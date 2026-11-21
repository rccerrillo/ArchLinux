#!/usr/bin/env bash
# =============================================================================
#  arch-sb-install.sh — Arch Linux laptop install
#
#    * GPT: 1 GiB ESP (/efi) + LUKS2 root (argon2id)
#    * Btrfs subvolumes: @ @home @snapshots @log @pkg @swap
#    * systemd-boot + signed Unified Kernel Images (linux + linux-lts)
#    * Secure Boot via sbctl (your own keys + Microsoft keys)
#    * TPM2 auto-unlock bound to PCR 7 (enrolled after first boot; see below)
#    * snapper + snap-pac (pre/post pacman snapshots + timeline), no GRUB needed
#    * zram for everyday swap + btrfs swapfile for hibernation
#    * KDE Plasma, NetworkManager, PipeWire, Bluetooth, power-profiles-daemon
#    * Optional: NVIDIA (nvidia-open, PRIME offload for Intel+NVIDIA laptops)
#    * Optional: KVM/QEMU/libvirt + OVMF Secure Boot + swtpm for Windows 11 VMs
#    * UFW firewall: deny incoming, allow outgoing (libvirt NAT allowed)
#
#  Run from the official Arch ISO booted in UEFI mode:
#      bash arch-sb-install.sh
#  Any CONFIG value can be overridden from the environment, e.g.:
#      DISK=/dev/nvme0n1 HOST_NAME=xps USERNAME=bob bash arch-sb-install.sh
#
#  BEFORE RUNNING: in the firmware setup, put Secure Boot into "Setup Mode"
#  (often "Clear/Delete all Secure Boot keys"; leave Secure Boot itself OFF).
#  If you skip this, the script still works and tells you how to enroll later.
#
#  AFTER INSTALL:
#    1. Reboot, enable Secure Boot in firmware.
#    2. Boot, type the LUKS passphrase one last time, log in.
#    3. Run:  sudo tpm-enroll      (creates recovery key + TPM2/PCR7 slot)
#    4. Reboot — the disk unlocks automatically from now on.
#
#  THIS ERASES $DISK COMPLETELY.
# =============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\e[1;31m[!] Failed at line $LINENO: $BASH_COMMAND\e[0m" >&2' ERR

# ----------------------------- CONFIG ----------------------------------------
DISK="${DISK:-}"                         # e.g. /dev/nvme0n1 (prompted if empty)
HOST_NAME="${HOST_NAME:-archlaptop}"
USERNAME="${USERNAME:-}"                 # prompted if empty
TIMEZONE="${TIMEZONE:-America/Phoenix}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
ESP_SIZE="${ESP_SIZE:-1G}"
SWAP_GB="${SWAP_GB:-}"                   # hibernation swapfile; default = RAM size
INSTALL_LTS="${INSTALL_LTS:-yes}"        # linux-lts as a fallback UKI
INSTALL_KDE="${INSTALL_KDE:-yes}"
TPM_PIN="${TPM_PIN:-no}"                 # yes = TPM2 + PIN instead of TPM-only
INSTALL_NVIDIA="${INSTALL_NVIDIA:-ask}"  # ask | yes | no  (Turing/GTX 16xx/RTX 20xx and newer)
INSTALL_VIRT="${INSTALL_VIRT:-ask}"      # ask | yes | no  (KVM/QEMU/libvirt stack for a Win11 VM)
INSTALL_UFW="${INSTALL_UFW:-yes}"        # UFW: deny incoming, allow outgoing
BTRFS_OPTS="noatime,compress=zstd:1"
MNT=/mnt
LOG=/tmp/arch-sb-install.log
# -----------------------------------------------------------------------------

exec > >(tee -a "$LOG") 2>&1

msg()  { echo -e "\n\e[1;32m==>\e[0m \e[1m$*\e[0m"; }
warn() { echo -e "\e[1;33m[warn]\e[0m $*"; }
die()  { echo -e "\e[1;31m[error]\e[0m $*" >&2; exit 1; }

ask_secret() {   # ask_secret "Prompt" VARNAME
  local p1 p2
  while true; do
    read -rsp "$1: " p1; echo
    read -rsp "Confirm: " p2; echo
    if [[ -n $p1 && $p1 == "$p2" ]]; then printf -v "$2" '%s' "$p1"; return; fi
    warn "Empty or mismatched, try again."
  done
}

# ----------------------------- PREFLIGHT -------------------------------------
msg "Preflight checks"
[[ $EUID -eq 0 ]] || die "Run as root from the Arch ISO."
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode."
[[ $(cat /sys/firmware/efi/fw_platform_size 2>/dev/null) == 64 ]] \
  || die "64-bit UEFI required for systemd-boot/UKI."
ping -c1 -W5 archlinux.org &>/dev/null || die "No network. Use iwctl / check cable."
[[ -e /dev/tpmrm0 ]] || warn "No TPM2 device found (/dev/tpmrm0). Install continues, but auto-unlock will not be possible."
timedatectl set-ntp true

if [[ -z $DISK ]]; then
  echo; lsblk -dpno NAME,SIZE,MODEL | grep -Ev '/dev/(loop|sr|zram)'; echo
  read -rp "Target disk (e.g. /dev/nvme0n1): " DISK
fi
[[ -b $DISK ]] || die "$DISK is not a block device."
[[ -z $USERNAME ]] && read -rp "Username to create: " USERNAME
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."

ask_secret "LUKS passphrase (fallback; TPM unlock is added after first boot)" LUKS_PASS
ask_secret "Password for $USERNAME" USER_PASS

if [[ -z $SWAP_GB ]]; then
  SWAP_GB=$(awk '/MemTotal/ {printf "%d", ($2/1048576)+0.999}' /proc/meminfo)
fi

if grep -q GenuineIntel /proc/cpuinfo; then UCODE=intel-ucode; VULKAN=vulkan-intel
elif grep -q AuthenticAMD /proc/cpuinfo; then UCODE=amd-ucode; VULKAN=vulkan-radeon
else UCODE=""; VULKAN=""; fi

ask_yn() {   # ask_yn VARNAME "Question" default(y|n)  — only asks when VAR=ask
  local -n ref=$1; [[ $ref == ask ]] || return 0
  local a; read -rp "$2 [$( [[ $3 == y ]] && echo Y/n || echo y/N )]: " a
  a=${a:-$3}; [[ $a == [yY]* ]] && ref=yes || ref=no
}

NV_GPU=$(lspci -d 10de::03xx 2>/dev/null || true)
if [[ -n $NV_GPU ]]; then
  echo; echo "NVIDIA GPU detected:"; echo "$NV_GPU"
  echo "(nvidia-open supports Turing and newer: GTX 16xx, RTX 20xx+, MX450/550+."
  echo " Pascal/Maxwell (GTX 10xx/9xx, MX1xx-3xx) need nvidia-580xx-dkms from the AUR instead.)"
  ask_yn INSTALL_NVIDIA "Install NVIDIA drivers (PRIME offload with Intel iGPU)?" y
else
  ask_yn INSTALL_NVIDIA "No NVIDIA GPU detected. Install NVIDIA drivers anyway?" n
fi
ask_yn INSTALL_VIRT "Install KVM/QEMU/libvirt virtualization stack for a Windows 11 VM?" y

if [[ $DISK =~ [0-9]$ ]]; then P="${DISK}p"; else P="$DISK"; fi
ESP_PART="${P}1"; CRYPT_PART="${P}2"

cat <<EOF

  Disk:       $DISK  (ESP: $ESP_PART, LUKS: $CRYPT_PART)
  Hostname:   $HOST_NAME      User: $USERNAME
  Timezone:   $TIMEZONE      Locale: $LOCALE   Keymap: $KEYMAP
  Swapfile:   ${SWAP_GB} GiB (hibernation)  + zram
  Microcode:  ${UCODE:-none}   LTS kernel: $INSTALL_LTS   KDE: $INSTALL_KDE
  TPM mode:   PCR 7, PIN: $TPM_PIN
  NVIDIA:     $INSTALL_NVIDIA   Virtualization: $INSTALL_VIRT   UFW: $INSTALL_UFW

EOF
lsblk "$DISK"
read -rp "Type the disk path again to ERASE it and continue: " CONFIRM
[[ $CONFIRM == "$DISK" ]] || die "Aborted."

# ----------------------------- PARTITION / LUKS ------------------------------
msg "Partitioning $DISK"
umount -R "$MNT" 2>/dev/null || true
cryptsetup close root 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+"$ESP_SIZE" -t1:ef00 -c1:ESP \
       -n2:0:0            -t2:8304 -c2:cryptroot "$DISK"
partprobe "$DISK"; udevadm settle; sleep 1

msg "Creating LUKS2 container"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id \
  --label cryptroot --batch-mode --key-file=- "$CRYPT_PART"
printf '%s' "$LUKS_PASS" | cryptsetup open --allow-discards --persistent \
  --key-file=- "$CRYPT_PART" root
LUKS_UUID=$(cryptsetup luksUUID "$CRYPT_PART")

# ----------------------------- FILESYSTEMS -----------------------------------
msg "Creating filesystems and subvolumes"
mkfs.fat -F32 -n ESP "$ESP_PART"
mkfs.btrfs -f -L arch /dev/mapper/root

mount /dev/mapper/root "$MNT"
SUBVOLS=(@ @home @snapshots @log @pkg @swap)
[[ $INSTALL_VIRT == yes ]] && SUBVOLS+=(@libvirt)
for sv in "${SUBVOLS[@]}"; do btrfs subvolume create "$MNT/$sv"; done
umount "$MNT"

mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/root "$MNT"
mkdir -p "$MNT"/{efi,home,.snapshots,var/log,var/cache/pacman/pkg,swap}
mount -o "$BTRFS_OPTS,subvol=@home"      /dev/mapper/root "$MNT/home"
mount -o "$BTRFS_OPTS,subvol=@snapshots" /dev/mapper/root "$MNT/.snapshots"
mount -o "$BTRFS_OPTS,subvol=@log"       /dev/mapper/root "$MNT/var/log"
mount -o "$BTRFS_OPTS,subvol=@pkg"       /dev/mapper/root "$MNT/var/cache/pacman/pkg"
mount -o "noatime,subvol=@swap"          /dev/mapper/root "$MNT/swap"
mount -o umask=0077 "$ESP_PART" "$MNT/efi"

if [[ $INSTALL_VIRT == yes ]]; then
  # VM disk images: own subvolume (not in root snapshots), copy-on-write disabled
  mkdir -p "$MNT/var/lib/libvirt/images"
  mount -o "noatime,subvol=@libvirt" /dev/mapper/root "$MNT/var/lib/libvirt/images"
  chattr +C "$MNT/var/lib/libvirt/images"
fi

# Nested subvolume so snapper can snapshot /home separately
btrfs subvolume create "$MNT/home/.snapshots"

msg "Creating ${SWAP_GB} GiB swapfile for hibernation"
btrfs filesystem mkswapfile --size "${SWAP_GB}g" --uuid clear "$MNT/swap/swapfile"
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "$MNT/swap/swapfile")

# ----------------------------- PACSTRAP --------------------------------------
PKGS=(base base-devel linux linux-firmware btrfs-progs cryptsetup dosfstools
      efibootmgr sbctl tpm2-tss tpm2-tools snapper snap-pac zram-generator
      networkmanager sudo nano vim man-db man-pages git arch-install-scripts
      terminus-font bluez bluez-utils power-profiles-daemon fwupd sof-firmware
      pciutils usbutils)
[[ -n $UCODE ]] && PKGS+=("$UCODE")
[[ $INSTALL_LTS == yes ]] && PKGS+=(linux-lts)
[[ $INSTALL_UFW == yes ]] && PKGS+=(ufw)
if [[ $INSTALL_NVIDIA == yes ]]; then
  # Prebuilt open kernel modules for each installed kernel (no DKMS build needed)
  PKGS+=(nvidia-open nvidia-utils nvidia-settings nvidia-prime switcheroo-control egl-wayland)
  [[ $INSTALL_LTS == yes ]] && PKGS+=(nvidia-open-lts)
fi
if [[ $INSTALL_VIRT == yes ]]; then
  PKGS+=(qemu-desktop libvirt virt-manager virt-viewer edk2-ovmf swtpm
         dnsmasq nftables dmidecode)
fi
if [[ $INSTALL_KDE == yes ]]; then
  PKGS+=(plasma-meta sddm konsole kwrite dolphin dolphin-plugins kate ark spectacle gwenview okular
         firefox pipewire pipewire-pulse pipewire-jack wireplumber mesa
         noto-fonts noto-fonts-emoji kde-gtk-config xdg-desktop-portal-kde)
  [[ -n $VULKAN ]] && PKGS+=("$VULKAN")
fi

msg "Installing packages"
pacman -Sy --noconfirm archlinux-keyring
pacstrap -K "$MNT" "${PKGS[@]}"

# ----------------------------- SYSTEM CONFIG ---------------------------------
msg "Writing fstab"
genfstab -U "$MNT" >> "$MNT/etc/fstab"
# Drop subvolid= so rolled-back @ (new subvolid) still mounts by name
sed -i 's/subvolid=[0-9]*,//g' "$MNT/etc/fstab"
echo "/swap/swapfile  none  swap  defaults,pri=0  0 0" >> "$MNT/etc/fstab"

msg "Base system config"
echo "$HOST_NAME" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
EOF
sed -i "s/^#\(${LOCALE//./\\.} \)/\1/" "$MNT/etc/locale.gen"
echo "LANG=$LOCALE" > "$MNT/etc/locale.conf"
printf 'KEYMAP=%s\nFONT=ter-v16n\n' "$KEYMAP" > "$MNT/etc/vconsole.conf"

# zram for normal swapping (higher priority than the hibernation swapfile)
cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF

# Kernel command line embedded in every UKI
CMDLINE="rd.luks.name=$LUKS_UUID=root rd.luks.options=tpm2-device=auto,discard root=/dev/mapper/root rootfstype=btrfs rootflags=subvol=@ rw resume=/dev/mapper/root resume_offset=$RESUME_OFFSET zswap.enabled=0 quiet loglevel=3"
if [[ $INSTALL_VIRT == yes ]]; then
  if [[ $UCODE == intel-ucode ]]; then CMDLINE+=" intel_iommu=on iommu=pt"; else CMDLINE+=" iommu=pt"; fi
fi
echo "$CMDLINE" > "$MNT/etc/kernel/cmdline"

# systemd-based initramfs with sd-encrypt (handles TPM2, passphrase, resume).
# With NVIDIA, the 'kms' hook is dropped so nouveau never loads in early boot.
KMS_HOOK="kms"; [[ $INSTALL_NVIDIA == yes ]] && KMS_HOOK=""
mkdir -p "$MNT/etc/mkinitcpio.conf.d"
echo "HOOKS=(base systemd autodetect microcode modconf $KMS_HOOK keyboard sd-vconsole block sd-encrypt filesystems)" \
  | tr -s ' ' > "$MNT/etc/mkinitcpio.conf.d/10-encrypt-uki.conf"

if [[ $INSTALL_NVIDIA == yes ]]; then
  mkdir -p "$MNT/etc/modprobe.d"
  cat > "$MNT/etc/modprobe.d/nvidia.conf" <<'EOF'
# Keep VRAM contents across suspend/hibernate (needed for nvidia-suspend/hibernate services)
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
# Runtime D3 power management: dGPU powers off when idle (Turing+ laptops)
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia_drm modeset=1 fbdev=1
EOF
fi

write_preset() {   # write_preset <pkgbase> <uki-name>
  cat > "$MNT/etc/mkinitcpio.d/$1.preset" <<EOF
# mkinitcpio preset for '$1' — builds a UKI only (signed by sbctl's post hook)
ALL_kver="/boot/vmlinuz-$1"
PRESETS=('default')
default_uki="/efi/EFI/Linux/$2.efi"
EOF
}
mkdir -p "$MNT/efi/EFI/Linux"
write_preset linux arch-linux
[[ $INSTALL_LTS == yes ]] && write_preset linux-lts arch-linux-lts

# sudo for wheel
echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"
chmod 440 "$MNT/etc/sudoers.d/10-wheel"

# ----------------------------- SNAPPER ---------------------------------------
msg "Configuring snapper"
TEMPLATE="$MNT/usr/share/snapper/config-templates/default"
install -Dm640 "$TEMPLATE" "$MNT/etc/snapper/configs/root"
install -Dm640 "$TEMPLATE" "$MNT/etc/snapper/configs/home"
set_snap() {  # set_snap <config> KEY VALUE
  sed -i "s|^$2=.*|$2=\"$3\"|" "$MNT/etc/snapper/configs/$1"
}
for c in root home; do
  set_snap "$c" ALLOW_GROUPS wheel
  set_snap "$c" SYNC_ACL yes
  set_snap "$c" TIMELINE_CREATE yes
  set_snap "$c" TIMELINE_CLEANUP yes
  set_snap "$c" TIMELINE_LIMIT_HOURLY 5
  set_snap "$c" TIMELINE_LIMIT_DAILY 7
  set_snap "$c" TIMELINE_LIMIT_WEEKLY 2
  set_snap "$c" TIMELINE_LIMIT_MONTHLY 0
  set_snap "$c" TIMELINE_LIMIT_YEARLY 0
done
set_snap root SUBVOLUME /
set_snap root NUMBER_LIMIT 15          # snap-pac pre/post pairs
set_snap home SUBVOLUME /home
echo 'SNAPPER_CONFIGS="root home"' > "$MNT/etc/conf.d/snapper"
chmod 750 "$MNT/.snapshots" "$MNT/home/.snapshots"

# ----------------------------- PACMAN HOOK: systemd-boot signing -------------
mkdir -p "$MNT/etc/pacman.d/hooks"
cat > "$MNT/etc/pacman.d/hooks/95-systemd-boot-sign.hook" <<'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = systemd

[Action]
Description = Signing systemd-boot and updating the ESP copy...
When = PostTransaction
Depends = sbctl
Exec = /bin/sh -c 'sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi && bootctl update --graceful; sbctl sign-all'
EOF

# ----------------------------- LIBVIRT ---------------------------------------
if [[ $INSTALL_VIRT == yes ]]; then
  # Autostart the default NAT network (virbr0) without needing a running daemon
  mkdir -p "$MNT/etc/libvirt/qemu/networks/autostart"
  if [[ -f $MNT/usr/share/libvirt/networks/default.xml && ! -f $MNT/etc/libvirt/qemu/networks/default.xml ]]; then
    cp "$MNT/usr/share/libvirt/networks/default.xml" "$MNT/etc/libvirt/qemu/networks/default.xml"
  fi
  ln -sf ../default.xml "$MNT/etc/libvirt/qemu/networks/autostart/default.xml"
fi

# ----------------------------- UFW -------------------------------------------
if [[ $INSTALL_UFW == yes ]]; then
  # Policies apply from the very first boot...
  sed -i 's/^ENABLED=.*/ENABLED=yes/' "$MNT/etc/ufw/ufw.conf"
  sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/;
          s/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' "$MNT/etc/default/ufw"
  # ...and a one-shot unit applies the rules properly with ufw itself on first boot
  cat > "$MNT/usr/local/sbin/firstboot-ufw" <<EOF
#!/bin/sh
set -e
ufw default deny incoming
ufw default allow outgoing
ufw logging low
if [ "$INSTALL_VIRT" = yes ]; then
  # Let VMs on libvirt's NAT bridge reach DHCP/DNS on the host and route out
  ufw allow in on virbr0 comment 'libvirt guests -> host (DHCP/DNS)'
  ufw route allow in on virbr0 comment 'libvirt guests -> out'
  ufw route allow out on virbr0 comment 'replies -> libvirt guests'
fi
ufw --force enable
systemctl disable firstboot-ufw.service
EOF
  chmod 755 "$MNT/usr/local/sbin/firstboot-ufw"
  cat > "$MNT/etc/systemd/system/firstboot-ufw.service" <<'EOF'
[Unit]
Description=First-boot UFW configuration
After=ufw.service
Wants=ufw.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-ufw

[Install]
WantedBy=multi-user.target
EOF
fi

# ----------------------------- HELPER SCRIPTS --------------------------------
cat > "$MNT/etc/arch-sb.conf" <<EOF
LUKS_UUID=$LUKS_UUID
TPM_PIN=$TPM_PIN
EOF

cat > "$MNT/usr/local/bin/tpm-enroll" <<'EOF'
#!/usr/bin/env bash
# Enroll a recovery key and a TPM2 (PCR 7) key slot. Run after Secure Boot is ON.
# Re-run any time auto-unlock stops working (e.g. after a firmware dbx update).
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
source /etc/arch-sb.conf
DEV="/dev/disk/by-uuid/$LUKS_UUID"

if ! sbctl status --json | grep -Eq '"secure_boot": *true'; then
  echo "Secure Boot is NOT enabled. Enable it in firmware first, then re-run." >&2
  sbctl status; exit 1
fi
sbctl verify || true

if ! systemd-cryptenroll "$DEV" 2>/dev/null | grep -q recovery; then
  echo; echo ">>> Generating a RECOVERY KEY. Store it in your password manager NOW."
  systemd-cryptenroll --recovery-key "$DEV"
  read -rp "Press Enter once the recovery key is saved..."
fi

PIN_OPT=()
[[ ${TPM_PIN:-no} == yes ]] && PIN_OPT=(--tpm2-with-pin=yes)

echo; echo ">>> Enrolling TPM2 bound to PCR 7 (enter the LUKS passphrase when asked)"
systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 "${PIN_OPT[@]}" "$DEV"
echo; systemd-cryptenroll "$DEV"
echo; echo "Done. Reboot to test automatic unlock."
EOF

cat > "$MNT/usr/local/bin/snap-rollback" <<'EOF'
#!/usr/bin/env bash
# Roll the root subvolume back to a snapper snapshot, without GRUB.
#   snap-rollback <number>     (list with: snapper -c root list)
# Current root is kept as @old-<timestamp>. UKIs are rebuilt from the restored
# root so the kernel in the UKI matches the restored /usr/lib/modules.
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
N="${1:?usage: snap-rollback <snapshot number>  (see: snapper -c root list)}"
DEV=/dev/mapper/root
TOP=$(mktemp -d); NEW=$(mktemp -d)
cleanup() { umount -R "$NEW" 2>/dev/null || true; umount "$TOP" 2>/dev/null || true; rmdir "$TOP" "$NEW" 2>/dev/null || true; }
trap cleanup EXIT

mount -o subvolid=5 "$DEV" "$TOP"
SRC="$TOP/@snapshots/$N/snapshot"
[[ -d $SRC ]] || { echo "Snapshot $N not found." >&2; exit 1; }
grep -m1 -o '<description>.*</description>' "$TOP/@snapshots/$N/info.xml" || true
read -rp "Roll back root to snapshot $N? [y/N] " a; [[ $a == [yY] ]] || exit 1

STAMP=$(date +%Y%m%d-%H%M%S)
mv "$TOP/@" "$TOP/@old-$STAMP"
btrfs subvolume snapshot "$SRC" "$TOP/@"

echo ">>> Rebuilding and signing UKIs from the restored root"
mount -o subvol=@ "$DEV" "$NEW"
mount --bind /efi "$NEW/efi"
arch-chroot "$NEW" sh -c 'mkinitcpio -P && sbctl sign-all'

echo
echo "Rolled back. Reboot now."
echo "Old root kept as @old-$STAMP. To delete it later:"
echo "  sudo mount -o subvolid=5 $DEV /mnt && sudo btrfs subvolume list -o /mnt/@old-$STAMP"
echo "  (delete any nested subvolumes listed, then) sudo btrfs subvolume delete /mnt/@old-$STAMP"
EOF
chmod 755 "$MNT/usr/local/bin/tpm-enroll" "$MNT/usr/local/bin/snap-rollback"

# ----------------------------- CHROOT ----------------------------------------
msg "Configuring inside chroot"
arch-chroot "$MNT" env TIMEZONE="$TIMEZONE" USERNAME="$USERNAME" \
  INSTALL_KDE="$INSTALL_KDE" INSTALL_NVIDIA="$INSTALL_NVIDIA" \
  INSTALL_VIRT="$INSTALL_VIRT" INSTALL_UFW="$INSTALL_UFW" bash -euo pipefail <<'CHROOT'
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
locale-gen

useradd -m -G wheel -s /bin/bash "$USERNAME"
passwd -l root

# Secure Boot keys + signed systemd-boot
sbctl create-keys
sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
                 /usr/lib/systemd/boot/efi/systemd-bootx64.efi
bootctl install --esp-path=/efi

cat > /efi/loader/loader.conf <<'EOF'
default arch-linux.efi
timeout 3
console-mode max
editor no
EOF

# Build UKIs (sbctl's initcpio post hook signs them), drop old initramfs images
mkinitcpio -P
rm -f /boot/initramfs-*.img
for f in /efi/EFI/Linux/*.efi /efi/EFI/BOOT/BOOTX64.EFI /efi/EFI/systemd/systemd-bootx64.efi; do
  [[ -f $f ]] && sbctl sign -s "$f"
done
sbctl verify || true

systemctl enable NetworkManager bluetooth power-profiles-daemon \
  systemd-timesyncd systemd-boot-update snapper-timeline.timer snapper-cleanup.timer
[[ $INSTALL_KDE == yes ]] && systemctl enable sddm

if [[ $INSTALL_NVIDIA == yes ]]; then
  systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume switcheroo-control
fi
if [[ $INSTALL_VIRT == yes ]]; then
  usermod -aG libvirt,kvm "$USERNAME"
  systemctl enable libvirtd.service
fi
if [[ $INSTALL_UFW == yes ]]; then
  systemctl enable ufw.service firstboot-ufw.service
fi
true
CHROOT

printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot "$MNT" chpasswd
unset LUKS_PASS USER_PASS

# ----------------------------- SECURE BOOT ENROLL ----------------------------
SB_ENROLLED=no
if arch-chroot "$MNT" sbctl status --json | grep -Eq '"setup_mode": *true'; then
  msg "Firmware is in Setup Mode: enrolling keys (with Microsoft keys)"
  arch-chroot "$MNT" sbctl enroll-keys -m && SB_ENROLLED=yes
else
  warn "Firmware is NOT in Setup Mode; keys not enrolled yet."
fi

# Baseline snapshot of the fresh install
arch-chroot "$MNT" snapper --no-dbus -c root create -d "fresh install" || true

# ----------------------------- DONE ------------------------------------------
msg "Unmounting"
cp "$LOG" "$MNT/var/log/arch-sb-install.log" 2>/dev/null || true
sync
umount -R "$MNT"
cryptsetup close root

echo
msg "Install complete. Next steps:"
if [[ $SB_ENROLLED == yes ]]; then
  cat <<EOF
  1. Reboot, go into firmware setup, and ENABLE Secure Boot.
  2. Boot, enter the LUKS passphrase, log in as $USERNAME.
  3. Run:  sudo tpm-enroll     (saves a recovery key, adds the TPM2/PCR7 slot)
  4. Reboot. The disk should now unlock on its own.
EOF
else
  cat <<EOF
  1. Reboot into firmware setup: clear Secure Boot keys / enter Setup Mode
     (leave Secure Boot OFF), then boot Arch and enter the LUKS passphrase.
  2. Run:  sudo sbctl enroll-keys -m
  3. Reboot into firmware and ENABLE Secure Boot.
  4. Boot, enter the passphrase, run:  sudo tpm-enroll
  5. Reboot. The disk should now unlock on its own.
EOF
fi
echo "  Rollback later with:  snapper -c root list  then  sudo snap-rollback <N>"
if [[ $INSTALL_NVIDIA == yes ]]; then
  echo "  NVIDIA: apps run on the Intel iGPU by default; use 'prime-run <app>' or"
  echo "          right-click > 'Run using dedicated graphics card' in KDE. Check: nvidia-smi"
fi
if [[ $INSTALL_VIRT == yes ]]; then
  cat <<'EOF'
  Win11 VM: in virt-manager pick Q35 + UEFI firmware 'OVMF_CODE.secboot.4m.fd',
            add a TPM (emulated, v2.0), virtio disk/NIC, and attach the
            virtio-win driver ISO (download from fedorapeople.org, or 'virtio-win' in the AUR).
            VM images live in /var/lib/libvirt/images (own subvolume, no CoW, not snapshotted).
EOF
fi
[[ $INSTALL_UFW == yes ]] && echo "  Firewall: 'sudo ufw status verbose' after first boot."
