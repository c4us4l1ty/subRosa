1. **Move script to root directory:** Prerequisite.
Move the script to `/usr/local/bin/` so system root processes can execute it safely:

```bash
sudo mv ~/Downloads/battery-dimmer.sh /usr/local/bin/battery-dimmer.sh
sudo chmod +x /usr/local/bin/battery-dimmer.sh

```


2. **Create the system service unit:**
Create the system-wide service unit file using `sudo`:

```bash
sudo nano /etc/systemd/system/battery-dimmer.service

```

Paste the following configuration:

```ini
[Unit]
Description=Battery Dimmer Background Service
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/battery-dimmer.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target

```


3. **Enable and start root service:**
Reload systemd, enable the service to start automatically on boot, and run it immediately:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now battery-dimmer.service

```


To verify that the service is running successfully as root:

```bash
sudo systemctl status battery-dimmer.service

```

*If functioning properly, you will see `Active: active (running)` in green text.*


The exit status **`status=203/EXEC`** means systemd tried to execute the script, but the system could not run the file.

This usually happens for one of three reasons:

1. **Missing Shebang:** The first line of `/usr/local/bin/battery-dimmer.sh` isn't `#!/bin/bash` or `#!/usr/bin/env bash`.
2. **Windows Line Endings:** The script has `\r\n` (CRLF) line endings instead of Unix `\n` (LF).
3. **SELinux context:** Fedora blocked execution due to SELinux security context.

Run this single command in your terminal to fix line endings, ensure permissions, fix SELinux context, and restart the service:

```bash
sudo sed -i 's/\r$//' /usr/local/bin/battery-dimmer.sh && \
sudo chmod 755 /usr/local/bin/battery-dimmer.sh && \
sudo restorecon -v /usr/local/bin/battery-dimmer.sh && \
sudo systemctl restart battery-dimmer.service

```

To verify if the script is running, check its status:

```bash
sudo systemctl status battery-dimmer.service

```

*If fixed, it will output `Active: active (running)`.*



btw i could've written...

```bash

#!/bin/bash

while true; do
    battery=$(cat /sys/class/power_supply/BAT0/capacity)

    if [ "$battery" -le 50 ]; then
        xrandr --output eDP-1 --brightness 0.7
    else
        xrandr --output eDP-1 --brightness 1
    fi

    sleep 30
done
```
