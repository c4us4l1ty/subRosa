sudo dnf remove kmines kpat elisa dragonplayer kolourpaint kamoso neochat kmail kaddressbook korganizer akregator kontact kleopatra krdc krfb skanpage partitionmanager filelight kcharselect kcalc gwenview okular

sudo dnf remove kmines kpat elisa dragonplayer kolourpaint kamoso neochat kmail kaddressbook korganizer akregator kontact kleopatra krdc krfb skanpage partitionmanager filelight kcharselect kcalc gwenview okular libreoffice\*

sudo dnf remove plasma-discover
sudo dnf autoremove

sudo dnf remove \
  ark \
  elisa \
  kdeconnect \
  kdeconnect-sms \
  kjournaldbrowser \
  kmouth \
  kwalletmanager \
  orca

  dnf repoquery --userinstalled --qf '%{name}' | sort   #use this to see installed packages

  sudo dnf remove \
  open-vm-tools-desktop \
  qemu-guest-agent \
  spice-vdagent \
  spice-webdavd \
  hyperv-daemons \
  virtualbox-guest-additions

  #if no printer is used.
  sudo dnf remove \
  cups \
  cups-browsed \
  cups-filters \
  cups-pk-helper \
  gutenprint \
  hplip \
  system-config-printer-udev

  sudo dnf remove kde-connect
  sudo dnf remove fprintd fprintd-pam #Remove fingerprint support
  sudo dnf remove flatpak-kcm plasma-discover-flatpak
  dnf repoquery --whatrequires flatpak  #You will probably still see things such as Anaconda, but don't remove Anaconda just to get rid of Flatpak unless you specifically want to remove Fedora's installer components.
  sudo rm -f /etc/flatpak/remotes.d/fedora-flathub.repo
  sudo dnf autoremove

  sudo dnf upgrade --refresh
  systemctl reboot




Open Terminal.
Run:
bash
sudo nano /var/lib/AccountsService/users/$USER
Look for a line beginning with Icon=.
Remove that line, if present.
Save with Ctrl+O, press Enter, then exit with Ctrl+X.
Log out and log back in.
Important: This may restore the default avatar or the “V” rather than hide the picture completely. GNOME normally displays a fallback avatar, so removing it entirely may require changing desktop environment code or configuration.


Steps for Fedora
1. Open Terminal and run:
bash
sudo ls -l /var/lib/AccountsService/icons/
Look for a file matching your username.
2. Make a backup of the avatar file
Replace YOUR_USERNAME with your Linux username:
bash
sudo cp /var/lib/AccountsService/icons/YOUR_USERNAME /var/lib/AccountsService/icons/YOUR_USERNAME.bak
3. Empty the avatar file
bash
sudo truncate -s 0 /var/lib/AccountsService/icons/YOUR_USERNAME
4. Log out and log back in to check the result.
If the avatar doesn't disappear or GNOME restores the “V”, restore the backup:
bash
sudo cp /var/lib/AccountsService/icons/YOUR_USERNAME.bak /var/lib/AccountsService/icons/YOUR_USERNAME
Important: This workaround is not guaranteed to work on every Fedora/GNOME version. It may produce a broken or fallback avatar rather than removing the circle completely. If you mean removing the circle entirely from the login screen, that requires a different approach.



