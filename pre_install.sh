#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[pre-install] $*"; }

# ---------------------------
# Variables (adjust as needed)
# ---------------------------
DISK="/dev/sda"            # target disk
ESP_PART="${DISK}1"        # EFI System Partition
CRYPT_PART="${DISK}2"      # LUKS-encrypted root partition
HOSTNAME="archlinux"
USERNAME="archuser"
ROOT_PASS="changeme"
USER_PASS="changeme"

# ---------------------------
# 1. Prepare partitions
# ---------------------------
log "Formatting EFI partition..."
mkfs.fat -F32 "$ESP_PART"

log "Setting up LUKS encryption on root..."
cryptsetup luksFormat "$CRYPT_PART"
cryptsetup open "$CRYPT_PART" cryptroot

# ---------------------------
# 2. Setup Btrfs subvolumes
# ---------------------------
log "Creating Btrfs filesystem and subvolumes..."
mkfs.btrfs /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@.snapshots
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_pkgs

umount /mnt

log "Mounting subvolumes..."
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt

mkdir -p /mnt/{boot,home,root,.snapshots,srv,var/log,var/cache/pacman/pkg}

mount -o subvol=@home,compress=zstd       /dev/mapper/cryptroot /mnt/home
mount -o subvol=@.snapshots,compress=zstd /dev/mapper/cryptroot /mnt/.snapshots
mount -o subvol=@srv,compress=zstd        /dev/mapper/cryptroot /mnt/srv
mount -o subvol=@var_log,compress=zstd    /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@var_pkgs,compress=zstd   /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg

log "Mounting EFI partition..."
mount "$ESP_PART" /mnt/boot

# ---------------------------
# 3. Bootstrap base system
# ---------------------------
log "Installing base system..."
pacstrap -K /mnt base linux linux-lts linux-firmware btrfs-progs vim nano \
  efibootmgr networkmanager sudo sbsigntools

# ---------------------------
# 4. Generate fstab
# ---------------------------
log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ---------------------------
# 5. Chroot configuration
# ---------------------------
log "Entering chroot for configuration..."
arch-chroot /mnt /usr/bin/env bash <<EOF
set -euo pipefail

# Timezone, locale, hostname
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# mkinitcpio hooks (tested working: encrypt + btrfs + fsck)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install systemd-boot
bootctl install

# Loader configuration
cat > /boot/loader/loader.conf <<EOF2
default arch.conf
timeout 3
editor no
EOF2

# UUID for cryptdevice
ROOT_UUID=\$(blkid -s UUID -o value "$CRYPT_PART")

# Boot entries
cat > /boot/loader/entries/arch.conf <<EOF2
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=\$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

cat > /boot/loader/entries/arch-fallback.conf <<EOF2
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=\$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

cat > /boot/loader/entries/arch-lts.conf <<EOF2
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options cryptdevice=UUID=\$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

cat > /boot/loader/entries/arch-lts-fallback.conf <<EOF2
title   Arch Linux (LTS Fallback)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts-fallback.img
options cryptdevice=UUID=\$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

# Users and passwords
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager
EOF

log "✅ Pre-install finished. Reboot into the system and run post-install.sh"
