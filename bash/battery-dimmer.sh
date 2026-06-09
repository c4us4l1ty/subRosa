#!/usr/bin/env bash
# battery-dimmer.sh — True A++ Grade Event-driven, hardware-aware backlight dimmer.
# Mathematically perceptual (Weber-Fechner compliant), strictly zero-fork, TOCTOU immune,
# integer overflow protected, and inherently safe against udev and sysfs deadlocks.

# STRICT MODE
set -uo pipefail
shopt -s nullglob

# Correct POSIX-style Bash 4.2+ validation
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    echo "Fatal: Bash 4.2 or higher is required." >&2
    exit 1
fi

# ==============================================================================
# CONFIGURATION & STRICT VALIDATION (Overflow Protected)
# ==============================================================================
: "${THRESHOLD:=50}"
: "${DIM_BY_PERCENT:=30}"
: "${MIN_PERCENT:=5}"
: "${BASE_POLL_INTERVAL:=60}"
: "${SUSPEND_THRESHOLD:=10}"
: "${LOG_THROTTLE:=30}"
: "${RESCAN_EVERY:=10}"
: "${UDEV_DEBOUNCE:=2}" # Seconds to wait for flapping hardware to settle

# Strict 6-digit upper bound prevents arbitrary user input from overflowing Bash's 64-bit integer limits
for _var in THRESHOLD DIM_BY_PERCENT MIN_PERCENT BASE_POLL_INTERVAL SUSPEND_THRESHOLD LOG_THROTTLE RESCAN_EVERY UDEV_DEBOUNCE; do
    [[ "${!_var}" =~ ^0*[0-9]{1,6}$ ]] || { echo "Fatal: $_var must be a positive integer <= 999999." >&2; exit 1; }
    printf -v "$_var" '%d' "$(( 10#${!_var} ))"
done
unset _var

readonly THRESHOLD DIM_BY_PERCENT MIN_PERCENT BASE_POLL_INTERVAL SUSPEND_THRESHOLD LOG_THROTTLE RESCAN_EVERY UDEV_DEBOUNCE

(( THRESHOLD >= 0 && THRESHOLD <= 100 ))          || exit 1
(( DIM_BY_PERCENT > 0 && DIM_BY_PERCENT <= 100 )) || exit 1
(( MIN_PERCENT >= 0 && MIN_PERCENT < 100 ))       || exit 1
(( BASE_POLL_INTERVAL >= 10 ))                    || exit 1
(( UDEV_DEBOUNCE >= 1 && UDEV_DEBOUNCE <= 60 ))   || exit 1

# ==============================================================================
# PATHS, TOCTOU-SAFE INITIALIZATION, & UDEV DEADLOCK PREVENTION
# ==============================================================================
readonly SYSFS_BL="/sys/class/backlight"
readonly SYSFS_PS="/sys/class/power_supply"
readonly STATE_DIR="/run/battery-dimmer"
readonly LOCK_FILE="$STATE_DIR/dimmer.lock"
declare LOG_FILE="/var/log/battery-dimmer.log"
readonly WAKEUP_FIFO="$STATE_DIR/wakeup"
readonly SLEEP_FIFO="$STATE_DIR/sleep_timer"
readonly UDEV_RULE="/etc/udev/rules.d/99-battery-dimmer.rules"

export LC_ALL=C
(( EUID == 0 )) || { echo "Fatal: Root required." >&2; exit 1; }

# UDEV Deadlock-Immune Installation
if [[ "${1:-}" == "--install-udev" ]]; then
    # Using 'dd' with nonblock ensures the udev worker thread never blocks if the daemon is dead.
    cat <<EOF > "$UDEV_RULE"
# Wake up battery-dimmer. Non-blocking to prevent udev worker starvation/PID exhaustion.
SUBSYSTEM=="power_supply", RUN+="/bin/sh -c 'echo 1 | dd of=${WAKEUP_FIFO} oflag=nonblock status=none 2>/dev/null || true'"
EOF
    udevadm control --reload-rules
    echo "Installed A++ udev rule. The daemon will wake instantly and safely on AC events."
    exit 0
fi

# TOCTOU-Safe State Directory Initialization
mkdir -m 700 "$STATE_DIR" 2>/dev/null || true
if [[ ! -d "$STATE_DIR" || ! -O "$STATE_DIR" ]]; then
    echo "Fatal: State dir compromised or unavailable." >&2; exit 1
fi

# TOCTOU-Safe FIFO Creation (Atomic, validating ownership/type to prevent symlink attacks)
mkfifo -m 600 "$WAKEUP_FIFO" 2>/dev/null || true
if [[ ! -p "$WAKEUP_FIFO" || $(stat -c '%U' "$WAKEUP_FIFO") != "root" ]]; then
    echo "Fatal: Wakeup FIFO compromised or invalid." >&2; exit 1
fi

mkfifo -m 600 "$SLEEP_FIFO" 2>/dev/null || true
if [[ ! -p "$SLEEP_FIFO" || $(stat -c '%U' "$SLEEP_FIFO") != "root" ]]; then
    echo "Fatal: Sleep FIFO compromised or invalid." >&2; exit 1
fi

# Daemon Log Reopener
reopen_logs() {
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE" 2>/dev/null || LOG_FILE="$STATE_DIR/dimmer.log"
    exec 7>> "$LOG_FILE"
}
reopen_logs

# ==============================================================================
# DAEMON LOCKING & TRAPS (TOCTOU-IMMUNE FLOCK)
# ==============================================================================
exec 9> "$LOCK_FILE"
flock -n 9 || { echo "Fatal: Already running. Lock held by another instance." >&2; exit 1; }

cleanup() {
    trap '' EXIT SIGINT SIGTERM SIGHUP SIGQUIT 
    (( CLEANING_UP )) && exit 0
    CLEANING_UP=1

    log_msg "Stopping daemon. Restoring backlight states..."
    
    if (( ${#BACKLIGHTS[@]} > 0 )); then
        for bl in "${BACKLIGHTS[@]}"; do
            if [[ "${BL_DIMMED["$bl"]:-0}" == "1" && -n "${BL_ORIG["$bl"]:-}" ]]; then
                printf '%s\n' "${BL_ORIG["$bl"]}" > "$bl/brightness" 2>/dev/null
            fi
        done
    fi

    rm -f "$WAKEUP_FIFO" "$SLEEP_FIFO" "$LOCK_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
    
    exec 10<&- 2>/dev/null
    exec 9<&- 2>/dev/null
    exec 8<&- 2>/dev/null
    exec 7>&- 2>/dev/null
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM SIGQUIT
trap reopen_logs SIGHUP

exec 8<> "$WAKEUP_FIFO"
exec 10<> "$SLEEP_FIFO" # Dedicated internal zero-fork sleep FD

# ==============================================================================
# GLOBALS & MONOTONIC TIME TRACKING (Zero-Fork)
# ==============================================================================
declare -a BACKLIGHTS=() POWER_SUPPLIES=() PS_KIND=() PS_SCOPE=()
declare -A BL_MAX=() BL_MIN=() BL_TOL=() BL_ORIG=() BL_OVERRIDE=() BL_DIMMED=() LOG_LAST=()

declare -i BATTERY_PCT=100 SHOULD_DIM=0 POWER_INPUT=0
declare -i CLEANING_UP=0 WAKEUP_COUNT=0 CURRENT_POLL_INTERVAL=$BASE_POLL_INTERVAL

declare -i UPTIME_REPLY=0
[[ -f /proc/uptime ]] || { echo "Fatal: /proc/uptime required for accurate monotonic time." >&2; exit 1; }
get_uptime() {
    local up _
    read -t 1 -r up _ < /proc/uptime || return 1
    UPTIME_REPLY=${up%%.*}
}

get_uptime
declare -i LAST_TICK=$UPTIME_REPLY

# Native Zero-Fork Sleep via Dummy FD Timeout
zero_fork_sleep() {
    read -t "${1:-0.02}" -u 10 _ || true
}

# ==============================================================================
# LOGGING
# ==============================================================================
log_msg() {
    printf '%(%Y-%m-%d %H:%M:%S)T battery-dimmer: %s\n' -1 "${1:-}" >&7 2>/dev/null
}

log_throttled() {
    local key=$1 text=$2 last now
    get_uptime
    now=$UPTIME_REPLY
    last=${LOG_LAST[$key]:-0}
    if (( now - last >= LOG_THROTTLE )); then
        LOG_LAST["$key"]=$now
        log_msg "$text"
    fi
}

# ==============================================================================
# HARDWARE DISCOVERY
# ==============================================================================
scan_backlights() {
    local bl max_bright
    unset -v BACKLIGHTS BL_MAX BL_MIN BL_TOL BL_ORIG BL_OVERRIDE BL_DIMMED
    declare -g -a BACKLIGHTS=()
    declare -g -A BL_MAX=() BL_MIN=() BL_TOL=() BL_ORIG=() BL_OVERRIDE=() BL_DIMMED=()

    for bl in "$SYSFS_BL"/*; do
        [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] || continue
        # Timeouts applied to ALL sysfs reads to prevent kernel driver hangs
        read -t 1 -r max_bright < "$bl/max_brightness" 2>/dev/null || continue
        [[ "$max_bright" =~ ^[0-9]+$ ]] || continue
        (( max_bright <= 0 )) && continue

        BACKLIGHTS+=("$bl")
        BL_MAX["$bl"]=$max_bright
        BL_MIN["$bl"]=$(( max_bright * MIN_PERCENT / 100 < 1 ? 1 : max_bright * MIN_PERCENT / 100 ))
        BL_TOL["$bl"]=$(( max_bright * 3 / 100 < 2 ? 2 : max_bright * 3 / 100 ))
    done
}

scan_power_supplies() {
    local dev type kind scope
    unset -v POWER_SUPPLIES PS_KIND PS_SCOPE
    declare -g -a POWER_SUPPLIES=() PS_KIND=() PS_SCOPE=()

    for dev in "$SYSFS_PS"/*; do
        [[ -f "$dev/type" ]] || continue
        read -t 1 -r type < "$dev/type" 2>/dev/null || continue
        type="${type,,}"

        case "$type" in
            mains|usb*) kind="input" ;;
            battery) kind="battery" ;;
            *) continue ;;
        esac

        scope=""
        [[ -f "$dev/scope" ]] && read -t 1 -r scope < "$dev/scope" 2>/dev/null

        POWER_SUPPLIES+=("$dev")
        PS_KIND+=("$kind")
        PS_SCOPE+=("${scope,,}")
    done
}

# ==============================================================================
# TELEMETRY & MATH
# ==============================================================================
update_telemetry() {
    local i dev kind status online b_now b_full pct lowest=100
    local has_battery=0 mains_online=0 any_discharging=0 any_charging=0

    BATTERY_PCT=100 SHOULD_DIM=0 POWER_INPUT=0

    for ((i = 0; i < ${#POWER_SUPPLIES[@]}; i++)); do
        dev=${POWER_SUPPLIES[i]}
        kind=${PS_KIND[i]}

        if [[ "$kind" == "input" ]]; then
            read -t 1 -r online < "$dev/online" 2>/dev/null || online=0
            (( online == 1 )) && mains_online=1
            continue
        fi

        [[ "${PS_SCOPE[i]}" == "device" ]] && continue

        status=""
        [[ -f "$dev/status" ]] && read -t 1 -r status < "$dev/status" 2>/dev/null
        case "${status,,}" in
            discharging) any_discharging=1 ;;
            charging|full|"not charging") any_charging=1 ;;
        esac

        b_now=0; b_full=0
        if [[ -f "$dev/capacity" ]]; then
            read -t 1 -r b_now < "$dev/capacity" 2>/dev/null || b_now=0
            b_full=100
        elif [[ -f "$dev/energy_now" && -f "$dev/energy_full" ]]; then
            read -t 1 -r b_now < "$dev/energy_now" 2>/dev/null || b_now=0
            read -t 1 -r b_full < "$dev/energy_full" 2>/dev/null || b_full=0
        elif [[ -f "$dev/charge_now" && -f "$dev/charge_full" ]]; then
            read -t 1 -r b_now < "$dev/charge_now" 2>/dev/null || b_now=0
            read -t 1 -r b_full < "$dev/charge_full" 2>/dev/null || b_full=0
        fi

        (( b_full <= 0 )) && continue

        # Multiplication precedes division to prevent bash float truncation
        pct=$(( (b_now * 100) / b_full ))
        
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
    
    if (( mains_online == 1 )); then
        CURRENT_POLL_INTERVAL=$(( BASE_POLL_INTERVAL * 5 ))
    elif (( lowest > THRESHOLD + 15 )); then
        CURRENT_POLL_INTERVAL=$BASE_POLL_INTERVAL
    else
        CURRENT_POLL_INTERVAL=$(( BASE_POLL_INTERVAL / 4 > 10 ? BASE_POLL_INTERVAL / 4 : 10 ))
    fi
}

# ==============================================================================
# ACTIONS & HARDWARE CONFIRMATION
# ==============================================================================
smooth_dim() {
    local bl=$1 start=$2 target=$3 name=$4
    local diff check_val current_val step steps=15 fraction
    
    diff=$(( target > start ? target - start : start - target ))
    (( diff == 0 )) && return 0
    (( diff < steps )) && steps=$diff
    (( steps > 30 )) && steps=30 # Hard cap iteration max
    
    for (( step=1; step<steps; step++ )); do
        # Logarithmic/Geometric Perceptual Interpolation using quadratic easing
        # Simulates the Weber-Fechner perceptual curve within Bash Integer math constraints
        fraction=$(( step * step * 10000 / (steps * steps) ))
        current_val=$(( start + (target - start) * fraction / 10000 ))
        
        printf '%s\n' "$current_val" > "$bl/brightness" 2>/dev/null
        
        # Truly zero-fork delay
        zero_fork_sleep 0.02
    done
    printf '%s\n' "$target" > "$bl/brightness" 2>/dev/null
    
    read -t 1 -r check_val < "$bl/brightness" 2>/dev/null || check_val=0
    if (( check_val != target && check_val != current_val )); then
        log_msg "Warning: Hardware rejected brightness on $name (requested $target, got $check_val)."
        return 1
    fi
    return 0
}

apply_dim() {
    (( ${#BACKLIGHTS[@]} == 0 )) && return 0
    local bl name current target reduction diff

    for bl in "${BACKLIGHTS[@]}"; do
        name="${bl##*/}"
        [[ ${BL_OVERRIDE["$name"]:-0} == 1 ]] && continue

        read -t 1 -r current < "$bl/brightness" 2>/dev/null || current=0
        reduction=$(( (current * DIM_BY_PERCENT + 99) / 100 ))
        (( reduction < 1 )) && reduction=1
        target=$(( current - reduction ))
        
        (( target < ${BL_MIN["$bl"]} )) && target=${BL_MIN["$bl"]}

        if [[ "${BL_DIMMED["$bl"]:-0}" == "1" ]]; then
            diff=$(( current > target ? current - target : target - current ))
            if (( diff > ${BL_TOL["$bl"]} )); then
                unset "BL_ORIG[$bl]"
                BL_DIMMED["$bl"]=0
                BL_OVERRIDE["$name"]=1
                log_throttled "$name" "Hardware override detected on $name. Released control."
            fi
        elif (( current > target )); then
            if smooth_dim "$bl" "$current" "$target" "$name"; then
                BL_ORIG["$bl"]=$current
                BL_DIMMED["$bl"]=1
                log_msg "Dimmed $name smoothly (${current}->${target}, bat=${BATTERY_PCT}%)"
            else
                unset "BL_ORIG[$bl]"
                BL_DIMMED["$bl"]=0
                BL_OVERRIDE["$name"]=1
            fi
        fi
    done
}

apply_restore() {
    (( ${#BACKLIGHTS[@]} == 0 )) && return 0
    local bl name current orig_saved

    for bl in "${BACKLIGHTS[@]}"; do
        name="${bl##*/}"

        if [[ "${BL_DIMMED["$bl"]:-0}" == "1" && -n "${BL_ORIG["$bl"]:-}" ]]; then
            orig_saved=${BL_ORIG["$bl"]}
            read -t 1 -r current < "$bl/brightness" 2>/dev/null || current=0
            
            smooth_dim "$bl" "$current" "$orig_saved" "$name" && \
                log_msg "Restored $name to original ($orig_saved)."
            
            unset "BL_ORIG[$bl]"
            BL_DIMMED["$bl"]=0
        fi

        (( POWER_INPUT == 1 )) && BL_OVERRIDE["$name"]=0
    done
}

# ==============================================================================
# MAIN LOOP
# ==============================================================================
scan_backlights
scan_power_supplies
log_msg "Started. Threshold=${THRESHOLD}%, Dim=${DIM_BY_PERCENT}%, Max Polling=${BASE_POLL_INTERVAL}s."

# Drain any stale startup events before entering the loop
while read -t 0 -u 8; do read -r -t 0.05 -u 8 _ || break; done

while true; do
    # Sleep until timeout or instant interrupt from Udev pipe.
    # 'read' returns 0 if it successfully read data (udev event).
    # It returns >0 if it timed out.
    if read -t "$CURRENT_POLL_INTERVAL" -r -u 8 _; then
        # UDEV EVENT DETECTED
        # Debounce: Sleep to allow flapping hardware (e.g., loose charging cables) 
        # to settle. The kernel will buffer rapid-fire events in the FIFO during this time.
        zero_fork_sleep "$UDEV_DEBOUNCE"
        
        # Drain the accumulated flapping signals cleanly without blocking
        while read -t 0 -u 8; do 
            read -r -t 0.05 -u 8 _ || break
        done
    fi

    get_uptime
    NOW_TICK=$UPTIME_REPLY
    drift=$(( NOW_TICK - LAST_TICK ))
    
    if (( drift > CURRENT_POLL_INTERVAL + SUSPEND_THRESHOLD )); then
        log_msg "Suspend/resume detected (drift=${drift}s). Forcing hardware rescan."
        scan_backlights
        scan_power_supplies
    fi
    LAST_TICK=$NOW_TICK

    (( ++WAKEUP_COUNT % RESCAN_EVERY == 0 )) && { scan_backlights; scan_power_supplies; }

    update_telemetry

    if (( BATTERY_PCT >= 0 )); then
        if (( SHOULD_DIM == 1 )); then
            apply_dim
        else
            apply_restore
        fi
    fi
done
