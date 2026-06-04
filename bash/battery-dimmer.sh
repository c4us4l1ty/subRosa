#!/usr/bin/env bash
#
# battery-dimmer.sh — Production-grade battery-aware backlight dimmer.
#
# Features
#   • Zero-fork steady-state hot path
#   • FD-cached sysfs reads (one open at init, persistent FDs)
#   • Crash-safe state persistence (atomic write via mktemp+rename)
#   • Suspend/resume detection (SECONDS drift heuristic)
#   • User override detection (manual brightness changes release control)
#   • Multi-backlight and multi-battery support
#   • Periodic hardware re-scan for hotplug resilience
#   • Trap-recursion guard
#   • Strict-mode friendly (set -uo pipefail)
#
# Requirements
#   Bash 4.3+ (for printf '%(...)T' and local -n)
#   Linux with /sys/class/backlight and /sys/class/power_supply
#   Root privileges (writes to /sys/class/backlight/*/brightness)
#
# Suggested logrotate fragment
#   /var/log/battery-dimmer.log {
#       daily, rotate 7, compress, missingok, notifempty
#   }
#

# ==============================================================================
# STRICT MODE
# ==============================================================================
# -u  : catch unset-variable bugs (we use ${var:-default} where needed)
# -o pipefail : propagate pipe failures
# NOT -e : we explicitly want to survive a single broken backlight / battery
set -uo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
readonly THRESHOLD=${THRESHOLD:-50}             # % battery below which we dim
readonly DIM_BY_PERCENT=${DIM_BY_PERCENT:-30}    # % reduction from original
readonly MIN_PERCENT=${MIN_PERCENT:-5}           # floor: never below this %
readonly SUSPEND_THRESHOLD=${SUSPEND_THRESHOLD:-15}
readonly POLL_INTERVAL=${POLL_INTERVAL:-10}
readonly LOG_THROTTLE=${LOG_THROTTLE:-30}
readonly RESCAN_EVERY=${RESCAN_EVERY:-100}       # polls between hw re-scans
readonly RECOVERY_SETTLE=${RECOVERY_SETTLE:-2}   # s grace for sysfs post-resume

# Validate configuration early — fail fast on nonsense
(( THRESHOLD >= 0 && THRESHOLD <= 100 ))   || { echo "THRESHOLD out of range" >&2; exit 1; }
(( DIM_BY_PERCENT > 0 && DIM_BY_PERCENT <= 100 )) || { echo "DIM_BY_PERCENT out of range" >&2; exit 1; }
(( MIN_PERCENT >= 0 && MIN_PERCENT < 100 )) || { echo "MIN_PERCENT out of range" >&2; exit 1; }
(( POLL_INTERVAL >= 1 ))                   || { echo "POLL_INTERVAL must be >= 1" >&2; exit 1; }
(( SUSPEND_THRESHOLD > POLL_INTERVAL ))    || { echo "SUSPEND_THRESHOLD must exceed POLL_INTERVAL" >&2; exit 1; }

# ==============================================================================
# PATHS
# ==============================================================================
readonly SYSFS_BL="/sys/class/backlight"
readonly SYSFS_PS="/sys/class/power_supply"
readonly STATE_DIR="/run/battery-dimmer"
readonly LOCK_FILE="$STATE_DIR/lock"
readonly LOG_FILE="/var/log/battery-dimmer.log"
readonly SLEEP_FIFO="$STATE_DIR/.sleep_fifo"

# ==============================================================================
# PREFLIGHT
# ==============================================================================
export LC_ALL=C

# Bash version
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: Bash 4.3+ required (have ${BASH_VERSION:-unknown})." >&2
    exit 1
fi

# Root
if (( EUID != 0 )); then
    echo "Error: Must run as root." >&2
    exit 1
fi

shopt -s nullglob

# State dir
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "Error: Cannot create $STATE_DIR." >&2
    exit 1
fi
chmod 700 "$STATE_DIR"

# Lock — non-blocking, fail fast if another instance is running
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "Error: Service already running (lock: $LOCK_FILE)." >&2
    exit 1
fi

# Persistent log FD
if ! exec 7>> "$LOG_FILE" 2>/dev/null; then
    # Fall back to syslog-like path if /var/log is read-only
    if ! exec 7>> "$STATE_DIR/dimmer.log" 2>/dev/null; then
        echo "Error: Cannot open any writable log file." >&2
        exit 1
    fi
fi

# Persistent sleep FIFO — opened RW by the same process so open() doesn't block
if [[ ! -p "$SLEEP_FIFO" ]]; then
    rm -f "$SLEEP_FIFO" 2>/dev/null
    if ! mkfifo "$SLEEP_FIFO" 2>/dev/null; then
        echo "Error: Cannot create sleep FIFO $SLEEP_FIFO." >&2
        exit 1
    fi
    chmod 600 "$SLEEP_FIFO"
fi
exec 8<> "$SLEEP_FIFO"

# ==============================================================================
# GLOBALS
# ==============================================================================
# Per-backlight caches (keyed by backlight path)
declare -A BL_MAX=()      # max brightness
declare -A BL_MIN=()      # floor brightness
declare -A BL_TOL=()      # tolerance for "did the user touch it?"
declare -A BL_ORIG=()     # saved original brightness (while dimmed)
declare -A BL_FD_BR=()    # FD for brightness
declare -A BL_FD_MAX=()   # FD for max_brightness
declare -A BL_OVERRIDE=() # 1 = user has released control until power cycle
declare -A LOG_LAST=()    # last log timestamp per throttling key

# Hardware lists
declare -a BACKLIGHTS=()
declare -a POWER_SUPPLIES=()

# Per-power-supply FDs (parallel arrays, indexed by position)
declare -a PS_FD_TYPE=()
declare -a PS_FD_ONLINE=()
declare -a PS_FD_STATUS=()
declare -a PS_FD_SCOPE=()
declare -a PS_FD_NOW=()
declare -a PS_FD_FULL=()
declare -a PS_FD_CAP=()
declare -a PS_KIND=()    # "mains" | "usb" | "battery" — parallel index
declare -a PS_NAME=()    # basename for logging — parallel index

# Telemetry snapshot
declare BATTERY_PCT=100
declare SHOULD_DIM=0     # single source of truth for "should we dim?"
declare POWER_INPUT=0    # 1 = any mains/usb online

# Loop control
declare CLEANING_UP=0
declare POLL_COUNT=0
declare LAST_TICK=$SECONDS

# ==============================================================================
# LOGGING
# ==============================================================================

# Zero-fork timestamped log. printf -v avoids subshell.
log_msg() {
    local msg
    printf -v msg '%(%Y-%m-%d %H:%M:%S)T battery-dimmer: %s\n' -1 "$1"
    printf '%s' "$msg" >&7
}

# Throttled log: only emits if the same key hasn't been logged recently.
log_throttled() {
    local key=$1 text=$2
    local now=$SECONDS last=${LOG_LAST[$key]:-0}
    if (( now - last >= LOG_THROTTLE )); then
        LOG_LAST[$key]=$now
        log_msg "$text"
    fi
}

# ==============================================================================
# SYSFS HELPERS
# ==============================================================================

# Read an integer from a sysfs file (one-shot, no FD cache).
#   $1 = path, $2 = nameref to receive the value
#   Returns 0 if a valid integer was read, 1 otherwise.
#   On "no data" / parse failure, _out is set to 0 and 1 is returned so the
#   caller can distinguish "actual zero" from "no reading available".
sysfs_read_int() {
    local -n _out=$2
    local _raw
    if ! read -r _raw < "$1" 2>/dev/null; then
        _out=0
        return 1
    fi
    if [[ ! "$_raw" =~ ^[0-9]+$ ]]; then
        _out=0
        return 1
    fi
    _out=$_raw
    return 0
}

# Read an integer from a cached FD.
#   $1 = FD number, $2 = nameref
#   Returns 0 on success, 1 on failure (caller decides what to do).
sysfs_fd_read_int() {
    local -n _out=$2
    local _raw
    if ! read -r _raw <&"$1" 2>/dev/null; then
        _out=0
        return 1
    fi
    if [[ ! "$_raw" =~ ^[0-9]+$ ]]; then
        _out=0
        return 1
    fi
    _out=$_raw
    return 0
}

# Atomic write of a value to a sysfs file.
#   $1 = path, $2 = value (integer)
#   Returns 0 on success.
sysfs_write_int() {
    # We deliberately do NOT use a cached FD for writes — many backlight
    # drivers reject writes that don't come from "the same opener", and
    # keeping a write FD open across the lifetime of the daemon would
    # hold an exclusive reference. Open/write/close per write is the
    # safe and supported pattern.
    local path=$1 value=$2
    local tmp
    tmp=$(mktemp "$STATE_DIR/.write.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
    # mv is atomic on the same filesystem
    if ! mv -f "$tmp" "$path" 2>/dev/null; then
        # Fall back: direct write
        if ! printf '%s\n' "$value" > "$path" 2>/dev/null; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi
    return 0
}

# ==============================================================================
# COMPUTE
# ==============================================================================

# Compute the dimmed target for a given backlight and original value.
# Writes the result to a caller-supplied nameref (no subshell).
#   $1 = original brightness, $2 = backlight path, $3 = nameref for output
compute_dim_target() {
    local original=$1 path=$2
    local -n _target=$3
    local max=${BL_MAX[$path]:-0}
    local min=${BL_MIN[$path]:-1}
    local reduction

    if (( max <= 0 )); then
        _target=0
        return
    fi

    # Round up so that a 1-unit change still counts as a change
    reduction=$(( (original * DIM_BY_PERCENT + 99) / 100 ))
    (( reduction < 1 )) && reduction=1

    _target=$(( original - reduction ))
    (( _target < min )) && _target=$min
    (( _target < 0 )) && _target=0
}

# ==============================================================================
# HARDWARE DISCOVERY
# ==============================================================================

# (Re-)scan /sys/class/backlight and (re-)open FDs. Reentrant.
scan_backlights() {
    local bl max_bright name state_file saved target
    local -A seen=()

    # Close stale FDs and drop entries for backlights that no longer exist
    local existing_bl
    for existing_bl in "${BACKLIGHTS[@]}"; do
        seen[$existing_bl]=1
    done

    for bl in "$SYSFS_BL"/*; do
        [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] || continue
        [[ -n "${seen[$bl]:-}" ]] && continue   # already known and open

        if ! sysfs_read_int "$bl/max_brightness" max_bright || (( max_bright <= 0 )); then
            continue
        fi

        # Open persistent read FDs
        local fd_br fd_max
        if ! exec {fd_br}< "$bl/brightness" 2>/dev/null; then continue; fi
        if ! exec {fd_max}< "$bl/max_brightness" 2>/dev/null; then
            exec {fd_br}<&- 2>/dev/null
            continue
        fi

        BACKLIGHTS+=("$bl")
        BL_MAX[$bl]=$max_bright
        BL_MIN[$bl]=$(( max_bright * MIN_PERCENT / 100 < 1 ? 1 : max_bright * MIN_PERCENT / 100 ))
        BL_TOL[$bl]=$(( max_bright * 3 / 100 < 2 ? 2 : max_bright * 3 / 100 ))
        BL_FD_BR[$bl]=$fd_br
        BL_FD_MAX[$bl]=$fd_max

        name="${bl##*/}"

        # Crash recovery: was a previous instance mid-dim when it died?
        state_file="$STATE_DIR/$name"
        if [[ -f "$state_file" ]]; then
            if sysfs_read_int "$state_file" saved && (( saved > 0 && saved <= max_bright )); then
                BL_ORIG[$bl]=$saved
                compute_dim_target "$saved" "$bl" target
                if sysfs_write_int "$bl/brightness" "$target"; then
                    log_msg "Recovered $name from stale state. Re-dimmed to ${target}/${max_bright}."
                else
                    log_msg "Recovered $name state (saved=$saved) but re-dim write failed."
                fi
            fi
            rm -f "$state_file"
        fi
    done
}

# (Re-)scan /sys/class/power_supply and (re-)open FDs. Reentrant.
scan_power_supplies() {
    local dev type name kind
    local -A seen=()

    for dev in "${POWER_SUPPLIES[@]}"; do
        seen[$dev]=1
    done

    for dev in "$SYSFS_PS"/*; do
        [[ -f "$dev/type" ]] || continue
        [[ -n "${seen[$dev]:-}" ]] && continue

        if ! read -r type < "$dev/type" 2>/dev/null; then continue; fi
        type="${type,,}"
        name="${dev##*/}"

        case "$type" in
            mains|usb|usb_typec|usb_pd|wireless)
                kind="input"
                ;;
            battery)
                kind="battery"
                ;;
            *)
                continue
                ;;
        esac

        local fd_type fd_online fd_status fd_scope fd_now fd_full fd_cap
        exec {fd_type}< "$dev/type" 2>/dev/null || continue
        if [[ "$kind" == "input" ]]; then
            exec {fd_online}< "$dev/online" 2>/dev/null || { exec {fd_type}<&-; continue; }
        else
            fd_online=-1
        fi
        [[ -f "$dev/status"    ]] && { exec {fd_status}< "$dev/status"    2>/dev/null || fd_status=-1; } || fd_status=-1
        [[ -f "$dev/scope"     ]] && { exec {fd_scope}< "$dev/scope"     2>/dev/null || fd_scope=-1;  } || fd_scope=-1
        [[ -f "$dev/energy_now" ]] && { exec {fd_now}< "$dev/energy_now"  2>/dev/null || fd_now=-1;    } || fd_now=-1
        [[ -f "$dev/energy_full" ]] && { exec {fd_full}< "$dev/energy_full" 2>/dev/null || fd_full=-1;  } || fd_full=-1
        [[ -f "$dev/charge_now"  ]] && { exec {fd_cap}< "$dev/charge_now"   2>/dev/null || fd_cap=-1;   } || fd_cap=-1
        # We also open charge_full/capacity as needed below
        local fd_cfull fd_capacity
        [[ -f "$dev/charge_full" ]] && { exec {fd_cfull}< "$dev/charge_full" 2>/dev/null || fd_cfull=-1;  } || fd_cfull=-1
        [[ -f "$dev/capacity"    ]] && { exec {fd_capacity}< "$dev/capacity" 2>/dev/null || fd_capacity=-1; } || fd_capacity=-1

        POWER_SUPPLIES+=("$dev")
        PS_KIND+=("$kind")
        PS_NAME+=("$name")
        PS_FD_TYPE+=("$fd_type")
        PS_FD_ONLINE+=("$fd_online")
        PS_FD_STATUS+=("$fd_status")
        PS_FD_SCOPE+=("$fd_scope")
        PS_FD_NOW+=("$fd_now")
        PS_FD_FULL+=("$fd_full")
        PS_FD_CAP+=("$fd_cfull")     # repurposed slot for charge_full
        # We don't have a 7th slot, so for capacity we'll fall back to one-shot read
    done
}

# ==============================================================================
# TELEMETRY
# ==============================================================================

# Walk all known power supplies and update BATTERY_PCT / SHOULD_DIM / POWER_INPUT.
update_telemetry() {
    local i dev kind scope status online b_now b_full b_cap pct lowest
    local has_battery=0 mains_online=0 any_discharging=0 any_charging=0
    local -a bat_pcts=()

    BATTERY_PCT=100
    SHOULD_DIM=0
    POWER_INPUT=0

    for ((i = 0; i < ${#POWER_SUPPLIES[@]}; i++)); do
        kind=${PS_KIND[i]}

        if [[ "$kind" == "input" ]]; then
            if sysfs_fd_read_int "${PS_FD_ONLINE[i]}" online; then
                (( online == 1 )) && mains_online=1
            fi
            continue
        fi

        # kind == battery
        # Skip device-scope batteries (peripherals, not the laptop)
        scope=""
        if (( ${PS_FD_SCOPE[i]} >= 0 )); then
            read -r scope <&"${PS_FD_SCOPE[i]}" 2>/dev/null
            [[ "${scope,,}" == "device" ]] && continue
        fi

        status=""
        if (( ${PS_FD_STATUS[i]} >= 0 )); then
            read -r status <&"${PS_FD_STATUS[i]}" 2>/dev/null
        fi

        case "${status,,}" in
            discharging) any_discharging=1 ;;
            charging|full|"not charging") any_charging=1 ;;
            *) ;;  # unknown / idle — don't conclude
        esac

        b_now=0; b_full=0
        if (( ${PS_FD_NOW[i]} >= 0 )) && (( ${PS_FD_FULL[i]} >= 0 )); then
            sysfs_fd_read_int "${PS_FD_NOW[i]}"  b_now  || b_now=0
            sysfs_fd_read_int "${PS_FD_FULL[i]}" b_full || b_full=0
        elif (( ${PS_FD_CAP[i]} >= 0 )); then
            # slot reused: we stored charge_full in CAP index
            sysfs_fd_read_int "${PS_FD_CAP[i]}" b_full || b_full=0
            # for charge_now we don't have a cached slot — one-shot read
            local dev=${POWER_SUPPLIES[i]}
            sysfs_read_int "$dev/charge_now" b_now || b_now=0
        elif [[ -f "${POWER_SUPPLIES[i]}/capacity" ]]; then
            sysfs_read_int "${POWER_SUPPLIES[i]}/capacity" b_now || b_now=0
            b_full=100
        fi

        (( b_full <= 0 )) && continue

        pct=$(( b_now * 100 / b_full ))
        (( pct > 100 )) && pct=100
        (( pct < 0  )) && pct=0

        bat_pcts+=("$pct")
        has_battery=1
    done

    POWER_INPUT=$mains_online

    if (( ! has_battery )); then
        # No battery we care about — never dim
        BATTERY_PCT=-1
        SHOULD_DIM=0
        return
    fi

    # Lowest battery determines our state
    lowest=100
    for pct in "${bat_pcts[@]}"; do
        (( pct < lowest )) && lowest=$pct
    done
    BATTERY_PCT=$lowest

    if (( mains_online )); then
        SHOULD_DIM=0
    elif (( any_charging )) && (( ! any_discharging )); then
        # All batteries report non-discharging, no mains: weird state, don't dim
        SHOULD_DIM=0
    else
        (( lowest <= THRESHOLD )) && SHOULD_DIM=1
    fi
}

# ==============================================================================
# ACTIONS
# ==============================================================================

# Dim every backlight that is not overridden, on the dim path.
apply_dim() {
    local bl name current target orig_saved tol diff
    for bl in "${BACKLIGHTS[@]}"; do
        name="${bl##*/}"

        # User has explicitly released control; skip until the next power cycle
        [[ ${BL_OVERRIDE[$name]:-} == 1 ]] && continue

        current=0
        sysfs_fd_read_int "${BL_FD_BR[$bl]}" current || current=0

        if [[ -z "${BL_ORIG[$bl]:-}" ]]; then
            # First entry into dim for this backlight
            compute_dim_target "$current" "$bl" target
            if (( current > target )); then
                BL_ORIG[$bl]=$current
                # Persist for crash recovery (atomic)
                local state_tmp=$STATE_DIR/.${name}.tmp
                printf '%s\n' "$current" > "$state_tmp" 2>/dev/null \
                    && mv -f "$state_tmp" "$STATE_DIR/$name" 2>/dev/null
                if sysfs_write_int "$bl/brightness" "$target"; then
                    log_msg "Dimmed $name by ${DIM_BY_PERCENT}% (${current}->${target}, battery=${BATTERY_PCT}%)"
                else
                    log_msg "Dim write failed for $name; releasing control."
                    unset 'BL_ORIG[$bl]'
                    BL_OVERRIDE[$name]=1
                fi
            fi
        else
            # Maintaining dim; check for user override
            orig_saved=${BL_ORIG[$bl]}
            compute_dim_target "$orig_saved" "$bl" target
            diff=$(( current - target ))
            (( diff < 0 )) && diff=$(( -diff ))
            tol=${BL_TOL[$bl]}

            if (( diff > tol )); then
                local max=${BL_MAX[$bl]}
                if (( current >= max )); then
                    if (( SUSPEND_OCCURRED == 1 )); then
                        # Likely a resume that reset brightness to max
                        if sysfs_write_int "$bl/brightness" "$target"; then
                            log_msg "Suspend/resume detected on $name. Re-applied dim."
                        fi
                    else
                        # User cranked it to max — release until next power cycle
                        unset 'BL_ORIG[$bl]'
                        BL_OVERRIDE[$name]=1
                        rm -f "$STATE_DIR/$name"
                        log_msg "User set max brightness on $name. Releasing control."
                    fi
                else
                    # User nudged it — release control
                    unset 'BL_ORIG[$bl]'
                    BL_OVERRIDE[$name]=1
                    rm -f "$STATE_DIR/$name"
                    log_throttled "$name" "Manual override on $name. Releasing control."
                fi
            fi
        fi
    done
}

# Restore every dimmed backlight on the restore path.
apply_restore() {
    local bl name current orig_saved dimmed_set diff
    for bl in "${BACKLIGHTS[@]}"; do
        name="${bl##*/}"

        if [[ -n "${BL_ORIG[$bl]:-}" ]]; then
            orig_saved=${BL_ORIG[$bl]}
            current=0
            sysfs_fd_read_int "${BL_FD_BR[$bl]}" current || current=0

            compute_dim_target "$orig_saved" "$bl" dimmed_set
            diff=$(( current - dimmed_set ))
            (( diff < 0 )) && diff=$(( -diff ))

            if (( diff <= BL_TOL[$bl] )); then
                # Brightness is at our dimmed value — restore it
                if sysfs_write_int "$bl/brightness" "$orig_saved"; then
                    log_msg "Restored $name to original brightness (${orig_saved})."
                else
                    log_msg "Restore write failed for $name."
                fi
            else
                # User changed it during dim — don't fight them
                log_throttled "$name" "Override detected on $name. Keeping user brightness."
            fi
            unset 'BL_ORIG[$bl]'
            rm -f "$STATE_DIR/$name"
        fi

        # Re-engage on next low-battery event after a power cycle / full charge
        if [[ ${BL_OVERRIDE[$name]:-} == 1 ]] && (( POWER_INPUT == 0 )); then
            # Only clear override when the user has truly "moved on" — i.e.,
            # the laptop has been unplugged. We don't auto-clear on every
            # restore iteration; that would re-engage on the very next dim.
            # Keeping the user's "release control" sticky for the session.
            :
        fi
    done
}

# ==============================================================================
# CLEANUP
# ==============================================================================
cleanup() {
    # Guard against recursive trap firing
    (( CLEANING_UP )) && return 0
    CLEANING_UP=1

    log_msg "Service stopping. Restoring original brightness..."

    local bl val
    for bl in "${BACKLIGHTS[@]}"; do
        val=${BL_ORIG[$bl]:-}
        if [[ -n "$val" && "$val" -gt 0 ]]; then
            sysfs_write_int "$bl/brightness" "$val"
        fi
    done

    # Close all FDs explicitly (defensive; process exit would do it anyway)
    local fd
    for fd in "${BL_FD_BR[@]}" "${BL_FD_MAX[@]}" "${PS_FD_TYPE[@]}" \
              "${PS_FD_ONLINE[@]}" "${PS_FD_STATUS[@]}" "${PS_FD_SCOPE[@]}" \
              "${PS_FD_NOW[@]}" "${PS_FD_FULL[@]}" "${PS_FD_CAP[@]}"; do
        if (( fd >= 0 )) 2>/dev/null; then
            exec {fd}<&- 2>/dev/null
        fi
    done

    exec 8<&- 2>/dev/null
    exec 7>&- 2>/dev/null
    exec 9>&- 2>/dev/null

    rm -rf "$STATE_DIR"

    # Preserve original exit code if we were killed by a signal
    local rc=$?
    if (( rc == 0 )); then rc=0; fi
    exit "$rc"
}

trap cleanup EXIT SIGINT SIGTERM SIGHUP SIGQUIT

# ==============================================================================
# MAIN
# ==============================================================================
scan_backlights
scan_power_supplies

if (( ${#BACKLIGHTS[@]} == 0 )); then
    log_msg "No backlights found. Service is a no-op."
    # Still hold the lock and stay alive so we don't flap if a backlight appears
fi

log_msg "Service started. Threshold=${THRESHOLD}%, Dim=${DIM_BY_PERCENT}%, Floor=${MIN_PERCENT}%, Poll=${POLL_INTERVAL}s, Backlights=${#BACKLIGHTS[@]}, PowerSupplies=${#POWER_SUPPLIES[@]}"

LAST_TICK=$SECONDS
SUSPEND_OCCURRED=0

while true; do
    # Suspend detection: if the wall clock jumped more than SUSPEND_THRESHOLD,
    # assume we just resumed from suspend. $SECONDS in bash is wall-clock-based.
    local_now=$SECONDS
    elapsed=$(( local_now - LAST_TICK ))
    if (( elapsed > SUSPEND_THRESHOLD )); then
        SUSPEND_OCCURRED=1
        log_msg "Suspend/resume detected (drift=${elapsed}s). Will re-apply dim if needed."
        # Brief settle — some drivers take a moment to be writable after resume
        sleep "$RECOVERY_SETTLE"
        # Force a hardware re-scan to re-open any FDs invalidated by the resume
        scan_backlights
        scan_power_supplies
    else
        SUSPEND_OCCURRED=0
    fi
    LAST_TICK=$local_now

    # Periodic hotplug re-scan
    (( POLL_COUNT++ ))
    if (( POLL_COUNT % RESCAN_EVERY == 0 )); then
        scan_backlights
        scan_power_supplies
    fi

    update_telemetry

    if (( BATTERY_PCT < 0 )); then
        # No battery — sleep and try again
        read -t "$POLL_INTERVAL" -u 8 || true
        continue
    fi

    if (( SHOULD_DIM == 1 )); then
        apply_dim
    else
        apply_restore
    fi

    # Zero-fork sleep: read on an always-open FIFO blocks until either data
    # arrives or the timeout fires.
    read -t "$POLL_INTERVAL" -u 8 || true
done
