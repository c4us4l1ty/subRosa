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
