#!/usr/bin/env bash
# =============================================================================
# 01-arch-install.sh
# Arch Linux install: LUKS2 (PBKDF2) + Btrfs subvolumes + GRUB, single passphrase
#
# Run from the Arch ISO as root, AFTER connecting to the network (iwctl).
# Covers guide steps 1-12: partition -> LUKS -> Btrfs -> pacstrap -> chroot
# config -> keyfile -> mkinitcpio -> GRUB. Then run 02-post-install.sh as
# your user after first boot.
#
# THIS WIPES THE TARGET DISK.
# =============================================================================
set -Eeuo pipefail

# ---------- helpers ----------------------------------------------------------
c_info=$'\e[1;36m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
trap 'printf "%sERROR:%s line %s: %s\n" "$c_err" "$c_off" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ask "Prompt" "default" -> echoes answer
ask() {
  local prompt=$1 default=${2-} reply
  if [[ -n $default ]]; then
    read -rp "$prompt [$default]: " reply
    printf '%s' "${reply:-$default}"
  else
    while [[ -z ${reply-} ]]; do read -rp "$prompt: " reply; done
    printf '%s' "$reply"
  fi
}

# yesno "Prompt" y|n -> returns 0 for yes
yesno() {
  local prompt=$1 default=$2 reply hint
  [[ $default == y ]] && hint="Y/n" || hint="y/N"
  read -rp "$prompt [$hint]: " reply
  reply=${reply:-$default}
  [[ ${reply,,} == y* ]]
}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# ---------- fixed layout (matches the guide) ---------------------------------
ESP_SIZE="2G"
MAPPER="cryptroot"
BTRFS_LABEL="arch"
MOUNT_OPTS="noatime,compress=zstd:3"
# subvolume:mountpoint (relative to /mnt)
SUBVOLS=(
  "@home:home"
  "@srv:srv"
  "@cache:var/cache"
  "@log:var/log"
  "@tmp:var/tmp"
  "@spool:var/spool"
  "@libvirt:var/lib/libvirt/images"
  "@snapshots:.snapshots"
)
HOOKS_LINE='HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)'

# =============================================================================
# 0. Pre-flight checks
# =============================================================================
info "Pre-flight checks"
[[ $EUID -eq 0 ]] || die "Run as root from the Arch ISO."
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode."
ok "UEFI mode"
findmnt /mnt >/dev/null 2>&1 && die "/mnt is already mounted. Run: umount -R /mnt"
[[ -e /dev/mapper/$MAPPER ]] && die "/dev/mapper/$MAPPER already open. Run: cryptsetup close $MAPPER"
ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 \
  || die "No network. Connect first: iwctl -> station wlan0 connect \"SSID\""
ok "Network up"
setfont ter-128b 2>/dev/null || true
timedatectl set-ntp true
ok "Clock sync enabled"

# =============================================================================
# 1. Gather settings
# =============================================================================
info "Available disks:"
lsblk -dpno NAME,SIZE,MODEL | grep -Ev 'loop|sr[0-9]|zram' || true
echo
DISK=$(ask "Target disk (full path)" "/dev/nvme0n1")
[[ -b $DISK ]] || die "$DISK is not a block device."
[[ $DISK =~ (nvme|mmcblk|loop) ]] && PART_PREFIX="${DISK}p" || PART_PREFIX="$DISK"
ESP_PART="${PART_PREFIX}1"
LUKS_PART="${PART_PREFIX}2"

HOSTNAME_=$(ask "Hostname" "vvg-nb-arch")
USERNAME=$(ask "Username" "robert")
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username: $USERNAME"
TIMEZONE=$(ask "Timezone" "America/Phoenix")
[[ -f /usr/share/zoneinfo/$TIMEZONE ]] || die "Unknown timezone: $TIMEZONE"
LOCALE=$(ask "Locale" "en_US.UTF-8")
grep -q "^#\?${LOCALE} " /etc/locale.gen || die "Locale $LOCALE not found in /etc/locale.gen"

if grep -q GenuineIntel /proc/cpuinfo; then UCODE_DEFAULT=intel-ucode
elif grep -q AuthenticAMD /proc/cpuinfo; then UCODE_DEFAULT=amd-ucode
else UCODE_DEFAULT=intel-ucode; fi
UCODE=$(ask "CPU microcode package" "$UCODE_DEFAULT")
[[ $UCODE == intel-ucode || $UCODE == amd-ucode ]] || die "Use intel-ucode or amd-ucode."

echo
warn "SOF audio fix (dsp_driver=3) is for Intel Core Ultra / SoundWire laptops"
warn "where only HDMI audio appears. Do NOT enable it on older Intel or AMD machines."
SOF_FIX=n
yesno "Apply SOF audio fix?" n && SOF_FIX=y

# ---------- LUKS passphrase (read once, used for format/open/addkey) ---------
echo
warn "GRUB's unlock prompt uses a US keyboard layout. Use a passphrase you can type on one."
while true; do
  read -rsp "LUKS passphrase: " LUKS_PASS; echo
  read -rsp "Confirm passphrase: " LUKS_PASS2; echo
  [[ -n $LUKS_PASS ]] || { warn "Passphrase cannot be empty."; continue; }
  [[ $LUKS_PASS == "$LUKS_PASS2" ]] && break
  warn "Passphrases do not match. Try again."
done
unset LUKS_PASS2

# ---------- confirm ----------------------------------------------------------
echo
info "Summary"
cat <<EOF
  Disk:        $DISK  (ESP $ESP_PART = $ESP_SIZE FAT32, LUKS $LUKS_PART = rest)
  Hostname:    $HOSTNAME_
  User:        $USERNAME (wheel / sudo)
  Timezone:    $TIMEZONE
  Locale:      $LOCALE
  Microcode:   $UCODE
  SOF fix:     $SOF_FIX
  Mount opts:  $MOUNT_OPTS
EOF
lsblk "$DISK"
echo
warn "ALL DATA ON $DISK WILL BE DESTROYED."
CONFIRM=$(ask "Type the disk path again to confirm")
[[ $CONFIRM == "$DISK" ]] || die "Confirmation did not match. Nothing was changed."

# =============================================================================
# 2. Partition
# =============================================================================
info "Partitioning $DISK"
wipefs -af "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:+"$ESP_SIZE" -t1:ef00 -c1:EFI \
       -n2:0:0            -t2:8309 -c2:cryptroot "$DISK"
partprobe "$DISK"; udevadm settle; sleep 1
mkfs.fat -F32 -n EFI "$ESP_PART"
ok "Partitions created"

# =============================================================================
# 3. LUKS2 with PBKDF2 (GRUB cannot unlock Argon2)
# =============================================================================
info "Encrypting $LUKS_PART (LUKS2, PBKDF2)"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
  --hash sha512 --batch-mode --key-file=- "$LUKS_PART"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$LUKS_PART" "$MAPPER"
cryptsetup luksDump "$LUKS_PART" | grep -i argon2 >/dev/null && die "Keyslot uses Argon2. GRUB cannot unlock it."
ok "LUKS2 keyslot 0 uses PBKDF2"

# =============================================================================
# 4. Btrfs + subvolumes
# =============================================================================
info "Creating Btrfs and subvolumes"
mkfs.btrfs -f -L "$BTRFS_LABEL" "/dev/mapper/$MAPPER"
mount "/dev/mapper/$MAPPER" /mnt
btrfs subvolume create /mnt/@
for entry in "${SUBVOLS[@]}"; do btrfs subvolume create "/mnt/${entry%%:*}"; done
umount /mnt
ok "Subvolumes created"

# =============================================================================
# 5. Mount everything
# =============================================================================
info "Mounting subvolumes"
mount -o "$MOUNT_OPTS,subvol=@" "/dev/mapper/$MAPPER" /mnt
mkdir -p /mnt/efi
for entry in "${SUBVOLS[@]}"; do
  sv=${entry%%:*}; mp=${entry#*:}
  mkdir -p "/mnt/$mp"
  mount -o "$MOUNT_OPTS,subvol=$sv" "/dev/mapper/$MAPPER" "/mnt/$mp"
done
chattr +C /mnt/var/lib/libvirt/images
mount -o umask=0077 "$ESP_PART" /mnt/efi
expected=$(( ${#SUBVOLS[@]} + 2 ))   # @ + subvols + efi
actual=$(findmnt -R -n -o TARGET /mnt | wc -l)
[[ $actual -eq $expected ]] || { findmnt -R /mnt; die "Expected $expected mounts under /mnt, found $actual."; }
ok "All $actual mounts in place"

# =============================================================================
# 6. pacstrap + fstab
# =============================================================================
info "Refreshing ISO keyring"
pacman -Sy --noconfirm --needed archlinux-keyring

info "Installing base system (pacstrap)"
PACKAGES=(
  base base-devel linux linux-firmware btrfs-progs cryptsetup
  grub efibootmgr grub-btrfs inotify-tools "$UCODE"
  networkmanager sudo vim nano terminus-font fwupd
  sof-firmware alsa-firmware alsa-ucm-conf alsa-utils
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
)
pacstrap -K /mnt "${PACKAGES[@]}"

genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/,subvolid=[0-9]*//' /mnt/etc/fstab
ok "fstab written (subvolid removed for Snapper rollbacks)"

# =============================================================================
# 7. System configuration
# =============================================================================
info "Configuring system"
arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
arch-chroot /mnt hwclock --systohc
sed -i "/^#${LOCALE} /s/^#//" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
echo "FONT=ter-128b" > /mnt/etc/vconsole.conf
echo "$HOSTNAME_" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_.localdomain $HOSTNAME_
EOF

arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
echo '%wheel ALL=(ALL:ALL) ALL' > /mnt/etc/sudoers.d/10-wheel
chmod 440 /mnt/etc/sudoers.d/10-wheel
arch-chroot /mnt visudo -c >/dev/null || die "sudoers syntax check failed."

info "Set the ROOT password"
until arch-chroot /mnt passwd; do warn "Try again."; done
info "Set the password for $USERNAME"
until arch-chroot /mnt passwd "$USERNAME"; do warn "Try again."; done

arch-chroot /mnt systemctl enable NetworkManager

if [[ $SOF_FIX == y ]]; then
  echo "options snd-intel-dspcfg dsp_driver=3" > /mnt/etc/modprobe.d/sof.conf
  ok "SOF audio driver forced"
fi
ok "System configured"

# =============================================================================
# 9. Keyfile (single passphrase prompt)
# =============================================================================
info "Creating and enrolling keyfile"
dd bs=512 count=4 if=/dev/random of=/mnt/crypto_keyfile.bin iflag=fullblock status=none
chmod 600 /mnt/crypto_keyfile.bin
printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
  --key-file=- "$LUKS_PART" /mnt/crypto_keyfile.bin
unset LUKS_PASS
cryptsetup open --test-passphrase --key-file /mnt/crypto_keyfile.bin "$LUKS_PART" \
  || die "Keyfile does not unlock $LUKS_PART."
slots=$(cryptsetup luksDump "$LUKS_PART" | grep -ci 'pbkdf2')
[[ $slots -ge 2 ]] || die "Expected 2 PBKDF2 keyslots, found $slots."
ok "Keyfile enrolled; $slots PBKDF2 keyslots"

# =============================================================================
# 10. mkinitcpio
# =============================================================================
info "Configuring mkinitcpio"
sed -i 's|^FILES=.*|FILES=(/crypto_keyfile.bin)|' /mnt/etc/mkinitcpio.conf
sed -i "s|^HOOKS=.*|$HOOKS_LINE|" /mnt/etc/mkinitcpio.conf
grep -q '^FILES=(/crypto_keyfile.bin)' /mnt/etc/mkinitcpio.conf || die "FILES= line not set."
grep -q ' encrypt ' /mnt/etc/mkinitcpio.conf || die "encrypt hook not set."
arch-chroot /mnt mkinitcpio -P
arch-chroot /mnt lsinitcpio /boot/initramfs-linux.img | grep 'crypto_keyfile.bin' >/dev/null \
  || die "Keyfile is NOT in the initramfs."
ok "Keyfile embedded in initramfs"

# =============================================================================
# 11. GRUB
# =============================================================================
info "Installing GRUB"
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")
GRUB_CMD="cryptdevice=UUID=${LUKS_UUID}:${MAPPER} cryptkey=rootfs:/crypto_keyfile.bin"
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_CMD\"|" /mnt/etc/default/grub
if grep -q '^#\?GRUB_ENABLE_CRYPTODISK=' /mnt/etc/default/grub; then
  sed -i 's|^#\?GRUB_ENABLE_CRYPTODISK=.*|GRUB_ENABLE_CRYPTODISK=y|' /mnt/etc/default/grub
else
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /mnt/etc/default/grub
fi
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi \
  --boot-directory=/boot --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
grep -q "cryptdevice=UUID=${LUKS_UUID}:${MAPPER}" /mnt/boot/grub/grub.cfg \
  || die "cryptdevice= missing from grub.cfg."
grep -q 'cryptkey=rootfs:/crypto_keyfile.bin' /mnt/boot/grub/grub.cfg \
  || die "cryptkey= missing from grub.cfg."
ok "GRUB installed and verified"

# =============================================================================
# Hand off post-install script
# =============================================================================
if [[ -f $SCRIPT_DIR/02-post-install.sh ]]; then
  install -Dm755 "$SCRIPT_DIR/02-post-install.sh" "/mnt/home/$USERNAME/02-post-install.sh"
  arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/02-post-install.sh"
  ok "Copied 02-post-install.sh to /home/$USERNAME"
fi

# =============================================================================
# 12. Finish
# =============================================================================
echo
ok "Installation complete."
cat <<EOF

  On boot: GRUB asks for the passphrase ONCE (expect a 5-20 second pause).
  The kernel then unlocks silently with the keyfile.

  After first login, connect Wi-Fi:  nmcli device wifi connect "SSID" --ask
  Then run as $USERNAME:             ~/02-post-install.sh
EOF
echo
if yesno "Unmount and reboot now?" y; then
  umount -R /mnt
  cryptsetup close "$MAPPER"
  reboot
fi
