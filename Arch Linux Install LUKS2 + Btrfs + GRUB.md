# Arch Linux Install: LUKS2 + Btrfs + GRUB

Oct 12, 2026 · @Robert

## Overview

This build gives one LUKS passphrase prompt at boot, an encrypted /boot that Snapper can snapshot, and a 2 GB FAT32 ESP that holds only the GRUB EFI binary.

- **Disk:** `nvme0n1p1` = 2 GB FAT32 ESP mounted at `/efi`. `nvme0n1p2` = the rest of the disk, LUKS2, opened as `cryptroot`, formatted Btrfs.
- **/boot lives inside the encrypted Btrfs root** (`@` subvolume). Kernels, initramfs and `/boot/grub` are encrypted and included in root snapshots.
- **Key derivation: PBKDF2, not Argon2id.** Argon2id is the LUKS2 default, and GRUB cannot unlock Argon2 keyslots. Every keyslot on this disk uses PBKDF2.
- **Single passphrase:** GRUB asks once to unlock the disk. A keyfile embedded in the initramfs then unlocks it again for the kernel silently. Without the keyfile you get a second prompt, which is what happened with archinstall.
- **Initramfs:** busybox-based hooks with `encrypt`, not the systemd/`sd-encrypt` default, because the `cryptdevice=` and `cryptkey=` kernel parameters belong to the `encrypt` hook.

Replace `/dev/nvme0n1` everywhere with your actual disk (check with `lsblk`).

## 1. Boot the ISO and prepare

Boot the Arch ISO in UEFI mode, then confirm UEFI and set a readable console font.

```bash
ls /sys/firmware/efi/efivars   # must list files = UEFI mode
setfont ter-128b               # larger Terminus console font
```

Connect to Wi-Fi with `iwctl`. The `NetworkConfigurationEnabled: disabled` line it prints is normal; systemd-networkd handles DHCP on the ISO.

```bash
iwctl
[iwd]# device list
[iwd]# station wlan0 scan
[iwd]# station wlan0 get-networks
[iwd]# station wlan0 connect "YourSSID"
[iwd]# exit

ping -c 3 archlinux.org
timedatectl set-ntp true
timedatectl                    # confirm: System clock synchronized: yes
```

If the device is missing or off: `rfkill unblock wifi`, or inside iwctl `device wlan0 set-property Powered on`.

## 2. Partition the disk

Two GPT partitions: a 2 GB EFI system partition and one LUKS partition filling the rest. This wipes the disk.

```bash
sgdisk -Z /dev/nvme0n1
sgdisk -n1:0:+2G -t1:ef00 -c1:EFI \
       -n2:0:0   -t2:8309 -c2:cryptroot /dev/nvme0n1
mkfs.fat -F32 -n EFI /dev/nvme0n1p1
```

## 3. Encrypt with LUKS2 (PBKDF2)

Format with PBKDF2 so GRUB can unlock it, then open it as `cryptroot`. Type `YES` in capitals when asked.

```bash
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --hash sha512 /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 cryptroot
```

Verify the keyslot is PBKDF2 before going further:

```bash
cryptsetup luksDump /dev/nvme0n1p2 | grep -iE "luks2|pbkdf"
```

It must say `pbkdf2`. If it says `argon2id`, rerun `luksFormat`.

- Use the mapper name `cryptroot` everywhere. The mounts and the GRUB `cryptdevice=` line all depend on it.
- GRUB's prompt uses a US keyboard layout. Pick a passphrase you can type on one.

## 4. Create Btrfs and subvolumes

Nine subvolumes: the eight requested plus `@snapshots`, which Snapper needs for clean rollbacks.

```bash
mkfs.btrfs -f -L arch /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @srv @cache @log @tmp @spool @libvirt @snapshots; do
  btrfs subvolume create /mnt/$sv
done
umount /mnt
```

| Subvolume | Mount point | Why separate |
| --- | --- | --- |
| `@` | `/` | Root, including `/boot`; what Snapper snapshots and rolls back |
| `@home` | `/home` | User data survives a root rollback |
| `@srv` | `/srv` | Served data kept out of root snapshots |
| `@cache` | `/var/cache` | Package cache; no value in snapshotting it |
| `@log` | `/var/log` | Logs survive rollback, useful for diagnosing what broke |
| `@tmp` | `/var/tmp` | Temporary files kept out of snapshots |
| `@spool` | `/var/spool` | Mail and print queues survive rollback |
| `@libvirt` | `/var/lib/libvirt/images` | VM disks; copy-on-write disabled with `chattr +C` |
| `@snapshots` | `/.snapshots` | Snapper's snapshot store |

## 5. Mount everything

Mount `@` first, create the mount points, then mount the rest. Every `mount` line has a **space** between the device and the mount point.

```bash
o=noatime,compress=zstd:3
mount -o $o,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{efi,home,srv,.snapshots,var/{cache,log,tmp,spool,lib/libvirt/images}}

mount -o $o,subvol=@home      /dev/mapper/cryptroot /mnt/home
mount -o $o,subvol=@srv       /dev/mapper/cryptroot /mnt/srv
mount -o $o,subvol=@cache     /dev/mapper/cryptroot /mnt/var/cache
mount -o $o,subvol=@log       /dev/mapper/cryptroot /mnt/var/log
mount -o $o,subvol=@tmp       /dev/mapper/cryptroot /mnt/var/tmp
mount -o $o,subvol=@spool     /dev/mapper/cryptroot /mnt/var/spool
mount -o $o,subvol=@libvirt   /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
mount -o $o,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

chattr +C /mnt/var/lib/libvirt/images   # no CoW for VM disk images
mount -o umask=0077 /dev/nvme0n1p1 /mnt/efi

findmnt -R /mnt                          # verify before pacstrap
```

`findmnt` must show `/mnt`, the eight sub-mounts and `/mnt/efi`. Note the leading dot in `.snapshots`. `zstd:3` was used here; `zstd:1` trades a little ratio for less CPU.

## 6. Install the base system and generate fstab

Use `-K` so pacstrap initializes the new system's pacman keyring. Swap `intel-ucode` for `amd-ucode` on AMD.

```bash
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs cryptsetup \
  grub efibootmgr grub-btrfs inotify-tools intel-ucode \
  networkmanager sudo vim nano terminus-font \
  sof-firmware alsa-firmware alsa-ucm-conf alsa-utils \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber

genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/,subvolid=[0-9]*//' /mnt/etc/fstab   # needed for Snapper rollbacks
arch-chroot /mnt
```

If pacstrap reports `Partition / too full`, `/mnt` is not mounted and it is writing to the ISO's RAM disk. Go back to step 5.

## 7. Configure the system (inside chroot)

```bash
# Time
ln -sf /usr/share/zoneinfo/America/Phoenix /etc/localtime
hwclock --systohc

# Locale
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Console font (applied early in boot via the consolefont hook)
echo "FONT=ter-128b" > /etc/vconsole.conf

# Hostname
echo "vvg-nb-archlinux" > /etc/hostname

# Root password
passwd

# User with sudo
useradd -m -G wheel -s /bin/bash robert
passwd robert
EDITOR=vim visudo        # uncomment: %wheel ALL=(ALL:ALL) ALL

# Networking at boot
systemctl enable NetworkManager
```

**Audio (Intel Core Ultra / SoundWire laptops).** `pacstrap` installs the audio firmware and PipeWire, but on newer Intel laptops the kernel may still load the legacy `snd_hda_intel` driver. That driver only exposes HDMI outputs, so the desktop shows Dummy Output. Force the SOF driver now so the `mkinitcpio -P` in step 10 includes it:

```bash
echo "options snd-intel-dspcfg dsp_driver=3" > /etc/modprobe.d/sof.conf
```

PipeWire runs as **user** services that start automatically on login; don't enable them as root. Archinstall's audio option installs these packages for you, which is why audio worked there out of the box; a manual install has to add them.

## 8. Verify the pacman keyring

`pacstrap -K` normally handles this. If pacman reports `unknown trust` or `invalid or corrupted package (PGP signature)`, rebuild the keyring:

```bash
gpgconf --homedir /etc/pacman.d/gnupg --kill all   # stop any stale gpg-agent
killall gpg-agent                                 # "no process found" is fine
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring
```

`--init` must finish without `agent_genkey failed`. That error means a stale gpg-agent is still running; kill it and repeat. Never set `SigLevel = Never` as a workaround.

## 9. Add the keyfile (prevents the second prompt)

Create a random keyfile and add it to LUKS keyslot 1, also with PBKDF2. Low iterations are safe because the keyfile itself is high-entropy and lives inside the encrypted volume.

```bash
dd bs=512 count=4 if=/dev/random of=/crypto_keyfile.bin iflag=fullblock
chmod 600 /crypto_keyfile.bin
cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/nvme0n1p2 /crypto_keyfile.bin
```

The device and the keyfile are **two separate arguments**: `/dev/nvme0n1p2` then `/crypto_keyfile.bin`, with a space between. Enter the LUKS passphrase when asked.

Verify two slots, both PBKDF2:

```bash
cryptsetup luksDump /dev/nvme0n1p2 | grep -iE "luks2|pbkdf"
```

## 10. Configure mkinitcpio

Edit `/etc/mkinitcpio.conf`. The current default `HOOKS` line is systemd-based and has no encryption hook, so replace it.

```
FILES=(/crypto_keyfile.bin)
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)
```

- `systemd` → `udev`, and `sd-vconsole` → `keymap consolefont`: switches to the busybox initramfs.
- `encrypt` after `block`: reads the `cryptdevice=` and `cryptkey=` parameters set in GRUB.

Rebuild the images. Missing-firmware warnings are normal; ERROR lines are not.

```bash
mkinitcpio -P
```

**Verify before rebooting.** Confirm the keyfile was actually embedded. If this prints nothing, `FILES=` is still empty or `mkinitcpio -P` ran before the keyfile existed; fix `FILES=` and rebuild.

```bash
grep ^FILES /etc/mkinitcpio.conf                          # FILES=(/crypto_keyfile.bin)
lsinitcpio /boot/initramfs-linux.img | grep crypto_keyfile # must print crypto_keyfile.bin
```

## 11. Install and configure GRUB

Get the UUID of the LUKS partition (not the mapper device):

```bash
blkid -s UUID -o value /dev/nvme0n1p2
```

Edit `/etc/default/grub`:

```
GRUB_ENABLE_CRYPTODISK=y
GRUB_CMDLINE_LINUX="cryptdevice=UUID=<luks-uuid>:cryptroot cryptkey=rootfs:/crypto_keyfile.bin"
```

Install GRUB with the EFI binary on the ESP and its files under `/boot/grub` on the encrypted Btrfs:

```bash
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
```

`grub-mkconfig` adds `root=` and `rootflags=subvol=@` automatically, and picks up the microcode image.

## 12. Reboot and first boot

```bash
exit                 # leave the chroot
umount -R /mnt
cryptsetup close cryptroot
reboot
```

On boot, GRUB asks for the passphrase once. Expect a 5–20 second pause after entering it; GRUB's PBKDF2 unlock is slow. The kernel then unlocks with the keyfile, with no second prompt.

Log in as root or your user and connect to Wi-Fi with NetworkManager:

```bash
nmcli radio wifi on
nmcli device wifi list
nmcli device wifi connect "YourSSID" --ask
ping -c 3 archlinux.org
```

For the desktop, continue with step 13.

The system is now ready for Snapper setup.

## 13. Install KDE Plasma

Install a lean Plasma desktop with networking, Bluetooth, power management, audio and display tools. `--needed` skips packages already installed in step 6 (NetworkManager, PipeWire, WirePlumber).

```bash
sudo pacman -S --needed \
  plasma-desktop \
  plasma-login-manager \
  plasma-nm networkmanager \
  bluedevil bluez bluez-utils \
  powerdevil power-profiles-daemon \
  plasma-pa pipewire pipewire-pulse wireplumber \
  kscreen \
  xdg-desktop-portal-kde \
  konsole dolphin dolphin-plugins kate \
  breeze-gtk kde-gtk-config \
  noto-fonts \
  kwallet kwalletmanager kwallet-pam ksshaskpass \
  kdeplasma-addons \
  discover
```

Enable the system services:

```bash
sudo systemctl enable plasmalogin.service           # Plasma Login Manager
sudo systemctl enable bluetooth.service             # bluez, for bluedevil
sudo systemctl enable power-profiles-daemon.service # power profiles in powerdevil
```

- `NetworkManager.service` was already enabled in step 7.
- PipeWire, `pipewire-pulse` and WirePlumber are **user** services that start on login; don't enable them with `sudo`.
- If another display manager is enabled (for example SDDM), use `sudo systemctl enable -f plasmalogin.service` to replace it.

`kwallet-pam` unlocks KWallet automatically at login, as long as the wallet password matches your login password and the wallet uses Blowfish encryption, not GPG. Keep that in mind when KWallet first asks to create a wallet. Reboot. Plasma Login Manager appears; log in to a Plasma (Wayland) session. Check audio with `wpctl status` and Bluetooth with `bluetoothctl show`.

## 14. Set up Snapper and bootable snapshots

Snapper snapshots `@` (which includes `/boot`), `snap-pac` snapshots before and after every pacman transaction, and `grub-btrfs` lists the snapshots in the GRUB menu. Run these on the installed system as your user with `sudo`.

**Install Snapper.** `grub-btrfs` and `inotify-tools` were already installed in step 6. `btrfs-assistant` is an optional Qt GUI (official repos) for browsing, diffing and restoring snapshots; it reads the Snapper config created below.

```bash
sudo pacman -S snapper snap-pac btrfs-assistant
```

**Create the root config on the existing `@snapshots` subvolume.** `snapper create-config` makes its own nested `.snapshots` subvolume, so remove it and remount `@snapshots` in its place:

```bash
sudo umount /.snapshots
sudo rmdir /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a                    # remounts @snapshots from fstab
sudo chmod 750 /.snapshots
findmnt /.snapshots              # must show subvol=/@snapshots
```

**Tune retention.** Edit `/etc/snapper/configs/root`. These are example limits; adjust to taste:

```
ALLOW_GROUPS="wheel"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
NUMBER_LIMIT="10"
```

**Make snapshots bootable read-write.** Snapshots are read-only, so add the `grub-btrfs-overlayfs` hook to the **end** of `HOOKS` in `/etc/mkinitcpio.conf`:

```
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck grub-btrfs-overlayfs)
```

```bash
sudo mkinitcpio -P
```

**Enable the timers and the GRUB menu watcher:**

```bash
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service
```

**Test.** Take a baseline snapshot and confirm GRUB picks it up:

```bash
sudo snapper -c root create -d "baseline after install"
sudo snapper -c root list
sudo grub-mkconfig -o /boot/grub/grub.cfg   # should report found snapshots
```

Reboot; the GRUB menu now has an **Arch Linux snapshots** submenu. You still enter the passphrase once, because the keyfile is inside each snapshot's initramfs.

**Rolling back.** With this flat `@` layout, `snapper rollback` won't take effect, because fstab mounts `subvol=@` by name. Roll back manually instead, from the ISO or a booted snapshot (replace `N` with the snapshot number from `snapper list`):

```bash
sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt
sudo mv /mnt/@ /mnt/@.broken
sudo btrfs subvolume snapshot /mnt/@snapshots/N/snapshot /mnt/@
sudo umount /mnt
reboot
```

Once the restored system boots fine, delete the old root with `btrfs subvolume delete` on `@.broken` (mount `subvolid=5` again to reach it). `/home`, `/var/log` and the other subvolumes are untouched by a rollback.

## 15. Install the AUR helper paru

Do this after Snapper, so `snap-pac` snapshots every AUR install too (paru hands the finished package to pacman). Run it as your **normal user**: `makepkg` refuses to run as root.

```bash
sudo pacman -S --needed base-devel git
git clone https://aur.archlinux.org/paru.git ~/paru
cd ~/paru
makepkg -si
cd ~ && rm -rf ~/paru
paru --version
```

To skip compiling paru's Rust code, clone `https://aur.archlinux.org/paru-bin.git` instead; the steps are otherwise the same.

Everyday use:

```bash
paru -Syu          # update repo and AUR packages together
paru <search-term> # search, then pick packages to install
paru -S <package>  # install a specific package
```

- paru shows each PKGBUILD before building. Read it: AUR packages are user-submitted and unvetted.
- Optional settings live in `/etc/paru.conf`, for example uncomment `BottomUp` to list the best search match last, nearest the prompt.

## Troubleshooting notes

Problems hit during this install and their fixes.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `mkfs.btrfs`: probe of `/dev/mapper/...` failed | LUKS container never opened | `cryptsetup open /dev/nvme0n1p2 cryptroot` first; put `-f` before `-L` |
| pacstrap: `Partition / too full` | Nothing mounted at `/mnt`; writing to ISO RAM | Remount per step 5, check `findmnt -R /mnt` |
| `mount`: can't find in /etc/fstab | No space between device and mount point | `... /dev/mapper/cryptroot /mnt/home` |
| `luksAddKey`: device does not exist | Device and keyfile typed as one path | `/dev/nvme0n1p2 /crypto_keyfile.bin`, space between |
| `luksDump: requires <device>` | Shell variable like `$DEV` was empty | Type the full device path |
| pacman: `unknown trust` / corrupted package | Keyring empty or uninitialized | Rebuild keyring, step 8 |
| `agent_genkey failed: No such file or directory` | Stale gpg-agent after deleting gnupg dir | `gpgconf --kill all`, `killall gpg-agent`, then `--init` again |
| Two passphrase prompts at boot | No keyfile in initramfs, or `sd-encrypt` hook | Steps 9–11 |
| Boot says keyfile could not be found, then asks for passphrase again | `FILES=()` left empty, so the keyfile isn't in the initramfs | Set `FILES=(/crypto_keyfile.bin)`, `mkinitcpio -P`, verify with `lsinitcpio` (step 10) |
| GRUB rejects a correct passphrase | Keyslot uses Argon2id | Reformat or convert slot to PBKDF2 |
| Plasma shows no sound cards | `sof-firmware` / `alsa-ucm-conf` not installed | Install them (step 6 list), reboot |
| Only HDMI outputs in `aplay -l`; sink is Dummy Output | Legacy `snd_hda_intel` loaded instead of SOF | `dsp_driver=3` in `/etc/modprobe.d/sof.conf`, `mkinitcpio -P`, reboot (step 7) |
