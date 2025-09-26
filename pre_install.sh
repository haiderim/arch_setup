#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[pre-install] $*"; }

# Variables (set these or override via env)
DISK="${DISK:-/dev/sda}"
HOSTNAME="${HOSTNAME:-archhost}"
USERNAME="${USERNAME:-user}"
ROOT_PASS="${ROOT_PASS:-rootpass}"
USER_PASS="${USER_PASS:-userpass}"

log "Target disk: $DISK"

EFI_PART="${DISK}1"
CRYPT_PART="${DISK}2"

# Step 1: Partitioning (you may replace this with parted/sgdisk)
# Here just assume partitions exist; you can add logic if needed.

# Step 2: Format & encrypt
log "Formatting EFI partition $EFI_PART"
mkfs.fat -F32 "$EFI_PART"

log "Setting up LUKS on $CRYPT_PART"
cryptsetup luksFormat --type luks2 "$CRYPT_PART"
cryptsetup open "$CRYPT_PART" cryptroot

# Step 3: Btrfs + subvolumes
log "Creating Btrfs and subvolumes"
mkfs.btrfs /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@.snapshots
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_pkgs
umount /mnt

log "Mounting subvolumes"
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,srv,var/log,var/cache/pacman/pkg}
mount -o subvol=@home,compress=zstd /dev/mapper/cryptroot /mnt/home
mount -o subvol=@.snapshots,compress=zstd /dev/mapper/cryptroot /mnt/.snapshots
mount -o subvol=@srv,compress=zstd /dev/mapper/cryptroot /mnt/srv
mount -o subvol=@var_log,compress=zstd /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@var_pkgs,compress=zstd /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg

# Step 4: Mount EFI
log "Mounting EFI partition"
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# Step 5: Bootstrap base
log "Installing base system"
pacstrap -K /mnt base linux linux-lts linux-firmware btrfs-progs \
  vim sudo networkmanager efibootmgr sbsigntools

# Step 6: fstab
log "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Step 7: Chroot and configure inside
log "Entering chroot to configure system"
arch-chroot /mnt /usr/bin/env bash <<EOF
set -euo pipefail

# Setup locale / time / hostname
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Setup mkinitcpio hooks (encrypt + btrfs + fsck)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install systemd-boot
bootctl install

# Create loader config
cat > /boot/loader/loader.conf <<EOF2
default arch.conf
timeout 3
editor no
EOF2

# Write loader entries
ROOT_UUID=\$(blkid -s UUID -o value "$CRYPT_PART")
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

if [[ -f /boot/vmlinuz-linux-lts ]]; then
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
fi

# User & password
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable network manager
systemctl enable NetworkManager

EOF  # end of arch-chroot

log "Pre-install complete. Now reboot into chroot and run post-install."
