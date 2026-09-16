```markdown
This guide details the steps taken to fix severe battery drain on Fedora by removing conflicting power daemons, installing TLP, verifying device power states, and optimizing browser settings.

---

## 1. Replace Default Power Daemon with TLP

Fedora ships with `tuned` / `power-profiles-daemon` by default. Running multiple power managers creates conflicts and drains battery.

### Remove conflicting daemons & install TLP
```bash
# Remove default power managers
sudo dnf remove power-profiles-daemon tuned

# Install TLP and its radio device wizard
sudo dnf install tlp tlp-rdw

# Enable and start the service
sudo systemctl enable --now tlp
sudo tlp start

```

### Verify TLP Status

```bash
# Verify TLP is active
sudo tlp-stat -s

# Check battery status and current power discharge rate (Watts)
sudo tlp-stat -b

```

> **Target:** Normal idle baseline power consumption on battery should be **under 10W**.

---

## 2. Check & Disable Discrete GPU Drain

If your laptop has a dedicated NVIDIA GPU, it may stay powered on in high-performance mode continuously.

### Diagnostic & Driver Switching

```bash
# Check if NVIDIA GPU is actively drawing power
nvidia-smi

# If drawing high power while idle on battery, switch to Integrated/Hybrid graphics
prime-select intel   # or 'amd', depending on your CPU vendor

```

---

## 3. Identify Power Drainers (PowerTOP)

Use `powertop` to monitor real-time discharge rates and process consumption.

```bash
# Install PowerTOP
sudo dnf install powertop

# Launch diagnostic tool
sudo powertop

```

* Use `Tab` to navigate to the **Overview** tab to see process power consumption and the current `Discharge rate`.

---

## 4. Enable Hardware Video Acceleration (Browser Fix)

Without hardware acceleration, playing videos in Firefox/Chrome forces the CPU to decode video streams, rapidly draining battery.

### Firefox Configuration

1. Open Firefox and type `about:config` into the address bar.
2. Search for and set the following keys to `true`:
* `media.ffmpeg.vaapi.enabled` -> `true`
* `media.hardware-video-decoding.enabled` -> `true`



### Verification

* Navigate to `about:support` in Firefox.
* Scroll to **Graphics** and ensure `HARDWARE_VIDEO_DECODING` is listed as **default available**.

---

## 5. Advanced Power Checks

### Verify PCI Express ASPM (Sleep States)

Ensure high-speed interfaces (NVMe, Wi-Fi) enter low-power states when idle:

```bash
sudo tlp-stat -e

```

* Confirm that ASPM policies report as `powersave` or `default`.

### Prevent Tracker Indexer CPU Spikes

Check if GNOME file indexing (`tracker3`) is using background CPU cycles:

```bash
tracker3 status

```

* If indexing is stuck or consuming heavy CPU, go to **Settings → Search** in GNOME and toggle off unused locations.

---

## Quick Reference Commands

| Command | Purpose |
| --- | --- |
| `sudo tlp start` | Manually apply current TLP power profile |
| `sudo tlp bat` | Force TLP into Battery mode immediately |
| `sudo tlp-stat -s` | Show current active TLP mode and state |
| `sudo tlp-stat -b` | View detailed battery health & power draw (Watts) |

Severe battery drain on Linux is usually caused by an active discrete GPU (NVIDIA/AMD) running in high-performance mode continuously or by aggressive CPU boosting.

3. **Replace Default Power Manager with TLP:** Advanced Optimization.
Fedora's default manager (`tuned` or `power-profiles-daemon`) often fails to apply aggressive sleep states. Replace it with TLP:

```bash
sudo dnf remove power-profiles-daemon tuned
sudo dnf install tlp tlp-rdw
sudo systemctl enable --now tlp

```

*Verification:* Run `sudo tlp-stat -s` to ensure TLP is active and managing power.


4. **Enable Video Hardware Acceleration:** Browser Fix.
Web browsers (Firefox/Chrome) without hardware acceleration render videos using CPU threads, draining significant power.

In Firefox, navigate to `about:config` and verify:

* `media.ffmpeg.vaapi.enabled` is set to `true`.
* `media.hardware-video-decoding.enabled` is set to `true`.

*Verification:* Open `about:support` in Firefox and check under **Graphics** to confirm `HARDWARE_VIDEO_DECODING` is marked as `default available`.

The 3 black holes eating you right now
Hole #1: Userspace inferno - 90%+ of a core burned continuously
opencode: 57.7% CPU, 715MB - this very session, node churn
firefox: 26.1% + tab 11.1% + tab 9.9% + tab 3.7% = ~50% sustained
gnome-shell: 8.7% avg, 159 MINUTES CPU in 30h uptime - ABNORMAL
gnome-shell should be <1-2%. 8.7% + kworker/i915_flip in top means Mutter is compositing nonstop at 1920x1200@60 + 1.25 fractional scale - fractional scaling on Intel UHD costs ~1-2W alone. Combined Firefox RSS ~2GB across 8 contentprocs keeps package C-states from ever going deep. CPUs stuck at ~1500MHz idle, only one core reaches 400MHz.
Your loadavg 1.04, vmstat us 10-14% sy 3% id 83-91% confirms: never truly idle.
Hole #2: Sleep that isn't sleep
mem_sleep: [s2idle] - no S3 deep sleep available
suspend_stats: success 3 only
uptime: 1 day 6:24, sleep-inactive-battery-timeout: 900s
Last suspend: 13:28 -> 13:48 (20 min s2idle)
idle-delay: 60s
You basically never suspend. s2idle on Raptor Lake-P drains 3-7W - close the lid overnight = dead by morning. No power-profiles-daemon, you run TLP + thermald instead. TLP defaults are active (PLATFORM_PROFILE_ON_BAT=balanced, ON_SAV=low-power - you are in low-power now, good), but:
WIFI_PWR_ON_BAT=on should save, yet iwlwifi Unhandled alg: 0x703 spams journal every 2-5 min - firmware bug that wakes the radio
Bluetooth: Powered: yes, PowerState: on + kworker/hci0 active - ~0.5-1W for nothing
Idle C-states exposed as POLL / C1_ACPI / C2_ACPI / C3_ACPI only - no deep PC8-PC10 residency visible, so idle floor is ~7W instead of 3-4W achievable
Display is innocent right now: 3247 / 21333 = 15% brightness. Good.
Hole #3: 30-hour cruft + firmware age
BIOS QDCN23WW 01/02/2025 - 20 months old, missing Raptor Lake + AX201 power fixes
thermald active 35s CPU, btrfs-endio-meta kworkers churning, zram 613MB used, swappiness 60, 1.2GB shared - memory pressure from Firefox+opencode forces compression + IO
No failed units, no autostart, no flatpak, only background-logo extension - so it's not bloat, it's workload + s2idle.
Why it feels sudden: at 7.7W you get 4.4h. Open 1 YouTube / Meet / compile and H-chip jumps to 20-30W. 50Wh vanishes. Plus if you "sleep" with s2idle, you lose 15-25% overnight.
3. Fix it without downloading anything
No dnf install, only what you have:
# 1. Kill the BT vampire (instant 0.5-1W)
bluetoothctl power off
rfkill block bluetooth
# re-enable only when needed: rfkill unblock bluetooth; bluetoothctl power on

# 2. Force wifi powersave + check it sticks on battery
iw dev wlp0s20f3 set power_save on
iw dev wlp0s20f3 get power_save
# TLP already wants WIFI_PWR_ON_BAT=on, but verify after unplug:
cat /sys/module/iwlwifi/parameters/power_save

# 3. Put TLP into true battery savior (edit, no new pkg)
sudoedit /etc/tlp.d/01-battery.conf
# paste:
PLATFORM_PROFILE_ON_BAT=low-power
CPU_ENERGY_PERF_POLICY_ON_BAT=power
PCIE_ASPM_ON_BAT=powersupersave
USB_AUTOSUSPEND=1
# then:
sudo tlp start

# 4. Restart the leaking gnome-shell (saves reboot, frees ~200MB + drops 8% -> 1%)
# press Alt+F2, type r, Enter (Wayland: log out/in instead)
# or:
killall -3 gnome-shell

# 5. Contain Firefox - biggest win
# about:config -> media.ffmpeg.vaapi.enabled=true (Intel UHD decode, -3-5W on video)
# about:processes -> kill the 640MB/500MB tabs, use auto-suspend addon, limit to <6 tabs on battery
# gsettings: dim faster
gsettings set org.gnome.desktop.session idle-delay 60
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 300
gsettings set org.gnome.settings-daemon.plugins.power idle-dim true

# 6. Stop s2idle overnight death: hibernate or shutdown, don't just close lid
systemctl suspend  # check drain: cat /sys/class/power_supply/BAT0/energy_now before/after
# if you lose >5% in 1h s2idle, use:
systemctl hibernate
# or shutdown for overnight
Verify after:
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep -E "energy-rate|percentage|time to empty"
ps aux --sort=-%cpu | head -n 10
journalctl -b | grep -c "Unhandled alg: 0x703"
Target: energy-rate: 4.5-5.5W idle at 15% brightness with BT off + Firefox tamed = 8-9h theoretical, 6h real. If you stay at 7-9W, that's your floor with this H-chip + 1.25 scale + current workload - physics, not a fault.
If drain in s2idle is still >3W/h after BT off, that's BIOS/firmware - only fix is Lenovo BIOS update + mem_sleep_default=deep if your board ever gets S3, which this one currently doesn't expose.
