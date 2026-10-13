#!/usr/bin/env bash
# =============================================================================
# 02-post-install.sh
# Post-install for the LUKS2 + Btrfs + GRUB Arch build.
#
# Run as your NORMAL USER (with sudo) after first boot and network connect.
# Covers guide steps 13-15:
#   13. KDE Plasma desktop + services
#   14. Snapper, snap-pac, btrfs-assistant, bootable snapshots
#   15. paru (AUR helper)
# Each step can be skipped, and steps already done are detected and skipped.
# =============================================================================
set -Eeuo pipefail

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
  sudo pacman -S --needed --noconfirm snapper snap-pac btrfs-assistant

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
  ok "Snapper configured; snapshots will appear in the GRUB menu"
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
# Done
# =============================================================================
echo
ok "Post-install complete."
if yesno "Reboot now?" y; then
  sudo reboot
fi
