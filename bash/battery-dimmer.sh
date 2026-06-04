#!/bin/bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================
THRESHOLD=50       # Battery percentage to trigger dimming
DIM_BY_PERCENT=30  # Reduce current brightness by this percentage
MIN_PERCENT=5      # Safety: Never let brightness drop below this % of max

# State directory in tmpfs (RAM) for fast, wear-free reads/writes
STATE_DIR="/run/battery-dimmer"
# Lock file MUST be inside the state directory to ensure clean deletion
LOCK_FILE="$STATE_DIR/lock"

# ==============================================================================
# INITIALIZATION & SAFETY CHECKS
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root to modify screen brightness." >&2
    exit 1
fi

# Create state directory BEFORE taking the lock
mkdir -p "$STATE_DIR"

# Prevent multiple instances safely using flock (File Descriptor 9)
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "Error: Service is already running." >&2
    exit 1
fi

# Ensure globs that don't match anything return empty instead of a literal '*'
shopt -s nullglob

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# Safely read integers from sysfs, stripping non-numeric characters
read_sysfs_int() {
    local val
    # Native bash read. No 'cat' binary spawned.
    read -r val 2>/dev/null < "$1"
    val="${val//[^0-9]/}" # Strip everything except numbers
    echo "${val:-0}"      # Default to 0 if empty
}

# Check if a value is within a 3% tolerance of a target
is_within_tolerance() {
    local current=$1 target=$2 max=$3
    local diff=$(( current - target ))
    diff="${diff#-}" # Absolute value (remove minus sign)
    
    # Calculate 3% tolerance. 
    local tolerance=$(( max * 3 / 100 ))
    
    # Ensure a minimum floor of 2 for displays with tiny scales (e.g., max = 15)
    [ "$tolerance" -lt 2 ] && tolerance=2 
    
    [ "$diff" -le "$tolerance" ]
}

# Find the lowest battery percentage to prevent unexpected shutdowns on multi-battery systems
get_global_battery_percent() {
    local lowest_percent=100
    local battery_found=0
    local type_val scope_val

    for bat in /sys/class/power_supply/*; do
        # Ensure battery is physically present
        [ -f "$bat/present" ] && [ "$(read_sysfs_int "$bat/present")" -ne 1 ] && continue
        
        if [ -f "$bat/type" ]; then
            read -r type_val 2>/dev/null < "$bat/type"
            # Native case-insensitive match
            if [[ "${type_val,,}" == *"battery"* ]]; then
                # Ignore peripheral batteries (mice, keyboards, UPS)
                if [ -f "$bat/scope" ]; then
                    read -r scope_val 2>/dev/null < "$bat/scope"
                    [[ "${scope_val,,}" == *"device"* ]] && continue
                fi
                
                local b_now=0 b_full=0
                
                # Prefer energy (Wh), fallback to charge (Ah), fallback to capacity (%)
                if [ -f "$bat/energy_now" ] && [ -f "$bat/energy_full" ]; then
                    b_now=$(read_sysfs_int "$bat/energy_now")
                    b_full=$(read_sysfs_int "$bat/energy_full")
                elif [ -f "$bat/charge_now" ] && [ -f "$bat/charge_full" ]; then
                    b_now=$(read_sysfs_int "$bat/charge_now")
                    b_full=$(read_sysfs_int "$bat/charge_full")
                elif [ -f "$bat/capacity" ]; then
                    b_now=$(read_sysfs_int "$bat/capacity")
                    b_full=100
                fi
                
                if [ "$b_full" -gt 0 ]; then
                    # Use awk to prevent 32-bit integer overflow on systems with large values
                    local pct
                    pct=$(awk "BEGIN {printf \"%d\", ($b_now * 100) / $b_full}")
                    battery_found=1
                    
                    # Keep track of the lowest percentage across all batteries
                    [ "$pct" -lt "$lowest_percent" ] && lowest_percent=$pct
                fi
            fi
        fi
    done

    if [ "$battery_found" -eq 1 ]; then
        echo "$lowest_percent"
    else
        echo "ERROR"
    fi
}

get_global_power_state() {
    local type_val status_val

    # 1. Check AC Adapters and USB-C PD
    for ac in /sys/class/power_supply/*; do
        if [ -f "$ac/type" ]; then
            read -r type_val 2>/dev/null < "$ac/type"
            type_val="${type_val,,}" # Convert to lowercase natively
            if [[ "$type_val" == *"mains"* || "$type_val" == *"usb"* ]]; then
                if [ "$(read_sysfs_int "$ac/online")" -eq 1 ]; then
                    echo "charging"
                    return
                fi
            fi
        fi
    done
    
    # 2. Fallback: Check battery statuses (Handles Conservation Modes)
    for bat in /sys/class/power_supply/*; do
        if [ -f "$bat/type" ] && [ -f "$bat/status" ]; then
            read -r type_val 2>/dev/null < "$bat/type"
            if [[ "${type_val,,}" == *"battery"* ]]; then
                read -r status_val 2>/dev/null < "$bat/status"
                status_val="${status_val,,}"
                # Added "Unknown" to handle certain ACPI drivers when fully charged
                if [[ "$status_val" == *"charging"* || "$status_val" == *"full"* || "$status_val" == *"not charging"* || "$status_val" == *"unknown"* ]]; then
                    echo "charging"
                    return
                fi
            fi
        fi
    done

    echo "discharging"
}

get_valid_backlights() {
    local valid_bls=()
    # Prioritize native GPU backlights over generic ACPI ones to avoid conflicts
    for bl in /sys/class/backlight/intel_backlight /sys/class/backlight/amdgpu_bl* /sys/class/backlight/nv_backlight /sys/class/backlight/*; do
        if [ -f "$bl/brightness" ] && [ -f "$bl/max_brightness" ]; then
            local max
            max=$(read_sysfs_int "$bl/max_brightness")
            if [ "$max" -gt 0 ]; then
                # Prevent duplicates if globbing overlaps
                local found=0
                for existing in "${valid_bls[@]}"; do
                    if [[ "$existing" == "$bl" ]]; then
                        found=1
                        break
                    fi
                done
                if [[ "$found" -eq 0 ]]; then
                    valid_bls+=("$bl")
                fi
            fi
        fi
    done
    printf "%s\n" "${valid_bls[@]}"
}

# Cache valid backlights in an array to avoid re-evaluating sysfs directories every 10 seconds
mapfile -t VALID_BACKLIGHTS < <(get_valid_backlights)

# ==============================================================================
# CRASH RECOVERY
# ==============================================================================
# If the script was killed with `kill -9`, the trap wouldn't have fired.
# Restore brightness from stale state files before starting the main loop.
if [ -d "$STATE_DIR" ]; then
    for bl in "${VALID_BACKLIGHTS[@]}"; do
        bl_name="${bl##*/}" # Native basename
        state_file="$STATE_DIR/$bl_name"
        if [ -f "$state_file" ]; then
            logger -t battery-dimmer "Found stale state from crash. Restoring $bl_name."
            echo "$(read_sysfs_int "$state_file")" > "$bl/brightness" 2>/dev/null
            rm -f "$state_file"
        fi
    done
fi

# ==============================================================================
# CLEANUP / RESTORE ON EXIT
# ==============================================================================
cleanup() {
    logger -t battery-dimmer "Service stopping. Restoring original brightness..."
    for bl in "${VALID_BACKLIGHTS[@]}"; do
        local bl_name="${bl##*/}"
        local state_file="$STATE_DIR/$bl_name"
        
        if [ -f "$state_file" ]; then
            local original_val=$(read_sysfs_int "$state_file")
            if [ "$original_val" -gt 0 ]; then
                echo "$original_val" > "$bl/brightness" 2>/dev/null
            fi
        fi
    done
    # Wipe the entire state directory, cleanly removing the lock file and overrides
    rm -rf "$STATE_DIR"
    exit 0
}

# Trap standard termination signals to ensure cleanup runs
trap cleanup EXIT SIGINT SIGTERM SIGHUP

# ==============================================================================
# MAIN LOOP
# ==============================================================================
logger -t battery-dimmer "Service started. Threshold: ${THRESHOLD}%, Dim: ${DIM_BY_PERCENT}%"

while true; do
    BAT_PERCENT=$(get_global_battery_percent)
    STATE=$(get_global_power_state)

    if [ "$BAT_PERCENT" = "ERROR" ]; then
        sleep 15
        continue
    fi

    # ---------------------------------------------------------
    # DIMMING LOGIC (Battery low AND Discharging)
    # ---------------------------------------------------------
    if [ "$BAT_PERCENT" -le "$THRESHOLD" ] && [ "$STATE" = "discharging" ]; then
        for bl in "${VALID_BACKLIGHTS[@]}"; do
            bl_name="${bl##*/}"
            state_file="$STATE_DIR/$bl_name"
            override_file="$STATE_DIR/${bl_name}.override"

            # If user previously overrode the dimming, respect it until plugged in
            if [ -f "$override_file" ]; then
                continue
            fi

            CURRENT_BRIGHTNESS=$(read_sysfs_int "$bl/brightness")
            MAX_BRIGHTNESS=$(read_sysfs_int "$bl/max_brightness")
            MIN_BRIGHTNESS=$(( MAX_BRIGHTNESS * MIN_PERCENT / 100 ))

            if [ ! -f "$state_file" ]; then
                # FIRST TIME DIMMING: Save original and dim
                TARGET_BRIGHTNESS=$(( CURRENT_BRIGHTNESS - (CURRENT_BRIGHTNESS * DIM_BY_PERCENT / 100) ))
                [ "$TARGET_BRIGHTNESS" -lt "$MIN_BRIGHTNESS" ] && TARGET_BRIGHTNESS=$MIN_BRIGHTNESS

                if [ "$CURRENT_BRIGHTNESS" -gt "$TARGET_BRIGHTNESS" ]; then
                    echo "$CURRENT_BRIGHTNESS" > "$state_file"
                    echo "$TARGET_BRIGHTNESS" > "$bl/brightness" 2>/dev/null
                    logger -t battery-dimmer "Dimmed $bl_name by ${DIM_BY_PERCENT}% (Battery: ${BAT_PERCENT}%)"
                fi
            else
                # STATE EXISTS: Check if brightness has drifted from our target
                ORIGINAL_SAVED=$(read_sysfs_int "$state_file")
                TARGET_BRIGHTNESS=$(( ORIGINAL_SAVED - (ORIGINAL_SAVED * DIM_BY_PERCENT / 100) ))
                [ "$TARGET_BRIGHTNESS" -lt "$MIN_BRIGHTNESS" ] && TARGET_BRIGHTNESS=$MIN_BRIGHTNESS

                if ! is_within_tolerance "$CURRENT_BRIGHTNESS" "$TARGET_BRIGHTNESS" "$MAX_BRIGHTNESS"; then
                    if [ "$CURRENT_BRIGHTNESS" -eq "$MAX_BRIGHTNESS" ]; then
                        # Check if the kernel actually just woke from suspend in the last 15 seconds
                        if journalctl -k --since "15 seconds ago" 2>/dev/null | grep -qiE "ACPI: PM: Waking up|Suspended|suspend entry|PM: suspend"; then
                            logger -t battery-dimmer "Suspend/Resume detected on $bl_name. Re-applying dim."
                            echo "$TARGET_BRIGHTNESS" > "$bl/brightness" 2>/dev/null
                        else
                            # No suspend detected. The user actually dragged the slider to 100%.
                            rm -f "$state_file"
                            touch "$override_file"
                            logger -t battery-dimmer "User manually set brightness to 100%. Releasing control."
                        fi
                    else
                        # Actual user override detected (e.g., they moved it to 50%)
                        rm -f "$state_file"
                        touch "$override_file"
                        logger -t battery-dimmer "Brightness change detected on $bl_name. Assuming user override and releasing control."
                    fi
                fi
            fi
        done

    # ---------------------------------------------------------
    # RESTORE LOGIC (Charging, Full, or Above Threshold)
    # ---------------------------------------------------------
    elif [ "$STATE" = "charging" ] || [ "$BAT_PERCENT" -gt "$THRESHOLD" ]; then
        for bl in "${VALID_BACKLIGHTS[@]}"; do
            bl_name="${bl##*/}"
            state_file="$STATE_DIR/$bl_name"
            override_file="$STATE_DIR/${bl_name}.override"

            if [ -f "$state_file" ]; then
                ORIGINAL_SAVED=$(read_sysfs_int "$state_file")
                CURRENT_BRIGHTNESS=$(read_sysfs_int "$bl/brightness")
                MAX_BRIGHTNESS=$(read_sysfs_int "$bl/max_brightness")
                
                # Calculate what the dimmed value *was* to check if user overrode it
                DIMMED_SET=$(( ORIGINAL_SAVED - (ORIGINAL_SAVED * DIM_BY_PERCENT / 100) ))
                MIN_BRIGHTNESS=$(( MAX_BRIGHTNESS * MIN_PERCENT / 100 ))
                [ "$DIMMED_SET" -lt "$MIN_BRIGHTNESS" ] && DIMMED_SET=$MIN_BRIGHTNESS

                if is_within_tolerance "$CURRENT_BRIGHTNESS" "$DIMMED_SET" "$MAX_BRIGHTNESS"; then
                    # User hasn't touched it. Restore original.
                    echo "$ORIGINAL_SAVED" > "$bl/brightness" 2>/dev/null
                    logger -t battery-dimmer "Restored $bl_name to original brightness."
                else
                    logger -t battery-dimmer "User manual override detected on $bl_name. Keeping current brightness."
                fi
                
                # Always remove state file when charging/above threshold
                rm -f "$state_file"
            fi
            
            # Clear any overrides when power is restored
            if [ -f "$override_file" ]; then
                rm -f "$override_file"
                logger -t battery-dimmer "Cleared override for $bl_name."
            fi
        done
    fi

    sleep 10
done