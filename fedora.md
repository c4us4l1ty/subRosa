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




