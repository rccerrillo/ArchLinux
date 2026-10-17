#!/usr/bin/env bash
# =============================================================================
# 02-post-install.sh
# Post-install for the LUKS2 + Btrfs + GRUB Arch build.
#
# Run as your NORMAL USER (with sudo) after first boot and network connect.
# Covers guide steps 13-18:
#   13. KDE Plasma desktop + services
#   14. Snapper, snap-pac, btrfs-assistant, bootable snapshots
#   15. paru (AUR helper)
#   16. Apps, tools, printing, VPNs + their services
#   17. Virtualization (QEMU/KVM/libvirt, TPM, SMB)
#   18. Flatpak apps
#   19. Vendor / AUR apps (Brave Origin, RealVNC Viewer)
#   20. Firewall (UFW: deny incoming, allow outgoing)
# Mirrors are ranked with reflector before the first system update.
# Each step can be skipped, and steps already done are detected and skipped.
# =============================================================================
set -Eeuo pipefail

# ---------- settings ---------------------------------------------------------
REFLECTOR_COUNTRY="US"   # comma-separated list is fine, e.g. "US,CA"

# ---------- helpers ----------------------------------------------------------
c_info=$'\e[1;36m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
trap 'printf "%sERROR:%s line %s: %s\n" "$c_err" "$c_off" "$LINENO" "$BASH_COMMAND" >&2' ERR

yesno() {
  local prompt=$1 default=$2 reply hint
  [[ $default == y ]] && hint="Y/n" || hint="y/N"
  read -rp "$prompt [$hint]: " reply
  reply=${reply:-$default}
  [[ ${reply,,} == y* ]]
}

# set_cfg FILE KEY VALUE  -> sets KEY="VALUE" in a shell-style config file
set_cfg() {
  local file=$1 key=$2 value=$3
  if sudo grep -q "^${key}=" "$file"; then
    sudo sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
  else
    echo "${key}=\"${value}\"" | sudo tee -a "$file" >/dev/null
  fi
}

# =============================================================================
# Pre-flight
# =============================================================================
info "Pre-flight checks"
[[ $EUID -ne 0 ]] || die "Run as your normal user, not root (makepkg refuses root)."
sudo -v || die "sudo is not working for $USER."
# keep sudo alive for the duration of the script
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 \
  || die "No network. Connect first: nmcli device wifi connect \"SSID\" --ask"
ok "Network up, sudo OK"

# =============================================================================
# pacman.conf: color output + 10 parallel downloads
# =============================================================================
info "Configuring pacman (Color, ParallelDownloads = 10)"
PACCONF=/etc/pacman.conf
sudo cp -n "$PACCONF" "$PACCONF.bak"
sudo sed -i 's/^#\s*Color\s*$/Color/' "$PACCONF"
if grep -Eq '^#?\s*ParallelDownloads' "$PACCONF"; then
  sudo sed -i -E 's/^#?\s*ParallelDownloads\s*=.*/ParallelDownloads = 10/' "$PACCONF"
else
  sudo sed -i '/^\[options\]/a ParallelDownloads = 10' "$PACCONF"
fi
grep -q '^Color' "$PACCONF" || sudo sed -i '/^\[options\]/a Color' "$PACCONF"
grep -q '^Color' "$PACCONF" || die "Failed to enable Color in $PACCONF."
grep -q '^ParallelDownloads = 10' "$PACCONF" || die "Failed to set ParallelDownloads in $PACCONF."
ok "pacman.conf updated (backup at $PACCONF.bak)"

# =============================================================================
# Reflector: rank mirrors before the first big download
# =============================================================================
info "Installing and configuring reflector"
sudo pacman -S --needed --noconfirm reflector

sudo tee /etc/xdg/reflector/reflector.conf >/dev/null <<EOF
# Managed by 02-post-install.sh
--country ${REFLECTOR_COUNTRY}
--protocol https
--latest 20
--fastest 5
--age 8
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

sudo cp -n /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
if sudo systemctl start reflector.service; then
  ok "Mirrors ranked (backup at /etc/pacman.d/mirrorlist.bak)"
else
  warn "reflector run failed; keeping existing mirrorlist"
fi
sudo systemctl enable reflector.service reflector.timer
ok "reflector.service (boot) and reflector.timer (weekly) enabled"

info "Updating system"
sudo pacman -Syu --noconfirm

# =============================================================================
# 13. KDE Plasma
# =============================================================================
if yesno "Step 13: install KDE Plasma?" y; then
  info "Installing KDE Plasma"
  PLASMA_PKGS=(
    plasma-desktop
    plasma-login-manager
    plasma-nm networkmanager
    bluedevil bluez bluez-utils
    powerdevil power-profiles-daemon
    plasma-pa pipewire pipewire-pulse wireplumber
    kscreen
    xdg-desktop-portal-kde
    konsole dolphin dolphin-plugins kate
    breeze-gtk kde-gtk-config
    noto-fonts
    kwallet kwalletmanager kwallet-pam ksshaskpass
    kdeplasma-addons
    discover
    spectacle
  )
  sudo pacman -S --needed --noconfirm "${PLASMA_PKGS[@]}"

  # -f replaces any other enabled display manager (e.g. sddm)
  sudo systemctl enable -f plasmalogin.service
  sudo systemctl enable bluetooth.service power-profiles-daemon.service
  ok "Plasma installed; plasmalogin, bluetooth, power-profiles-daemon enabled"
  warn "KWallet auto-unlock: when asked to create a wallet, use Blowfish and your login password."
fi

# =============================================================================
# 14. Snapper + bootable snapshots
# =============================================================================
if yesno "Step 14: set up Snapper and bootable snapshots?" y; then
  info "Installing Snapper"
  # grub-btrfs builds the "Arch Linux snapshots" GRUB submenu;
  # inotify-tools lets grub-btrfsd watch /.snapshots for new snapshots.
  sudo pacman -S --needed --noconfirm snapper snap-pac btrfs-assistant grub-btrfs inotify-tools

  if [[ -f /etc/snapper/configs/root ]]; then
    ok "Snapper root config already exists; skipping create-config"
  else
    info "Creating root config on the existing @snapshots subvolume"
    findmnt -n -o OPTIONS /.snapshots | grep 'subvol=/@snapshots' >/dev/null \
      || die "/.snapshots is not mounted from @snapshots. Check /etc/fstab."
    sudo umount /.snapshots
    sudo rmdir /.snapshots
    sudo snapper -c root create-config /
    sudo btrfs subvolume delete /.snapshots
    sudo mkdir /.snapshots
    sudo mount -a
    sudo chmod 750 /.snapshots
    findmnt -n -o OPTIONS /.snapshots | grep 'subvol=/@snapshots' >/dev/null \
      || die "/.snapshots did not remount from @snapshots."
    ok "/.snapshots is mounted from @snapshots"
  fi

  info "Setting retention limits"
  CFG=/etc/snapper/configs/root
  set_cfg "$CFG" ALLOW_GROUPS          "wheel"
  set_cfg "$CFG" TIMELINE_LIMIT_HOURLY  "5"
  set_cfg "$CFG" TIMELINE_LIMIT_DAILY   "7"
  set_cfg "$CFG" TIMELINE_LIMIT_WEEKLY  "0"
  set_cfg "$CFG" TIMELINE_LIMIT_MONTHLY "0"
  set_cfg "$CFG" TIMELINE_LIMIT_YEARLY  "0"
  set_cfg "$CFG" NUMBER_LIMIT           "10"
  sudo chown :wheel /.snapshots

  info "Adding grub-btrfs-overlayfs hook (read-write snapshot boot)"
  if grep -q '^HOOKS=.*grub-btrfs-overlayfs' /etc/mkinitcpio.conf; then
    ok "Hook already present"
  else
    sudo sed -i 's/^\(HOOKS=(.*\))$/\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
    grep -q '^HOOKS=.*grub-btrfs-overlayfs' /etc/mkinitcpio.conf || die "Failed to add hook."
  fi
  sudo mkinitcpio -P
  sudo lsinitcpio /boot/initramfs-linux.img | grep 'crypto_keyfile.bin' >/dev/null \
    || die "Keyfile missing from initramfs after rebuild. Check FILES= in mkinitcpio.conf."
  ok "initramfs rebuilt; keyfile still embedded"

  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service

  info "Taking baseline snapshot"
  sudo snapper -c root create -d "baseline after post-install"
  sudo snapper -c root list
  sudo grub-mkconfig -o /boot/grub/grub.cfg

  # Confirm the snapshot submenu was generated and is wired into grub.cfg
  if sudo test -s /boot/grub/grub-btrfs.cfg && sudo grep -q 'grub-btrfs.cfg' /boot/grub/grub.cfg; then
    ok "Snapper configured; snapshot submenu is in the GRUB menu"
  else
    warn "GRUB snapshot submenu was NOT generated. Check the 'Detecting snapshots'"
    warn "lines from: sudo grub-mkconfig -o /boot/grub/grub.cfg"
  fi
  systemctl is-active --quiet grub-btrfsd.service \
    || warn "grub-btrfsd is not running; new snapshots won't be added to GRUB automatically."
fi

# =============================================================================
# 15. paru (AUR helper)
# =============================================================================
if yesno "Step 15: install paru (AUR helper)?" y; then
  if command -v paru >/dev/null; then
    ok "paru already installed"
  else
    sudo pacman -S --needed --noconfirm base-devel git
    PARU_PKG=paru
    yesno "Use prebuilt paru-bin (skips compiling Rust)?" n && PARU_PKG=paru-bin
    BUILD_DIR=$(mktemp -d)
    git clone "https://aur.archlinux.org/${PARU_PKG}.git" "$BUILD_DIR/$PARU_PKG"
    (cd "$BUILD_DIR/$PARU_PKG" && makepkg -si --noconfirm)
    rm -rf "$BUILD_DIR"
    command -v paru >/dev/null || die "paru did not install."
    ok "paru installed"
  fi
fi

# =============================================================================
# 16. Apps, tools, printing, VPNs
# =============================================================================
if yesno "Step 16: install apps, network tools, printing and VPNs?" y; then
  info "Installing packages"
  APP_PKGS=(
    # Docs / search
    man-db man-pages plocate

    # CLI tools
    wget git rsync rclone unzip fastfetch

    # Sync / VPN
    syncthing tailscale mullvad-vpn

    # Desktop apps
    firefox ark flatpak mission-center

    # Printing
    cups cups-filters cups-pdf ghostscript gsfonts
    foomatic-db-engine foomatic-db gutenprint
    print-manager system-config-printer

    # Network printer discovery
    avahi nss-mdns

    # Network tools
    bind                # dig, nslookup, host
    iputils             # ping, tracepath, arping
    inetutils           # hostname, telnet, ftp
    net-tools           # ifconfig, netstat, route (legacy)
    traceroute mtr      # path tracing
    nmap                # port scanning / host discovery
    tcpdump             # packet capture
    iperf3              # bandwidth testing
    ethtool             # NIC settings and stats
    whois
    openbsd-netcat      # nc (also used by virt-manager for remote hosts)

    # SMB / CIFS client side
    smbclient           # browse/test SMB shares from the CLI
    cifs-utils          # mount SMB shares (mount -t cifs)
    kio-extras          # smb:// browsing in Dolphin
  )
  sudo pacman -S --needed --noconfirm "${APP_PKGS[@]}"

  info "Configuring mDNS hostname resolution for network printers"
  if grep -q 'mdns_minimal' /etc/nsswitch.conf; then
    ok "mdns_minimal already in nsswitch.conf"
  else
    sudo sed -i \
      's/^\(hosts:.*\)\bresolve\b/\1mdns_minimal [NOTFOUND=return] resolve/' \
      /etc/nsswitch.conf
    grep -q 'mdns_minimal' /etc/nsswitch.conf \
      || warn "Couldn't add mdns_minimal; edit the hosts: line in /etc/nsswitch.conf by hand."
  fi
  # systemd-resolved's own mDNS fights with avahi; turn it off if resolved is in use
  if systemctl is-enabled systemd-resolved &>/dev/null; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nMulticastDNS=no\n' \
      | sudo tee /etc/systemd/resolved.conf.d/no-mdns.conf >/dev/null
    sudo systemctl restart systemd-resolved
  fi

  # Keep Snapper snapshots out of the locate database (otherwise every
  # snapshot's copy of the filesystem gets indexed)
  if ! grep -q '\.snapshots' /etc/updatedb.conf; then
    sudo sed -i 's/^PRUNENAMES = "\(.*\)"/PRUNENAMES = "\1 .snapshots"/' /etc/updatedb.conf
  fi

  info "Enabling services"
  sudo systemctl enable --now \
    plocate-updatedb.timer \
    man-db.timer \
    cups.socket \
    avahi-daemon.service \
    tailscaled.service \
    mullvad-daemon.service
  systemctl --user enable --now syncthing.service

  info "Building initial locate and man indexes"
  sudo updatedb
  sudo mandb -q
  ok "Apps installed; printing, VPN, Syncthing and index services enabled"
fi

# =============================================================================
# 17. Virtualization (QEMU / KVM / libvirt, TPM, SMB)
# =============================================================================
if yesno "Step 17: install the virtualization stack (QEMU/KVM/libvirt)?" y; then
  info "Installing virtualization packages"
  VIRT_PKGS=(
    qemu-full           # all QEMU system emulators and tools
    libvirt             # virtualization daemon and API
    virt-manager        # GUI for managing VMs
    virt-viewer         # SPICE/VNC console viewer
    virt-install        # create VMs from the CLI
    edk2-ovmf           # UEFI firmware incl. Secure Boot (Windows 11)
    swtpm               # software TPM 2.0 emulator (Windows 11)
    dnsmasq             # DHCP/DNS for libvirt's default NAT network
    nftables            # firewall backend libvirt uses for NAT
    dmidecode           # host hardware info for libvirt
    virtiofsd           # virtiofs shared folders between host and VM
    openbsd-netcat      # remote libvirt connections over SSH
    samba               # SMB server; also enables QEMU's built-in SMB share
  )
  sudo pacman -S --needed --noconfirm "${VIRT_PKGS[@]}"

  if [[ -e /dev/kvm ]]; then
    ok "KVM is available"
  else
    warn "/dev/kvm not found. Enable Intel VT-x / AMD-V (SVM) in your BIOS/UEFI,"
    warn "otherwise VMs will run in slow software emulation."
  fi

  # On Btrfs, keep VM disk images out of root snapshots and turn off
  # copy-on-write for them. A nested subvolume is skipped by snapper, and
  # NOCOW avoids heavy fragmentation of large, constantly rewritten files.
  IMG_DIR=/var/lib/libvirt/images
  if [[ $(stat -f -c %T /var/lib/libvirt) == btrfs ]]; then
    if sudo btrfs subvolume show "$IMG_DIR" &>/dev/null; then
      ok "$IMG_DIR is already a subvolume"
    elif [[ -z $(sudo ls -A "$IMG_DIR" 2>/dev/null) ]]; then
      sudo rmdir "$IMG_DIR" 2>/dev/null || true
      sudo btrfs subvolume create "$IMG_DIR"
      sudo chmod 711 "$IMG_DIR"
      sudo chattr +C "$IMG_DIR"
      ok "$IMG_DIR is now a NOCOW subvolume, excluded from root snapshots"
    else
      warn "$IMG_DIR already contains files; leaving it as-is."
    fi
  fi

  info "Enabling libvirt"
  sudo systemctl enable --now libvirtd.service

  # Let your user manage system VMs without a password prompt
  sudo usermod -aG libvirt "$USER"

  # Have virsh talk to the system instance (the same one virt-manager uses)
  mkdir -p "$HOME/.config/libvirt"
  if ! grep -qs '^uri_default' "$HOME/.config/libvirt/libvirt.conf"; then
    echo 'uri_default = "qemu:///system"' >> "$HOME/.config/libvirt/libvirt.conf"
  fi

  # Start the default NAT network now and on every boot
  if sudo virsh net-info default &>/dev/null; then
    sudo virsh net-autostart default >/dev/null
    sudo virsh net-start default 2>/dev/null || true
    ok "libvirt 'default' NAT network active and set to autostart"
  else
    warn "libvirt 'default' network not found; create it in virt-manager"
  fi
  ok "Virtualization ready (log out/in or reboot for libvirt group access)"
fi

# =============================================================================
# 18. Flatpak apps
# =============================================================================
if yesno "Step 18: install Flatpak apps?" y; then
  sudo pacman -S --needed --noconfirm flatpak
  sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

  # Apps only. Runtimes (Freedesktop, GNOME, KDE platforms), Mesa, VAAPI and
  # codec extensions are pulled in automatically as dependencies.
  FLATPAKS=(
    com.github.tchx84.Flatseal              # Flatpak permissions editor
    io.github.flattool.Warehouse            # Flatpak manager
    io.github.giantpinkrobots.flatsweep     # Flatpak leftover cleaner
    com.microsoft.Edge
    com.ticktick.TickTick
    net.cozic.joplin_desktop
    org.fkoehler.KTailctl                   # Tailscale GUI for KDE
    org.gnome.Calculator
    org.kde.kamoso                          # webcam app
    org.libreoffice.LibreOffice
    us.zoom.Zoom
    org.mozilla.Thunderbird
    org.gtk.Gtk3theme.Breeze                # Breeze theme for GTK Flatpaks
  )
  info "Installing Flatpak apps"
  sudo flatpak install -y --noninteractive --system flathub "${FLATPAKS[@]}"
  ok "Flatpak apps installed"
fi

# =============================================================================
# 19. Vendor / AUR apps (Brave Origin, RealVNC Viewer)
# =============================================================================
if yesno "Step 19: install Brave Origin and RealVNC Viewer?" y; then
  HAVE_PARU=false
  command -v paru >/dev/null && HAVE_PARU=true

  # Brave Origin via Brave's official installer. It installs from the Arch
  # repos when available, otherwise from the AUR via paru.
  info "Installing Brave Origin (official Brave installer)"
  if command -v brave-origin >/dev/null || pacman -Qq brave-origin brave-origin-bin &>/dev/null; then
    ok "Brave Origin already installed"
  elif curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh; then
    ok "Brave Origin installed"
  else
    warn "Brave Origin install failed. If it says no AUR helper was found, run step 15 (paru) and retry:"
    warn "  curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh"
  fi

  # RealVNC Viewer from the AUR. The AUR package often lags RealVNC's
  # releases by a few weeks; it updates through paru once the maintainer
  # bumps it.
  info "Installing RealVNC Viewer (AUR: realvnc-vnc-viewer)"
  if pacman -Qq realvnc-vnc-viewer &>/dev/null; then
    ok "RealVNC Viewer already installed"
  elif [[ $HAVE_PARU == true ]]; then
    if paru -S --needed --noconfirm --skipreview realvnc-vnc-viewer; then
      ok "RealVNC Viewer installed"
    else
      warn "RealVNC Viewer build failed (often because the AUR version's download"
      warn "was pulled upstream). Check the AUR comments, or build it yourself:"
      warn "  paru -G realvnc-vnc-viewer && cd realvnc-vnc-viewer"
      warn "  # bump pkgver in PKGBUILD to the current release, then:"
      warn "  updpkgsums && makepkg -si"
    fi
  else
    warn "paru not installed (step 15 skipped); skipping RealVNC Viewer."
  fi
fi

# =============================================================================
# Clone ArchLinux repo
# =============================================================================
REPO_URL="https://github.com/rccerrillo/ArchLinux.git"
REPO_DIR="$HOME/ArchLinux"
info "Cloning $REPO_URL"
sudo pacman -S --needed --noconfirm git
if [[ -d $REPO_DIR/.git ]]; then
  git -C "$REPO_DIR" pull --ff-only
  ok "Repo already present; updated $REPO_DIR"
else
  git clone "$REPO_URL" "$REPO_DIR"
  ok "Cloned to $REPO_DIR"
fi

# =============================================================================
# 20. Firewall (UFW)
# =============================================================================
if yesno "Step 20: enable UFW firewall (deny incoming, allow outgoing)?" y; then
  info "Installing and configuring UFW"
  sudo pacman -S --needed --noconfirm ufw

  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  # libvirt VMs on the default NAT network get DHCP/DNS from the host over
  # virbr0 and route out through it. Default-deny would block both, so
  # VMs would get no IP address and no internet.
  if pacman -Qq libvirt &>/dev/null; then
    sudo ufw allow in on virbr0 comment 'libvirt VM DHCP/DNS'
    sudo ufw route allow in on virbr0 comment 'libvirt VM NAT out'
    sudo ufw route allow out on virbr0 comment 'libvirt VM NAT return'
    ok "Allowed libvirt VM traffic on virbr0"
  fi

  sudo ufw --force enable
  sudo systemctl enable --now ufw.service
  sudo ufw status verbose
  ok "UFW active: incoming denied, outgoing allowed"
fi

# =============================================================================
# Final GRUB refresh so every snapshot taken during this run is listed
# =============================================================================
if [[ -f /etc/snapper/configs/root ]]; then
  info "Regenerating GRUB menu with all snapshots"
  sudo grub-mkconfig -o /boot/grub/grub.cfg
  if sudo test -s /boot/grub/grub-btrfs.cfg && sudo grep -q 'grub-btrfs.cfg' /boot/grub/grub.cfg; then
    ok "Snapshot submenu present in GRUB"
  else
    warn "Snapshot submenu still missing from GRUB; see the grub-mkconfig output above."
  fi
fi

# =============================================================================
# Done
# =============================================================================
echo
ok "Post-install complete."
cat <<'EOF'

Next steps (after reboot):
  * Tailscale:   sudo tailscale up
                 sudo tailscale set --operator=$USER   (lets KTailctl work without root)
  * Mullvad:     mullvad account login <account-number>   (or use the GUI)
  * Syncthing:   http://127.0.0.1:8384
  * Printers:    System Settings -> Printers
  * VMs:         open Virtual Machine Manager. For Windows 11, choose
                 "Customize before install", set firmware to a *secboot*
                 OVMF image, and add a TPM (emulated, CRB, v2.0).
  * Samba:       no SMB server is configured. Create /etc/samba/smb.conf
                 before enabling smb.service if you want to share folders.

Note: Mullvad and Tailscale can conflict over routing/DNS when both are
connected. Only run one at a time unless you've configured split routing.

EOF
if yesno "Reboot now?" y; then
  sudo reboot
fi
