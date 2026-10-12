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
--latest 10
--fastest 10
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
    wget git rsync rclone unzip

    # Sync / networking
    syncthing tailscale mullvad-vpn

    # Desktop apps
    firefox ark flatpak

    # Printing
    cups cups-filters cups-pdf ghostscript gsfonts
    foomatic-db-engine foomatic-db gutenprint
    print-manager system-config-printer

    # Network printer discovery
    avahi nss-mdns
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
)
sudo systemctl enable --now "${SYSTEM_UNITS[@]}"

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
  * Log out and back in so Flatpak apps appear in the menu.

Note: Mullvad and Tailscale can conflict over routing/DNS when both are
connected. Only run one at a time unless you've configured split routing.
EOF
