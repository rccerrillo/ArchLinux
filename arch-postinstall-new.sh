#!/usr/bin/env bash
#
# arch-postinstall.sh — post-install packages and services for Arch + KDE Plasma
#
# Run as your normal user (NOT root). The script calls sudo where needed,
# and the user-level Syncthing service has to be enabled as you.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
REFLECTOR_COUNTRY="US"   # comma-separated list is fine, e.g. "US,CA"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user, not root. It will use sudo when needed." >&2
    exit 1
fi

sudo -v
# Keep sudo alive for the duration of the script
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# ---------------------------------------------------------------------------
# 1. Reflector first, so everything else downloads from good mirrors
# ---------------------------------------------------------------------------
info "Installing and configuring reflector"
sudo pacman -S --needed --noconfirm reflector

sudo tee /etc/xdg/reflector/reflector.conf >/dev/null <<EOF
# Managed by arch-postinstall.sh
--country ${REFLECTOR_COUNTRY}
--protocol https
--latest 20
--fastest 5
--age 8
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

info "Ranking mirrors (one-off run)"
sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
sudo systemctl start reflector.service || warn "reflector run failed; keeping existing mirrorlist"

sudo pacman -Syu --noconfirm

# ---------------------------------------------------------------------------
# 2. Official repo packages
# ---------------------------------------------------------------------------
PACKAGES=(
    # Docs / search
    man-db man-pages plocate

    # CLI tools
    wget git rsync rclone unzip fastfetch

    # Sync / networking
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

    # Virtualization: QEMU / KVM / libvirt
    qemu-full           # all QEMU system emulators and tools
    libvirt             # virtualization daemon and API
    virt-manager        # GUI for managing VMs
    virt-viewer         # SPICE/VNC console viewer
    virt-install        # create VMs from the CLI (virt-install)
    edk2-ovmf           # UEFI firmware incl. Secure Boot (Windows 11)
    swtpm               # software TPM 2.0 emulator (Windows 11)
    dnsmasq             # DHCP/DNS for libvirt's default NAT network
    nftables            # firewall backend libvirt uses for NAT
    dmidecode           # host hardware info for libvirt
    virtiofsd           # virtiofs shared folders between host and VM

    # SMB / CIFS
    samba               # SMB server; also enables QEMU's built-in SMB share
    smbclient           # browse/test SMB shares from the CLI
    cifs-utils          # mount SMB shares (mount -t cifs)
    kio-extras          # smb:// browsing in Dolphin
)

info "Installing packages"
sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"

# ---------------------------------------------------------------------------
# 3. Configuration
# ---------------------------------------------------------------------------
info "Configuring mDNS hostname resolution for network printers"
# Insert mdns_minimal before 'resolve' on the hosts line (idempotent)
if ! grep -q 'mdns_minimal' /etc/nsswitch.conf; then
    sudo sed -i \
        's/^\(hosts:.*\)\bresolve\b/\1mdns_minimal [NOTFOUND=return] resolve/' \
        /etc/nsswitch.conf
fi
grep '^hosts:' /etc/nsswitch.conf

# systemd-resolved's own mDNS fights with avahi; turn it off if resolved is in use
if systemctl is-enabled systemd-resolved &>/dev/null; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nMulticastDNS=no\n' | \
        sudo tee /etc/systemd/resolved.conf.d/no-mdns.conf >/dev/null
    sudo systemctl restart systemd-resolved
fi

info "Ensuring Flathub remote exists"
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
    org.gtk.Gtk3theme.Breeze                # Breeze theme for GTK Flatpaks
)

info "Installing Flatpak apps"
sudo flatpak install -y --noninteractive --system flathub "${FLATPAKS[@]}"

# ---------------------------------------------------------------------------
# 4. Services
# ---------------------------------------------------------------------------
info "Enabling system services"
SYSTEM_UNITS=(
    reflector.service          # refresh mirrors at boot
    reflector.timer            # and weekly
    plocate-updatedb.timer     # daily locate DB refresh
    man-db.timer               # daily man index refresh
    cups.socket                # CUPS starts on demand
    avahi-daemon.service       # printer discovery
    tailscaled.service
    mullvad-daemon.service
    libvirtd.service           # VM management daemon
)
sudo systemctl enable --now "${SYSTEM_UNITS[@]}"

# ---------------------------------------------------------------------------
# 5. Virtualization setup
# ---------------------------------------------------------------------------
info "Configuring virtualization"

if [[ -e /dev/kvm ]]; then
    echo "  KVM is available."
else
    warn "/dev/kvm not found. Enable Intel VT-x / AMD-V (SVM) in your BIOS/UEFI,"
    warn "otherwise VMs will run in slow software emulation."
fi

# Let your user manage system VMs without a password prompt
sudo usermod -aG libvirt "$USER"

# Have virsh talk to the system instance (the same one virt-manager uses)
mkdir -p "$HOME/.config/libvirt"
if [[ ! -f "$HOME/.config/libvirt/libvirt.conf" ]] || \
   ! grep -q '^uri_default' "$HOME/.config/libvirt/libvirt.conf"; then
    echo 'uri_default = "qemu:///system"' >> "$HOME/.config/libvirt/libvirt.conf"
fi

# Start the default NAT network now and on every boot
if sudo virsh net-info default &>/dev/null; then
    sudo virsh net-autostart default >/dev/null
    sudo virsh net-start default 2>/dev/null || true
else
    warn "libvirt 'default' network not found; create it in virt-manager"
fi

info "Enabling user services"
systemctl --user enable --now syncthing.service

# Seed the indexes now so locate/apropos work immediately
info "Building initial locate and man indexes"
sudo updatedb
sudo mandb -q

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info "Done"
cat <<'EOF'

Next steps:
  * Tailscale:   sudo tailscale up
  * Mullvad:     mullvad account login <account-number>   (or use the GUI)
  * Syncthing:   http://127.0.0.1:8384
  * Printers:    System Settings -> Printers
  * Log out and back in (or reboot) so Flatpak apps appear in the menu
    and your new 'libvirt' group membership takes effect.
  * VMs:         open Virtual Machine Manager. For Windows 11, choose
                 "Customize before install", set firmware to a *secboot*
                 OVMF image, and add a TPM (emulated, CRB, v2.0).
  * Samba:       no SMB server is configured. Create /etc/samba/smb.conf
                 before enabling smb.service if you want to share folders.

Note: Mullvad and Tailscale can conflict over routing/DNS when both are
connected. Only run one at a time unless you've configured split routing.
EOF
