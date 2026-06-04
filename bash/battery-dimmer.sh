#!/usr/bin/env bash

# ==============================================================================
# CONFIGURATION & ENVIRONMENT
# ==============================================================================
export LC_ALL=C

THRESHOLD=50
DIM_BY_PERCENT=30
MIN_PERCENT=5

STATE_DIR="/run/battery-dimmer"
LOCK_FILE="$STATE_DIR/lock"

# Require Bash 4.3+ for Namerefs (local -n)
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: Bash 4.3+ required for zero-fork nameref optimization." >&2
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

shopt -s nullglob

# ==============================================================================
# HELPER FUNCTIONS (ZERO FORKS)
# ==============================================================================

# Safely read integers from sysfs without subshells.
# Usage: read_sysfs_int "/path" return_var_name
read_sysfs_int() {
    local -n _ret_ref=$2
    local _val
    # Native read. Using file descriptor instead of redirection pipeline.
    read -r _val < "$1" 2>/dev/null
    _val="${_val//[^0-9]/}"
    _ret_ref="${_val:-0}"
}

# Math check without subshells
# Usage: is_within_tolerance current target max return_var_name
is_within_tolerance() {
    local -n _ret_ref=$4
    local diff=$(( $1 - $2 ))
    diff="${diff#-}" 
    
    local tolerance=$(( $3 * 3 / 100 ))
    (( tolerance < 2 )) && tolerance=2 
    
    if (( diff <= tolerance )); then
        _ret_ref=1 # True
    else
        _ret_ref=0 # False
    fi
}

# Updates global variables GLOBAL_BAT_PERCENT directly
update_global_battery_percent() {
    local lowest_percent=100
    local battery_found=0
    local type_val scope_val
    local present_val b_now b_full pct

    for bat in /sys/class/power_supply/*; do
        [[ -f "$bat/present" ]] && { read_sysfs_int "$bat/present" present_val; (( present_val != 1 )) && continue; }
        
        if [[ -f "$bat/type" ]]; then
            read -r type_val < "$bat/type" 2>/dev/null
            if [[ "${type_val,,}" == *"battery"* ]]; then
                if [[ -f "$bat/scope" ]]; then
                    read -r scope_val < "$bat/scope" 2>/dev/null
                    [[ "${scope_val,,}" == *"device"* ]] && continue
                fi
                
                b_now=0; b_full=0
                
                if [[ -f "$bat/energy_now" && -f "$bat/energy_full" ]]; then
                    read_sysfs_int "$bat/energy_now" b_now
                    read_sysfs_int "$bat/energy_full" b_full
                elif [[ -f "$bat/charge_now" && -f "$bat/charge_full" ]]; then
                    read_sysfs_int "$bat/charge_now" b_now
                    read_sysfs_int "$bat/charge_full" b_full
                elif [[ -f "$bat/capacity" ]]; then
                    read_sysfs_int "$bat/capacity" b_now
                    b_full=100
                fi
                
                if (( b_full > 0 )); then
                    # NATIVE BASH MATH: Avoids awk and avoids 32-bit overflow by dividing the divisor first.
                    if (( b_full >= 100 )); then
                        pct=$(( b_now / (b_full / 100) ))
                    else
                        # Edge case where full capacity is physically less than 100 units
                        pct=$(( (b_now * 100) / b_full ))
                    fi
                    
                    (( pct > 100 )) && pct=100
                    
                    battery_found=1
                    (( pct < lowest_percent )) && lowest_percent=$pct
                fi
            fi
        fi
    done

    if (( battery_found == 1 )); then
        GLOBAL_BAT_PERCENT=$lowest_percent
    else
        GLOBAL_BAT_PERCENT="ERROR"
    fi
}

# Updates global variable GLOBAL_POWER_STATE directly
update_global_power_state() {
    local type_val status_val online_val
    GLOBAL_POWER_STATE="charging" # Default

    # AC Check
    for ac in /sys/class/power_supply/*; do
        if [[ -f "$ac/type" ]]; then
            read -r type_val < "$ac/type" 2>/dev/null
            type_val="${type_val,,}"
            if [[ "$type_val" == *"mains"* || "$type_val" == *"usb"* ]]; then
                read_sysfs_int "$ac/online" online_val
                if (( online_val == 1 )); then
                    GLOBAL_POWER_STATE="charging"
                    return
                fi
            fi
        fi
    done
    
    # Battery Check
    for bat in /sys/class/power_supply/*; do
        if [[ -f "$bat/type" && -f "$bat/status" ]]; then
            read -r type_val < "$bat/type" 2>/dev/null
            if [[ "${type_val,,}" == *"battery"* ]]; then
                read -r status_val < "$bat/status" 2>/dev/null
                if [[ "${status_val,,}" == "discharging" ]]; then
                    GLOBAL_POWER_STATE="discharging"
                    return
                fi
            fi
        fi
    done
}

# ==============================================================================
# INITIALIZATION
# ==============================================================================
# Use Hash Map (associative array) to guarantee $O(1) uniqueness natively
declare -A UNIQUE_BACKLIGHTS
for bl in /sys/class/backlight/intel_backlight /sys/class/backlight/amdgpu_bl* /sys/class/backlight/nv_backlight /sys/class/backlight/*; do
    if [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]]; then
        read_sysfs_int "$bl/max_brightness" _max_bl
        (( _max_bl > 0 )) && UNIQUE_BACKLIGHTS["$bl"]=1
    fi
done
VALID_BACKLIGHTS=("${!UNIQUE_BACKLIGHTS[@]}")

# Crash Recovery
if [[ -d "$STATE_DIR" ]]; then
    for bl in "${VALID_BACKLIGHTS[@]}"; do
        bl_name="${bl##*/}"
        state_file="$STATE_DIR/$bl_name"
        if [[ -f "$state_file" ]]; then
            logger -t battery-dimmer "Found stale state from crash. Restoring $bl_name."
            read_sysfs_int "$state_file" _stale_val
            echo "$_stale_val" > "$bl/brightness" 2>/dev/null
            rm -f "$state_file"
        fi
    done
fi

cleanup() {
    logger -t battery-dimmer "Service stopping. Restoring original brightness..."
    local _orig_val
    for bl in "${VALID_BACKLIGHTS[@]}"; do
        bl_name="${bl##*/}"
        state_file="$STATE_DIR/$bl_name"
        
        if [[ -f "$state_file" ]]; then
            read_sysfs_int "$state_file" _orig_val
            if (( _orig_val > 0 )) && [[ -w "$bl/brightness" ]]; then
                echo "$_orig_val" > "$bl/brightness" 2>/dev/null
            fi
        fi
    done
    rm -rf "$STATE_DIR"
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM SIGHUP

# ==============================================================================
# MAIN LOOP
# ==============================================================================
logger -t battery-dimmer "Service started. Threshold: ${THRESHOLD}%, Dim: ${DIM_BY_PERCENT}%"

# $SECONDS natively tracks time since script start with 0 CPU overhead
last_tick=$SECONDS
declare GLOBAL_BAT_PERCENT GLOBAL_POWER_STATE

while true; do
    current_tick=$SECONDS
    elapsed=$(( current_tick - last_tick ))
    
    if (( elapsed > 30 )); then
        SUSPEND_OCCURRED=1
    else
        SUSPEND_OCCURRED=0
    fi
    last_tick=$current_tick

    update_global_battery_percent
    update_global_power_state

    if [[ "$GLOBAL_BAT_PERCENT" == "ERROR" ]]; then
        sleep 15 & wait $!
        last_tick=$SECONDS
        continue
    fi

    if (( GLOBAL_BAT_PERCENT <= THRESHOLD )) && [[ "$GLOBAL_POWER_STATE" == "discharging" ]]; then
        for bl in "${VALID_BACKLIGHTS[@]}"; do
            [[ ! -w "$bl/brightness" ]] && continue
            
            bl_name="${bl##*/}"
            state_file="$STATE_DIR/$bl_name"
            override_file="$STATE_DIR/${bl_name}.override"

            [[ -f "$override_file" ]] && continue

            read_sysfs_int "$bl/brightness" CURRENT_BRIGHTNESS
            read_sysfs_int "$bl/max_brightness" MAX_BRIGHTNESS
            
            MIN_BRIGHTNESS=$(( MAX_BRIGHTNESS * MIN_PERCENT / 100 ))
            (( MIN_BRIGHTNESS <= 0 )) && MIN_BRIGHTNESS=1

            if [[ ! -f "$state_file" ]]; then
                TARGET_BRIGHTNESS=$(( CURRENT_BRIGHTNESS - (CURRENT_BRIGHTNESS * DIM_BY_PERCENT / 100) ))
                (( TARGET_BRIGHTNESS < MIN_BRIGHTNESS )) && TARGET_BRIGHTNESS=$MIN_BRIGHTNESS

                if (( CURRENT_BRIGHTNESS > TARGET_BRIGHTNESS )); then
                    echo "$CURRENT_BRIGHTNESS" > "$state_file"
                    echo "$TARGET_BRIGHTNESS" > "$bl/brightness" 2>/dev/null
                    logger -t battery-dimmer "Dimmed $bl_name by ${DIM_BY_PERCENT}% (Battery: ${GLOBAL_BAT_PERCENT}%)"
                fi
            else
                read_sysfs_int "$state_file" ORIGINAL_SAVED
                TARGET_BRIGHTNESS=$(( ORIGINAL_SAVED - (ORIGINAL_SAVED * DIM_BY_PERCENT / 100) ))
                (( TARGET_BRIGHTNESS < MIN_BRIGHTNESS )) && TARGET_BRIGHTNESS=$MIN_BRIGHTNESS

                is_within_tolerance "$CURRENT_BRIGHTNESS" "$TARGET_BRIGHTNESS" "$MAX_BRIGHTNESS" IN_TOLERANCE
                if (( IN_TOLERANCE == 0 )); then
                    if (( CURRENT_BRIGHTNESS == MAX_BRIGHTNESS )); then
                        if (( SUSPEND_OCCURRED == 1 )); then
                            logger -t battery-dimmer "Suspend/Resume detected on $bl_name. Re-applying dim."
                            echo "$TARGET_BRIGHTNESS" > "$bl/brightness" 2>/dev/null
                        else
                            rm -f "$state_file"
                            touch "$override_file"
                            logger -t battery-dimmer "User set 100%. Releasing control."
                        fi
                    else
                        rm -f "$state_file"
                        touch "$override_file"
                        logger -t battery-dimmer "Manual override on $bl_name. Releasing control."
                    fi
                fi
            fi
        done

    elif [[ "$GLOBAL_POWER_STATE" == "charging" ]] || (( GLOBAL_BAT_PERCENT > THRESHOLD )); then
        for bl in "${VALID_BACKLIGHTS[@]}"; do
            bl_name="${bl##*/}"
            state_file="$STATE_DIR/$bl_name"
            override_file="$STATE_DIR/${bl_name}.override"

            if [[ -f "$state_file" ]]; then
                read_sysfs_int "$state_file" ORIGINAL_SAVED
                read_sysfs_int "$bl/brightness" CURRENT_BRIGHTNESS
                read_sysfs_int "$bl/max_brightness" MAX_BRIGHTNESS
                
                DIMMED_SET=$(( ORIGINAL_SAVED - (ORIGINAL_SAVED * DIM_BY_PERCENT / 100) ))
                MIN_BRIGHTNESS=$(( MAX_BRIGHTNESS * MIN_PERCENT / 100 ))
                (( MIN_BRIGHTNESS <= 0 )) && MIN_BRIGHTNESS=1
                (( DIMMED_SET < MIN_BRIGHTNESS )) && DIMMED_SET=$MIN_BRIGHTNESS

                is_within_tolerance "$CURRENT_BRIGHTNESS" "$DIMMED_SET" "$MAX_BRIGHTNESS" IN_TOLERANCE
                if (( IN_TOLERANCE == 1 )) && [[ -w "$bl/brightness" ]]; then
                    echo "$ORIGINAL_SAVED" > "$bl/brightness" 2>/dev/null
                    logger -t battery-dimmer "Restored $bl_name to original brightness."
                else
                    logger -t battery-dimmer "Override detected on $bl_name. Keeping current brightness."
                fi
                rm -f "$state_file"
            fi
            
            if [[ -f "$override_file" ]]; then
                rm -f "$override_file"
                logger -t battery-dimmer "Cleared override for $bl_name."
            fi
        done
    fi

    sleep 10 & wait $!
done
