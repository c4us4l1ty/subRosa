 **if no printer is used.**
 `sudo dnf remove \
  cups \
  cups-browsed \
  cups-filters \
  cups-pk-helper \
  gutenprint \
  hplip \
  system-config-printer-udev`

Open Terminal.
Run: `sudo nano /var/lib/AccountsService/users/$USER` Look for a line beginning with Icon=. Remove that line, if present. Log out and log back in.
Important: This may restore the default avatar or the “V” rather than hide the picture completely. GNOME normally displays a fallback avatar, so removing it entirely may require changing desktop environment code or configuration.

1. Open Terminal and run: `sudo ls -l /var/lib/AccountsService/icons/`
Look for a file matching your username.
2. Make a backup of the avatar file
Replace YOUR_USERNAME with your Linux username: `sudo cp /var/lib/AccountsService/icons/YOUR_USERNAME /var/lib/AccountsService/icons/YOUR_USERNAME.bak`
3. Empty the avatar file: `sudo truncate -s 0 /var/lib/AccountsService/icons/YOUR_USERNAME`
4. Log out and log back in to check the result.
If the avatar doesn't disappear or GNOME restores the “V”, restore the backup:  `sudo cp /var/lib/AccountsService/icons/YOUR_USERNAME.bak /var/lib/AccountsService/icons/YOUR_USERNAME`

*Important: This workaround is not guaranteed to work on every Fedora/GNOME version. It may produce a broken or fallback avatar rather than removing the circle completely. If you mean removing the circle entirely from the login screen, that requires a different approach.*

**Step 1: Create the Firefox policy file**
Open a terminal and run:
```sh

sudo mkdir -p /etc/firefox/policies
sudo nano /etc/firefox/policies/policies.json`
```

Paste this configuration into the editor:
```sh
{
  "policies": {
    "PrivateBrowsingModeAvailability": 1,
    "BlockAboutProfiles": true,
    "WebsiteFilter": {
      "Block": [
        "*://proxyium.com/*",
        "*://*.proxyium.com/*"
      ]
    }
  }
}
```

Step 3: Restart and verify

    Close all Firefox windows.
    Reopen Firefox.
    Type this into the address bar:
    about:policies
    Open the Active tab.

You should see PrivateBrowsingModeAvailability and WebsiteFilter listed among the active policies.

