#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[pre-install] $*"; }

# --- Variables (export these before running) ---
DISK="${DISK:-}"
HOSTNAME="${HOSTNAME:-archhost}"
USERNAME="${USERNAME:-user}"

# Secure password handling
get_secure_password() {
    local prompt="$1"
    local password password_confirm
    while true; do
        read -r -s -p "$prompt: " password
        echo >&2
        read -r -s -p "Confirm $prompt: " password_confirm
        echo >&2
        if [[ "$password" == "$password_confirm" ]]; then
            if [[ ${#password} -ge 8 ]]; then
                echo "$password"
                break
            else
                echo "ERROR: Password must be at least 8 characters long" >&2
            fi
        else
            echo "ERROR: Passwords do not match" >&2
        fi
    done
}

ROOT_PASS="${ROOT_PASS:-$(get_secure_password "Root password")}"
USER_PASS="${USER_PASS:-$(get_secure_password "User password for $USERNAME")}"

log "Target disk: $DISK"

# --- Validation helpers ---
validate_disk() {
    local disk="$1"
    [[ -b "$disk" ]] || { echo "ERROR: $disk is not a block device" >&2; exit 1; }
    [[ "$disk" =~ ^/dev/ ]] || { echo "ERROR: Invalid disk path: $disk" >&2; exit 1; }
    [[ -w "$disk" ]] || { echo "ERROR: No write permission for $disk" >&2; exit 1; }
}

validate_password() {
    local pass="$1" pass_type="$2"
    [[ ${#pass} -ge 8 ]] || { echo "ERROR: $pass_type password must be at least 8 characters" >&2; exit 1; }
    [[ "$pass" =~ [A-Z] ]] || { echo "ERROR: $pass_type password must contain uppercase letters" >&2; exit 1; }
    [[ "$pass" =~ [a-z] ]] || { echo "ERROR: $pass_type password must contain lowercase letters" >&2; exit 1; }
    [[ "$pass" =~ [0-9] ]] || { echo "ERROR: $pass_type password must contain numbers" >&2; exit 1; }
}

validate_parameters() {
    [[ -n "$DISK" ]] || { echo "ERROR: DISK parameter is required" >&2; exit 1; }
    [[ -n "$HOSTNAME" ]] || { echo "ERROR: HOSTNAME parameter is required" >&2; exit 1; }
    [[ -n "$USERNAME" ]] || { echo "ERROR: USERNAME parameter is required" >&2; exit 1; }
    [[ -n "$ROOT_PASS" ]] || { echo "ERROR: ROOT_PASS parameter is required" >&2; exit 1; }
    [[ -n "$USER_PASS" ]] || { echo "ERROR: USER_PASS parameter is required" >&2; exit 1; }
    validate_disk "$DISK"
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "ERROR: Invalid username format" >&2; exit 1; }
    [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "ERROR: Invalid hostname format" >&2; exit 1; }
    validate_password "$ROOT_PASS" "Root"
    validate_password "$USER_PASS" "User"
    [[ "$ROOT_PASS" != "$USER_PASS" ]] || { echo "ERROR: Root and user passwords must be different" >&2; exit 1; }
    log "All parameters validated successfully"
}

validate_parameters

EFI_PART="${DISK}1"
CRYPT_PART="${DISK}2"

# --- Partitioning ---
log "Creating GPT partition table on $DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$DISK" mkpart primary 513MiB 100%
parted -s "$DISK" set 1 boot on
partprobe "$DISK"
sleep 2

log "Formatting EFI partition"
mkfs.fat -F32 "$EFI_PART"

log "Setting up LUKS"
sleep 5
cryptsetup luksFormat --type luks2 "$CRYPT_PART"
cryptsetup open "$CRYPT_PART" cryptroot

log "Creating Btrfs filesystem and subvolumes"
mkfs.btrfs "/dev/mapper/cryptroot"
mount "/dev/mapper/cryptroot" /mnt
for subvol in @ @home @.snapshots @srv @var_log @var_pkgs; do
    btrfs subvolume create "/mnt/$subvol"
done
umount /mnt

mount -o "subvol=@,compress=zstd" "/dev/mapper/cryptroot" /mnt
for m in "home:@home" ".snapshots:@.snapshots" "srv:@srv" "var/log:@var_log" "var/cache/pacman/pkg:@var_pkgs"; do
    dir="${m%%:*}"; subvol="${m##*:}"
    mkdir -p "/mnt/$dir"
    mount -o "subvol=${subvol},compress=zstd" "/dev/mapper/cryptroot" "/mnt/$dir"
done

mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --- Bootstrap system ---
log "Optimizing mirrors with reflector"
reflector --country India,UnitedStates,Germany,Japan --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || pacman -Syy --noconfirm

log "Installing base system"
packages=(base linux linux-lts linux-firmware btrfs-progs cryptsetup efibootmgr intel-ucode snapper snap-pac sbsigntools zram-generator reflector vi less git openssl iwd nano sudo)
pacman -Sy --noconfirm
pacstrap /mnt "${packages[@]}"

log "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot configuration ---
log "Entering chroot to configure system"
arch-chroot /mnt /usr/bin/env -i \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/sbin:/bin" \
  HOSTNAME="$HOSTNAME" \
  USERNAME="$USERNAME" \
  ROOT_PASS="$ROOT_PASS" \
  USER_PASS="$USER_PASS" \
  CRYPT_PART="$CRYPT_PART" \
  bash -s <<'CHROOT_EOF'
set -euo pipefail

# Define log function inside chroot
log(){ echo "[chroot] $*"; }

log "Starting chroot configuration..."
log "Environment check:"
log "  HOSTNAME: $HOSTNAME"
log "  USERNAME: $USERNAME" 
log "  CRYPT_PART: $CRYPT_PART"

ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# mkinitcpio hooks
perl -0777 -pe 's/^HOOKS=.*$/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems btrfs fsck)/m' -i /etc/mkinitcpio.conf
mkinitcpio -P

# systemd-boot
bootctl install
ROOT_UUID=$(blkid -s UUID -o value "$CRYPT_PART")

cat > /boot/loader/loader.conf <<EOF2
default arch.conf
timeout 3
editor no
EOF2

cat > /boot/loader/entries/arch.conf <<EOF2
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

cat > /boot/loader/entries/arch-fallback.conf <<EOF2
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

if [[ -f /boot/vmlinuz-linux-lts ]]; then
  cat > /boot/loader/entries/arch-lts.conf <<EOF2
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2
  cat > /boot/loader/entries/arch-lts-fallback.conf <<EOF2
title   Arch Linux (LTS Fallback)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts-fallback.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2
fi

# Accounts
log "Setting up user accounts..."
log "Username: $USERNAME"

# Set root password (root user already exists in base system)
echo "root:$ROOT_PASS" | chpasswd && log "Root password set successfully" || log "ERROR: Failed to set root password"

# Create regular user only if it doesn't exist
if ! id "$USERNAME" &>/dev/null; then
    log "Creating user $USERNAME..."
    if useradd -m -G wheel -s /bin/bash "$USERNAME"; then
        log "User $USERNAME created successfully"
    else
        log "ERROR: Failed to create user $USERNAME"
        exit 1
    fi
else
    log "User $USERNAME already exists, skipping creation"
    # Add to wheel group if not already a member
    if ! groups "$USERNAME" | grep -q wheel; then
        if usermod -aG wheel "$USERNAME"; then
            log "Added $USERNAME to wheel group"
        else
            log "ERROR: Failed to add $USERNAME to wheel group"
        fi
    fi
fi

# Verify user was created
if id "$USERNAME" &>/dev/null; then
    log "User verification: $USERNAME exists"
    log "User groups: $(groups $USERNAME)"
else
    log "ERROR: User $USERNAME was not created properly"
    exit 1
fi

# Set user password
if echo "$USERNAME:$USER_PASS" | chpasswd; then
    log "User password set successfully"
else
    log "ERROR: Failed to set user password"
    exit 1
fi

# Sudo configuration
cp /etc/sudoers /etc/sudoers.bak
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
log "Sudo access configured for wheel group"

# Networking
systemctl enable systemd-networkd systemd-resolved iwd || true

# Reflector config
cat > /etc/reflector.conf <<EOF2
--save /etc/pacman.d/mirrorlist
--country India,Singapore,Germany
--protocol https
--latest 20
--sort rate
--age 12
--completion-percent 100
EOF2
systemctl enable reflector.timer || true
systemctl start reflector.timer || true

# Pacman tweaks
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf || echo "ParallelDownloads = 5" >> /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf

# Validation
log "Performing final validation checks..."
checks=0
[[ -f "/boot/EFI/systemd/systemd-bootx64.efi" ]] && ((checks++)) && log "✓ systemd-boot installed"
[[ -f "/boot/vmlinuz-linux" ]] && ((checks++)) && log "✓ Linux kernel installed"
id "$USERNAME" &>/dev/null && ((checks++)) && log "✓ User $USERNAME exists"
groups "$USERNAME" | grep -q wheel && ((checks++)) && log "✓ User in wheel group"
systemctl is-enabled systemd-networkd &>/dev/null && ((checks++)) && log "✓ Network services enabled"

echo "[INFO] Validation score: $checks/5"
if [[ $checks -ge 4 ]]; then
    echo "[SUCCESS] Pre-installation completed successfully!"
else
    echo "[WARNING] Some components may need manual verification"
    exit 1
fi
CHROOT_EOF

log "Pre-install complete. System is ready for first boot!"
log "Remember to reboot and remove installation media."
