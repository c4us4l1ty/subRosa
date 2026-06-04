#!/usr/bin/env bash
# shellcheck shell=bash
#
# battery-dimmer.sh — Dim backlight on low battery, restore when charging/charged.
# Zero-fork hot path, crash-safe, thermally friendly.
#

# ==============================================================================
# STRICT MODE & ERRORS
# ==============================================================================
# Note: NOT using `set -e` because we want to continue on non-fatal errors
# (e.g., a single backlight being unwritable).

# ==============================================================================
# CONFIGURATION
# ==============================================================================
THRESHOLD=50
DIM_BY_PERCENT=30
MIN_PERCENT=5
SUSPEND_THRESHOLD=15   # seconds of drift to consider a suspend/resume
POLL_INTERVAL=10       # seconds between checks
LOG_THROTTLE=30        # minimum seconds between identical log messages

STATE_DIR="/run/battery-dimmer"
LOCK_FILE="$STATE_DIR/lock"
LOG_FILE="/var/log/battery-dimmer.log"
SLEEP_FIFO="$STATE_DIR/.sleep_fifo"

# ==============================================================================
# PREFLIGHT
# ==============================================================================
export LC_ALL=C

# Require Bash 4.3+ for `printf '%(...)T'` and `local -n`
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: Bash 4.3+ required." >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: Root required." >&2
    exit 1
fi

mkdir -p "$STATE_DIR"

exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "Error: Service already running." >&2
    exit 1
fi

# Persistent FDs: 7 = log, 8 = sleep FIFO (open in read+write mode to keep it alive)
exec 7>> "$LOG_FILE"
mkfifo "$SLEEP_FIFO" 2>/dev/null
exec 8<> "$SLEEP_FIFO"

shopt -s nullglob

# ==============================================================================
# GLOBALS (state shared with helpers)
# ==============================================================================
declare -A BL_MAX BL_TOLERANCE BL_MIN MEM_ORIGINAL OVERRIDES LOG_LAST
declare -a VALID_BACKLIGHTS
declare -a POWER_SUPPLIES
GLOBAL_BAT_PERCENT=100
GLOBAL_POWER_STATE="charging"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# Pure-Bash timestamped log. No fork, no `date`.
log_msg() {
    local msg
    printf -v msg '%(%Y-%m-%d %H:%M:%S)T battery-dimmer: %s\n' -1 "$1"
    echo "$msg" >&7
}

# Throttled log: only emits if the same key hasn't been logged recently.
log_throttled() {
    local key=$1
    local text=$2
    local now=$SECONDS
    local last=${LOG_LAST[$key]:-0}
    if (( now - last >= LOG_THROTTLE )); then
        LOG_LAST[$key]=$now
        log_msg "$text"
    fi
}

# Fast integer read from a sysfs file. Uses nameref to avoid subshells.
read_sysfs_int() {
    local -n _out=$2
    local _raw
    read -r _raw < "$1" 2>/dev/null
    if [[ "$_raw" == *[!0-9]* || -z "$_raw" ]]; then
        _out=0
    else
        _out=$_raw
    fi
}

# Single-pass telemetry: read all power supplies, compute lowest battery %.
update_telemetry() {
    GLOBAL_BAT_PERCENT=100
    GLOBAL_POWER_STATE="charging"
    local lowest=100
    local bat_found=0

    local dev type online scope status b_now b_full pct
    for dev in "${POWER_SUPPLIES[@]}"; do
        [[ -f "$dev/type" ]] || continue
        read -r type < "$dev/type" 2>/dev/null
        type="${type,,}"

        if [[ "$type" == "mains" || "$type" == "usb" ]]; then
            read -r online < "$dev/online" 2>/dev/null
            if [[ "$online" == "1" ]]; then
                GLOBAL_POWER_STATE="charging"
            fi
        elif [[ "$type" == "battery" ]]; then
            if [[ -f "$dev/scope" ]]; then
                read -r scope < "$dev/scope" 2>/dev/null
                [[ "${scope,,}" == *"device"* ]] && continue
            fi

            status="unknown"
            if [[ -f "$dev/status" ]]; then
                read -r status < "$dev/status" 2>/dev/null
            fi

            if [[ "$GLOBAL_POWER_STATE" != "charging" && "${status,,}" == "discharging" ]]; then
                GLOBAL_POWER_STATE="discharging"
            fi

            b_now=0
            b_full=0
            if [[ -f "$dev/energy_now" && -f "$dev/energy_full" ]]; then
                read_sysfs_int "$dev/energy_now" b_now
                read_sysfs_int "$dev/energy_full" b_full
            elif [[ -f "$dev/charge_now" && -f "$dev/charge_full" ]]; then
                read_sysfs_int "$dev/charge_now" b_now
                read_sysfs_int "$dev/charge_full" b_full
            elif [[ -f "$dev/capacity" ]]; then
                read_sysfs_int "$dev/capacity" b_now
                b_full=100
            fi

            if (( b_full > 0 )); then
                pct=$(( (b_now * 100) / b_full ))
                (( pct > 100 )) && pct=100
                (( pct < 0 )) && pct=0
                (( pct < lowest )) && lowest=$pct
                bat_found=1
            fi
        fi
    done

    if (( bat_found )); then
        GLOBAL_BAT_PERCENT=$lowest
    else
        GLOBAL_BAT_PERCENT=-1   # sentinel for "no battery found"
    fi
}

# Compute the dimmed target brightness for a given original value.
# Guarantees a minimum of 1 unit reduction and respects the floor.
compute_dim_target() {
    local original=$1
    local max=$2
    local min=${BL_MIN[$max]:-$(($max * MIN_PERCENT / 100))}
    (( min < 1 )) && min=1

    local reduction=$(( original * DIM_BY_PERCENT / 100 ))
    (( reduction < 1 )) && reduction=1

    local target=$(( original - reduction ))
    (( target < min )) && target=$min
    echo "$target"
}

# ==============================================================================
# INITIALIZATION: cache backlight metadata, recover from crash
# ==============================================================================

# Cache power supply list (rarely hotplugs on laptops).
mapfile -t POWER_SUPPLIES < <(compgen -G "/sys/class/power_supply/*" 2>/dev/null || true)

# Discover backlights, dedupe, pre-calc constants, handle crash recovery.
declare -A SEEN_BL
for bl in /sys/class/backlight/*; do
    [[ -n "${SEEN_BL[$bl]}" ]] && continue
    [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] || continue
    SEEN_BL[$bl]=1

    local_max=0
    read_sysfs_int "$bl/max_brightness" local_max
    if (( local_max <= 0 )); then
        continue
    fi

    VALID_BACKLIGHTS+=("$bl")
    BL_MAX[$bl]=$local_max

    # Tolerance: 3% of max, minimum 2 units
    local_tol=$(( local_max * 3 / 100 ))
    (( local_tol < 2 )) && local_tol=2
    BL_TOLERANCE[$bl]=$local_tol

    # Minimum brightness floor
    local_min=$(( local_max * MIN_PERCENT / 100 ))
    (( local_min < 1 )) && local_min=1
    BL_MIN[$bl]=$local_min

    # Crash recovery: restore original + re-apply dim immediately
    bl_name="${bl##*/}"
    state_file="$STATE_DIR/$bl_name"
    if [[ -f "$state_file" ]]; then
        saved=0
        read_sysfs_int "$state_file" saved
        if (( saved > 0 && saved <= local_max )); then
            MEM_ORIGINAL[$bl]=$saved
            target=$(compute_dim_target "$saved" "$local_max")
            if echo "$target" > "$bl/brightness" 2>/dev/null; then
                log_msg "Recovered $bl_name from stale state. Re-dimmed to ${target}/${local_max}."
            fi
        fi
        rm -f "$state_file"
    fi
done

# ==============================================================================
# CLEANUP
# ==============================================================================
cleanup() {
    log_msg "Service stopping. Restoring original brightness..."
    local bl val
    for bl in "${VALID_BACKLIGHTS[@]}"; do
        val=${MEM_ORIGINAL[$bl]}
        if [[ -n "$val" ]] && (( val > 0 )); then
            echo "$val" > "$bl/brightness" 2>/dev/null
        fi
    done
    rm -rf "$STATE_DIR"
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM SIGHUP SIGQUIT

# ==============================================================================
# MAIN LOOP
# ==============================================================================
log_msg "Service started. Threshold: ${THRESHOLD}%, Dim: ${DIM_BY_PERCENT}%, Polling: ${POLL_INTERVAL}s"

last_tick=$SECONDS
SUSPEND_OCCURRED=0

while true; do
    current_tick=$SECONDS
    elapsed=$(( current_tick - last_tick ))

    if (( elapsed > SUSPEND_THRESHOLD )); then
        SUSPEND_OCCURRED=1
    else
        SUSPEND_OCCURRED=0
    fi
    last_tick=$current_tick

    update_telemetry

    # No battery present — just sleep
    if (( GLOBAL_BAT_PERCENT < 0 )); then
        read -t "$POLL_INTERVAL" -u 8 || true
        continue
    fi

    # === DIM PATH: low battery + discharging ===
    if (( GLOBAL_BAT_PERCENT <= THRESHOLD )) && [[ "$GLOBAL_POWER_STATE" == "discharging" ]]; then
        for bl in "${VALID_BACKLIGHTS[@]}"; do
            bl_name="${bl##*/}"

            # User has set manual override — leave it alone
            [[ ${OVERRIDES[$bl_name]} == 1 ]] && continue

            CURRENT_BRIGHTNESS=0
            read_sysfs_int "$bl/brightness" CURRENT_BRIGHTNESS

            if [[ -z "${MEM_ORIGINAL[$bl]}" ]]; then
                # First time entering dim state for this backlight
                target=$(compute_dim_target "$CURRENT_BRIGHTNESS" "$bl")
                if (( CURRENT_BRIGHTNESS > target )); then
                    MEM_ORIGINAL[$bl]=$CURRENT_BRIGHTNESS
                    echo "$CURRENT_BRIGHTNESS" > "$STATE_DIR/$bl_name"
                    if echo "$target" > "$bl/brightness" 2>/dev/null; then
                        log_msg "Dimmed $bl_name by ${DIM_BY_PERCENT}% (Battery: ${GLOBAL_BAT_PERCENT}%)"
                    fi
                fi
            else
                # We are maintaining the dim; check for user override
                ORIGINAL_SAVED=${MEM_ORIGINAL[$bl]}
                target=$(compute_dim_target "$ORIGINAL_SAVED" "$bl")
                diff=$(( CURRENT_BRIGHTNESS - target ))
                (( diff < 0 )) && diff=$(( -diff ))
                tolerance=${BL_TOLERANCE[$bl]}

                if (( diff > tolerance )); then
                    if (( CURRENT_BRIGHTNESS >= BL_MAX[$bl] )); then
                        if (( SUSPEND_OCCURRED == 1 )); then
                            # Likely a resume that reset brightness to max
                            if echo "$target" > "$bl/brightness" 2>/dev/null; then
                                log_msg "Suspend/resume detected on $bl_name. Re-applying dim."
                            fi
                        else
                            # User set to max — release control until next power cycle
                            unset 'MEM_ORIGINAL[$bl]'
                            OVERRIDES[$bl_name]=1
                            rm -f "$STATE_DIR/$bl_name"
                            log_msg "User set max brightness on $bl_name. Releasing control."
                        fi
                    else
                        # User changed brightness manually — release control
                        unset 'MEM_ORIGINAL[$bl]'
                        OVERRIDES[$bl_name]=1
                        rm -f "$STATE_DIR/$bl_name"
                        log_throttled "$bl_name" "Manual override on $bl_name. Releasing control."
                    fi
                fi
            fi
        done

    # === RESTORE PATH: charging or battery above threshold ===
    elif [[ "$GLOBAL_POWER_STATE" == "charging" ]] || (( GLOBAL_BAT_PERCENT > THRESHOLD )); then
        for bl in "${VALID_BACKLIGHTS[@]}"; do
            bl_name="${bl##*/}"

            # Restore brightness if we dimmed it
            if [[ -n "${MEM_ORIGINAL[$bl]}" ]]; then
                ORIGINAL_SAVED=${MEM_ORIGINAL[$bl]}
                CURRENT_BRIGHTNESS=0
                read_sysfs_int "$bl/brightness" CURRENT_BRIGHTNESS

                # Where *we* set it to (the dimmed value)
                DIMMED_SET=$(compute_dim_target "$ORIGINAL_SAVED" "$bl")
                diff=$(( CURRENT_BRIGHTNESS - DIMMED_SET ))
                (( diff < 0 )) && diff=$(( -diff ))

                if (( diff <= BL_TOLERANCE[$bl] )); then
                    # Brightness is still at our dimmed value — restore it
                    if echo "$ORIGINAL_SAVED" > "$bl/brightness" 2>/dev/null; then
                        log_msg "Restored $bl_name to original brightness (${ORIGINAL_SAVED})."
                    fi
                else
                    # User changed it during dim — don't fight them
                    log_throttled "$bl_name" "Override detected on $bl_name. Keeping current brightness."
                fi
                unset 'MEM_ORIGINAL[$bl]'
                rm -f "$STATE_DIR/$bl_name"
            fi

            # Clear stale override flags so we re-engage on next low-battery event
            if [[ ${OVERRIDES[$bl_name]} == 1 ]]; then
                unset 'OVERRIDES[$bl_name]'
                log_throttled "$bl_name" "Cleared override for $bl_name."
            fi
        done
    fi

    # Zero-fork sleep: blocks on poll() internally
    read -t "$POLL_INTERVAL" -u 8 || true
done
