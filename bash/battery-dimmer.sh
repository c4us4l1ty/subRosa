#!/usr/bin/env bash
#
# battery-dimmer.sh — Ultra-optimized, zero-fork polling battery-aware backlight dimmer.
# Hardened for arbitrary arithmetic injection, race conditions, and sysfs quirks.

# ==============================================================================
# STRICT MODE & PARSER SETTINGS
# ==============================================================================
set -uo pipefail
shopt -s nullglob extglob

# Bash 4.2+ required for printf %()T (Zero-fork timestamps)
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    echo "Error: Bash 4.2 or higher is required." >&2
    exit 1
fi

# ==============================================================================
# CONFIGURATION & INJECTION PREVENTION
# ==============================================================================
# Fallbacks
: "${THRESHOLD:=50}"
: "${DIM_BY_PERCENT:=30}"
: "${MIN_PERCENT:=5}"
: "${SUSPEND_THRESHOLD:=10}"
: "${POLL_INTERVAL:=10}"
: "${LOG_THROTTLE:=30}"
: "${RESCAN_EVERY:=100}"
: "${RECOVERY_SETTLE:=2}"

# STRICT NUMERIC VALIDATION (Prevents arithmetic execution injection)
for _var in THRESHOLD DIM_BY_PERCENT MIN_PERCENT SUSPEND_THRESHOLD POLL_INTERVAL LOG_THROTTLE RESCAN_EVERY RECOVERY_SETTLE; do
    [[ "${!_var}" =~ ^[0-9]+$ ]] || { echo "Fatal: $_var must be a positive integer." >&2; exit 1; }
done
unset _var

readonly THRESHOLD DIM_BY_PERCENT MIN_PERCENT SUSPEND_THRESHOLD POLL_INTERVAL LOG_THROTTLE RESCAN_EVERY RECOVERY_SETTLE

(( THRESHOLD >= 0 && THRESHOLD <= 100 ))          || exit 1
(( DIM_BY_PERCENT > 0 && DIM_BY_PERCENT <= 100 )) || exit 1
(( MIN_PERCENT >= 0 && MIN_PERCENT < 100 ))       || exit 1
(( POLL_INTERVAL >= 1 ))                          || exit 1
(( SUSPEND_THRESHOLD > 2 ))                       || exit 1

# ==============================================================================
# PATHS & ROBUST INITIALIZATION
# ==============================================================================
readonly SYSFS_BL="/sys/class/backlight"
readonly SYSFS_PS="/sys/class/power_supply"
readonly STATE_DIR="/run/battery-dimmer"
readonly LOCK_FILE="/run/battery-dimmer.pid"
readonly LOG_FILE="/var/log/battery-dimmer.log"
readonly SLEEP_FIFO="$STATE_DIR/.sleep_fifo"

export LC_ALL=C

# Root check
(( EUID == 0 )) || { echo "Root required." >&2; exit 1; }

# State dir (ensure it exists before locking)
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR"

# Lock — Read/Write mode (<>) prevents truncation race condition.
exec 9<> "$LOCK_FILE"
flock -n 9 || { echo "Already running." >&2; exit 1; }

# Safe zero-fork truncation AFTER acquiring lock
: > "$LOCK_FILE"
echo $$ >&9

# Persistent sleep FIFO (Nuke regular files, ensure it is a pipe)
[[ -p "$SLEEP_FIFO" ]] || { rm -f "$SLEEP_FIFO"; mkfifo -m 600 "$SLEEP_FIFO"; }
exec 8<> "$SLEEP_FIFO"

# ==============================================================================
# GLOBALS
# ==============================================================================
# Associative arrays
declare -A BL_MAX=() BL_MIN=() BL_TOL=() BL_ORIG=() BL_OVERRIDE=() LOG_LAST=()

# Indexed arrays
declare -a BACKLIGHTS=() POWER_SUPPLIES=() PS_KIND=() PS_SCOPE=()

declare -i BATTERY_PCT=100 SHOULD_DIM=0 POWER_INPUT=0
declare -i CLEANING_UP=0 POLL_COUNT=0 LAST_TICK=$SECONDS SUSPEND_OCCURRED=0

# ==============================================================================
# ZERO-FORK LOGGING
# ==============================================================================
log_msg() {
    local msg
    # ${1:-} satisfies set -u if called without arguments
    printf -v msg '%(%Y-%m-%d %H:%M:%S)T battery-dimmer: %s\n' -1 "${1:-}"
    # Atomic append. Because we open/close per write, this naturally survives 
    # standard logrotate moves without needing a SIGHUP reopen handler.
    printf '%s' "$msg" >> "$LOG_FILE" 2>/dev/null || printf '%s' "$msg" >> "${STATE_DIR:?}/dimmer.log" 2>/dev/null
}

log_throttled() {
    local key=$1 text=$2 now=$SECONDS last=${LOG_LAST[$key]:-0}
    if (( now - last >= LOG_THROTTLE )); then
        LOG_LAST[$key]=$now
        log_msg "$text"
    fi
}

# ==============================================================================
# SYSFS HELPERS (BULLETPROOF ZERO-FORK)
# ==============================================================================
sysfs_read_int() {
    local _sri_raw=""
    
    # || true prevents script crash on missing newline, still populates _sri_raw
    read -r _sri_raw < "$1" 2>/dev/null || true
    
    # Strict regex: optional leading hyphen, followed by 1 or more digits.
    # Prevents arithmetic crashes from broken drivers returning "---" or "1-2".
    if [[ -n "$_sri_raw" && "$_sri_raw" =~ ^-?[0-9]+$ ]]; then
        printf -v "$2" '%s' "$_sri_raw" # Zero-fork safe assignment
        return 0
    fi
    printf -v "$2" '%s' "0"
    return 1
}

sysfs_write_int() {
    # sysfs writes < PAGE_SIZE are atomic at the kernel level
    printf '%s\n' "$2" > "$1" 2>/dev/null
}

state_persist() {
    local name=$1 val=$2 tmp="${STATE_DIR:?}/.$name.$$"
    # Note: mv is an external binary, but required here for atomic disk persistence
    printf '%s\n' "$val" > "$tmp" 2>/dev/null && mv -f "$tmp" "${STATE_DIR}/$name" 2>/dev/null
}

# ==============================================================================
# HARDWARE DISCOVERY
# ==============================================================================
scan_backlights() {
    local bl max_bright name saved target
    
    # Clear arrays entirely to prevent memory leaks from unplugged monitors
    BACKLIGHTS=()
    BL_MAX=() BL_MIN=() BL_TOL=()

    for bl in "$SYSFS_BL"/*; do
        [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] || continue
        sysfs_read_int "$bl/max_brightness" max_bright || continue
        (( max_bright <= 0 )) && continue

        BACKLIGHTS+=("$bl")
        BL_MAX[$bl]=$max_bright
        BL_MIN[$bl]=$(( max_bright * MIN_PERCENT / 100 < 1 ? 1 : max_bright * MIN_PERCENT / 100 ))
        BL_TOL[$bl]=$(( max_bright * 3 / 100 < 2 ? 2 : max_bright * 3 / 100 ))

        name="${bl##*/}"

        # Crash recovery
        if [[ -f "$STATE_DIR/$name" ]]; then
            if sysfs_read_int "$STATE_DIR/$name" saved && (( saved > 0 && saved <= max_bright )); then
                BL_ORIG[$bl]=$saved
                target=$(( saved - (saved * DIM_BY_PERCENT + 99) / 100 ))
                (( target < ${BL_MIN[$bl]} )) && target=${BL_MIN[$bl]}
                sysfs_write_int "$bl/brightness" "$target" && \
                    log_msg "Recovered $name to ${target}/${max_bright}."
            fi
            rm -f "${STATE_DIR:?}/$name"
        fi
    done
}

scan_power_supplies() {
    local dev type kind scope
    POWER_SUPPLIES=() PS_KIND=() PS_SCOPE=()

    for dev in "$SYSFS_PS"/*; do
        [[ -f "$dev/type" ]] || continue
        read -r type < "$dev/type" 2>/dev/null || continue
        type="${type,,}"

        case "$type" in
            mains|usb|usb_typec|usb_pd|wireless) kind="input" ;;
            battery) kind="battery" ;;
            *) continue ;;
        esac

        scope=""
        [[ -f "$dev/scope" ]] && read -r scope < "$dev/scope" 2>/dev/null

        POWER_SUPPLIES+=("$dev")
        PS_KIND+=("$kind")
        PS_SCOPE+=("${scope,,}")
    done
}

# ==============================================================================
# TELEMETRY
# ==============================================================================
update_telemetry() {
    local i dev kind status online b_now b_full pct lowest=100
    local has_battery=0 mains_online=0 any_discharging=0 any_charging=0

    BATTERY_PCT=100 SHOULD_DIM=0 POWER_INPUT=0

    for ((i = 0; i < ${#POWER_SUPPLIES[@]}; i++)); do
        dev=${POWER_SUPPLIES[i]}
        kind=${PS_KIND[i]}

        if [[ "$kind" == "input" ]]; then
            sysfs_read_int "$dev/online" online || online=0
            (( online == 1 )) && mains_online=1
            continue
        fi

        [[ "${PS_SCOPE[i]}" == "device" ]] && continue

        status=""
        [[ -f "$dev/status" ]] && read -r status < "$dev/status" 2>/dev/null
        case "${status,,}" in
            discharging) any_discharging=1 ;;
            charging|full|"not charging") any_charging=1 ;;
        esac

        b_now=0 b_full=0
        if [[ -f "$dev/energy_now" && -f "$dev/energy_full" ]]; then
            sysfs_read_int "$dev/energy_now" b_now; sysfs_read_int "$dev/energy_full" b_full
        elif [[ -f "$dev/charge_now" && -f "$dev/charge_full" ]]; then
            sysfs_read_int "$dev/charge_now" b_now; sysfs_read_int "$dev/charge_full" b_full
        elif [[ -f "$dev/capacity" ]]; then
            sysfs_read_int "$dev/capacity" b_now
            b_full=100
        fi

        # Safeguard division by zero and faulty sensors
        (( b_full <= 0 )) && continue

        pct=$(( b_now * 100 / b_full ))
        (( pct > 100 )) && pct=100
        (( pct < lowest )) && lowest=$pct
        has_battery=1
    done

    POWER_INPUT=$mains_online
    (( ! has_battery )) && { BATTERY_PCT=-1; return; }

    BATTERY_PCT=$lowest
    if (( mains_online || (any_charging && ! any_discharging) )); then
        SHOULD_DIM=0
    else
        (( lowest <= THRESHOLD )) && SHOULD_DIM=1
    fi
}

# ==============================================================================
# ACTIONS
# ==============================================================================
apply_dim() {
    (( ${#BACKLIGHTS[@]} == 0 )) && return 0
    local bl name current target orig_saved diff reduction orig_diff

    for bl in "${BACKLIGHTS[@]}"; do
        name="${bl##*/}"
        [[ ${BL_OVERRIDE[$name]:-0} == 1 ]] && continue

        sysfs_read_int "$bl/brightness" current || current=0

        if [[ -z "${BL_ORIG[$bl]:-}" ]]; then
            reduction=$(( (current * DIM_BY_PERCENT + 99) / 100 ))
            (( reduction < 1 )) && reduction=1
            target=$(( current - reduction ))
            (( target < ${BL_MIN[$bl]} )) && target=${BL_MIN[$bl]}

            if (( current > target )); then
                BL_ORIG[$bl]=$current
                state_persist "$name" "$current"
                if sysfs_write_int "$bl/brightness" "$target"; then
                    log_msg "Dimmed $name by ${DIM_BY_PERCENT}% (${current}->${target}, bat=${BATTERY_PCT}%)"
                else
                    unset 'BL_ORIG[$bl]'
                    BL_OVERRIDE[$name]=1
                fi
            fi
        else
            orig_saved=${BL_ORIG[$bl]}
            reduction=$(( (orig_saved * DIM_BY_PERCENT + 99) / 100 ))
            target=$(( orig_saved - reduction ))
            (( target < ${BL_MIN[$bl]} )) && target=${BL_MIN[$bl]}
            
            diff=$(( current - target ))
            (( diff < 0 )) && diff=$(( -diff ))

            if (( SUSPEND_OCCURRED == 1 )); then
                if (( diff <= ${BL_TOL[$bl]} )); then
                    : # Already at target, do nothing
                else
                    orig_diff=$(( current - orig_saved ))
                    (( orig_diff < 0 )) && orig_diff=$(( -orig_diff ))
                    
                    if (( orig_diff <= ${BL_TOL[$bl]} )); then
                        # DE restored to original on wake, re-apply dim
                        sysfs_write_int "$bl/brightness" "$target" && \
                            log_msg "Suspend/resume: DE restored $name, re-applying dim."
                    else
                        # Wildly different, assume user/DE override
                        unset 'BL_ORIG[$bl]'
                        BL_OVERRIDE[$name]=1
                        rm -f "${STATE_DIR:?}/$name"
                        log_throttled "$name" "Suspend/resume: Override detected on $name. Released control."
                    fi
                fi
            elif (( diff > ${BL_TOL[$bl]} )); then
                # Normal runtime manual override
                unset 'BL_ORIG[$bl]'
                BL_OVERRIDE[$name]=1
                rm -f "${STATE_DIR:?}/$name"
                log_throttled "$name" "Override detected on $name (diff=$diff). Released control."
            fi
        fi
    done
}

apply_restore() {
    (( ${#BACKLIGHTS[@]} == 0 )) && return 0
    local bl name current orig_saved dimmed_set diff reduction

    for bl in "${BACKLIGHTS[@]}"; do
        name="${bl##*/}"

        if [[ -n "${BL_ORIG[$bl]:-}" ]]; then
            orig_saved=${BL_ORIG[$bl]}
            sysfs_read_int "$bl/brightness" current || current=0

            reduction=$(( (orig_saved * DIM_BY_PERCENT + 99) / 100 ))
            dimmed_set=$(( orig_saved - reduction ))
            (( dimmed_set < ${BL_MIN[$bl]} )) && dimmed_set=${BL_MIN[$bl]}
            
            diff=$(( current - dimmed_set ))
            (( diff < 0 )) && diff=$(( -diff ))

            # Even on wake up, if we plug in power, we want to restore.
            if (( diff <= ${BL_TOL[$bl]} || SUSPEND_OCCURRED == 1 )); then
                sysfs_write_int "$bl/brightness" "$orig_saved" && \
                    log_msg "Restored $name to original ($orig_saved)."
            fi
            
            unset 'BL_ORIG[$bl]'
            rm -f "${STATE_DIR:?}/$name"
        fi

        # Power input clears previous user overrides
        (( POWER_INPUT == 1 )) && BL_OVERRIDE[$name]=0
    done
}

# ==============================================================================
# CLEANUP
# ==============================================================================
cleanup() {
    # SIGHUP removed to allow logrotate to function without killing the daemon
    trap '' EXIT SIGINT SIGTERM SIGQUIT 
    (( CLEANING_UP )) && exit 0
    CLEANING_UP=1

    log_msg "Stopping. Restoring backlights..."
    
    # Prevent unbound variable error on empty array under set -u
    if (( ${#BACKLIGHTS[@]} > 0 )); then
        for bl in "${BACKLIGHTS[@]}"; do
            val=${BL_ORIG[$bl]:-}
            [[ -n "$val" ]] && sysfs_write_int "$bl/brightness" "$val"
        done
    fi

    # CRITICAL: Delete state BEFORE releasing the lock to prevent race conditions
    # where a newly spawned instance acquires the lock while we are deleting its state.
    rm -rf "${STATE_DIR:?}"
    rm -f "$LOCK_FILE"

    # Now release FDs
    exec 8<&- 2>/dev/null
    exec 9>&- 2>/dev/null
    
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM SIGQUIT

# ==============================================================================
# MAIN LOOP
# ==============================================================================
scan_backlights
scan_power_supplies
log_msg "Started. Threshold=${THRESHOLD}%, Dim=${DIM_BY_PERCENT}%, Poll=${POLL_INTERVAL}s."

while true; do
    local_now=$SECONDS
    # True drift calculation
    drift=$(( local_now - LAST_TICK - POLL_INTERVAL ))
    
    if (( drift > SUSPEND_THRESHOLD )); then
        SUSPEND_OCCURRED=1
        log_msg "Suspend/resume detected (drift=${drift}s)."
        # Let GPU/Drivers settle before scanning
        read -t "$RECOVERY_SETTLE" -u 8 || true
        scan_backlights
        scan_power_supplies
    else
        SUSPEND_OCCURRED=0
    fi
    LAST_TICK=$local_now

    (( ++POLL_COUNT % RESCAN_EVERY == 0 )) && { scan_backlights; scan_power_supplies; }

    update_telemetry

    if (( BATTERY_PCT >= 0 )); then
        (( SHOULD_DIM == 1 )) && apply_dim || apply_restore
    fi

    # Update tick immediately prior to sleep to prevent execution time drift
    LAST_TICK=$SECONDS
    # Zero-fork sleep. Data will never arrive on FD 8.
    read -t "$POLL_INTERVAL" -u 8 || true
done
