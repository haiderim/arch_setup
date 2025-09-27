#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[pre-install] $*"; }

# Variables (set these or override via env)
DISK="${DISK:-}"
HOSTNAME="${HOSTNAME:-archhost}"
USERNAME="${USERNAME:-user}"

# Secure password handling following security best practices
# Avoid passing passwords via environment variables when possible
get_secure_password() {
    local prompt="$1"
    local password
    local password_confirm

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

# Use environment variables if provided, otherwise prompt securely
ROOT_PASS="${ROOT_PASS:-$(get_secure_password "Root password")}"
USER_PASS="${USER_PASS:-$(get_secure_password "User password for $USERNAME")}"

log "Target disk: $DISK"

# Enhanced input validation following bash best practices
validate_disk() {
    local disk="$1"
    [[ -b "$disk" ]] || { echo "ERROR: $disk is not a block device" >&2; exit 1; }
    [[ "$disk" =~ ^/dev/ ]] || { echo "ERROR: Invalid disk path: $disk" >&2; exit 1; }
    [[ -w "$disk" ]] || { echo "ERROR: No write permission for $disk" >&2; exit 1; }

    # Additional safety checks
    if [[ "$disk" =~ /dev/sda$ && $(lsblk -dno SIZE "$disk" 2>/dev/null || echo 0) < 8G ]]; then
        echo "WARNING: $disk appears small (<8G). Ensure this is the correct disk." >&2
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
}

validate_password() {
    local pass="$1"
    local pass_type="$2"
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

    # Validate disk
    validate_disk "$DISK"

    # Validate username format
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "ERROR: Invalid username format" >&2; exit 1; }

    # Validate hostname format
    [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || {
        echo "ERROR: Invalid hostname format" >&2; exit 1;
    }

    # Validate passwords
    validate_password "$ROOT_PASS" "Root"
    validate_password "$USER_PASS" "User"

    # Check for password reuse
    [[ "$ROOT_PASS" != "$USER_PASS" ]] || {
        echo "ERROR: Root and user passwords must be different" >&2; exit 1;
    }

    log "All parameters validated successfully"
}

validate_parameters

EFI_PART="${DISK}1"
CRYPT_PART="${DISK}2"

# Step 1: Partitioning (you may replace this with parted/sgdisk)
# Here just assume partitions exist; you can add logic if needed.

# Step 2: Format & encrypt
log "Formatting EFI partition $EFI_PART"
if ! mkfs.fat -F32 "$EFI_PART"; then
    echo "ERROR: Failed to format EFI partition $EFI_PART" >&2
    exit 1
fi

log "Setting up LUKS on $CRYPT_PART"
log "WARNING: This will destroy all data on $CRYPT_PART"
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Operation cancelled by user"
    exit 1
fi

if ! cryptsetup luksFormat --type luks2 "$CRYPT_PART"; then
    echo "ERROR: Failed to create LUKS container" >&2
    exit 1
fi

if ! cryptsetup open "$CRYPT_PART" cryptroot; then
    echo "ERROR: Failed to open LUKS container" >&2
    exit 1
fi

# Step 3: Btrfs + subvolumes with improved error handling
log "Creating Btrfs and subvolumes"
if ! mkfs.btrfs /dev/mapper/cryptroot; then
    echo "ERROR: Failed to create Btrfs filesystem" >&2
    exit 1
fi

mount /dev/mapper/cryptroot /mnt || {
    echo "ERROR: Failed to mount Btrfs root" >&2
    exit 1
}

# Create subvolumes with error checking
subvolumes=("@" "@home" "@.snapshots" "@srv" "@var_log" "@var_pkgs")
for subvol in "${subvolumes[@]}"; do
    if ! btrfs subvolume create "/mnt/$subvol"; then
        echo "ERROR: Failed to create subvolume $subvol" >&2
        umount /mnt
        exit 1
    fi
done

umount /mnt

log "Mounting subvolumes"
# Mount root first
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt || {
    echo "ERROR: Failed to mount root subvolume" >&2
    exit 1
}

# Create mount points and mount subvolumes
mount_points=(
    "home:@home"
    ".snapshots:@.snapshots"
    "srv:@srv"
    "var/log:@var_log"
    "var/cache/pacman/pkg:@var_pkgs"
)

for mount_point in "${mount_points[@]}"; do
    dir="${mount_point%%:*}"
    subvol="${mount_point##*:}"

    mkdir -p "/mnt/$dir" || {
        echo "ERROR: Failed to create directory /mnt/$dir" >&2
        exit 1
    }

    mount -o "subvol=$subvol,compress=zstd" /dev/mapper/cryptroot "/mnt/$dir" || {
        echo "ERROR: Failed to mount subvolume $subvol at /mnt/$dir" >&2
        exit 1
    }
done

# Step 4: Mount EFI with error handling
log "Mounting EFI partition"
mkdir -p /mnt/boot || {
    echo "ERROR: Failed to create /mnt/boot directory" >&2
    exit 1
}

mount "$EFI_PART" /mnt/boot || {
    echo "ERROR: Failed to mount EFI partition" >&2
    exit 1
}

# Step 5: Bootstrap base with package array for better maintainability
log "Installing base system"
packages=(
    base
    linux
    linux-lts
    linux-firmware
    btrfs-progs
    cryptsetup
    efibootmgr
    intel-ucode
    snapper
    snap-pac
    sbsigntools
    zram-generator
    vim
    less
    git
    openssl
    iwd
)

if ! pacstrap /mnt "${packages[@]}"; then
    echo "ERROR: Failed to install base packages" >&2
    exit 1
fi

# Step 6: fstab with validation
log "Generating fstab"
if ! genfstab -U /mnt >> /mnt/etc/fstab; then
    echo "ERROR: Failed to generate fstab" >&2
    exit 1
fi

# Verify fstab was generated correctly
if [[ ! -s /mnt/etc/fstab ]]; then
    echo "ERROR: fstab is empty or not generated" >&2
    exit 1
fi

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

# Setup mkinitcpio hooks (encrypt + btrfs + fsck) - Arch Wiki standard
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
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

# User & password with enhanced error handling
if ! echo "root:$ROOT_PASS" | chpasswd; then
    echo "ERROR: Failed to set root password" >&2
    exit 1
fi

if ! useradd -m -G wheel -s /bin/bash "$USERNAME"; then
    echo "ERROR: Failed to create user $USERNAME" >&2
    exit 1
fi

if ! echo "$USERNAME:$USER_PASS" | chpasswd; then
    echo "ERROR: Failed to set user password for $USERNAME" >&2
    exit 1
fi

# Enable sudo access with backup
if ! cp /etc/sudoers /etc/sudoers.bak; then
    echo "ERROR: Failed to backup sudoers file" >&2
    exit 1
fi

if ! sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers; then
    echo "ERROR: Failed to configure sudo access" >&2
    # Restore backup
    mv /etc/sudoers.bak /etc/sudoers
    exit 1
fi

# Enable networking with error handling
services=("systemd-networkd" "systemd-resolved" "iwd")
for service in "${services[@]}"; do
    if systemctl enable "$service"; then
        echo "[INFO] Enabled $service"
    else
        echo "[WARN] Failed to enable $service (may be optional)"
    fi
done

# --- Final Validation -----------------------------------------------------
echo "[INFO] Running final installation validation..."

# Check critical components
validation_checks=0

# Verify bootloader installation
if [[ -f "/boot/EFI/systemd/systemd-bootx64.efi" ]]; then
    echo "[INFO] ✓ systemd-boot installed"
    validation_checks=$((validation_checks + 1))
else
    echo "[WARN] ✗ systemd-boot installation failed"
fi

# Verify kernel installations
if [[ -f "/boot/vmlinuz-linux" ]]; then
    echo "[INFO] ✓ Linux kernel installed"
    validation_checks=$((validation_checks + 1))
else
    echo "[WARN] ✗ Linux kernel missing"
fi

# Verify user creation
if id "$USERNAME" &>/dev/null; then
    echo "[INFO] ✓ User $USERNAME created"
    validation_checks=$((validation_checks + 1))
else
    echo "[WARN] ✗ User creation failed"
fi

# Verify sudo access
if groups "$USERNAME" 2>/dev/null | grep -q wheel; then
    echo "[INFO] ✓ Sudo access configured"
    validation_checks=$((validation_checks + 1))
else
    echo "[WARN] ✗ Sudo access failed"
fi

# Verify networking setup
if systemctl is-enabled systemd-networkd &>/dev/null; then
    echo "[INFO] ✓ Networking enabled"
    validation_checks=$((validation_checks + 1))
else
    echo "[WARN] ✗ Networking setup failed"
fi

echo "[INFO] Validation score: $validation_checks/5"

if [[ $validation_checks -ge 4 ]]; then
    echo "[SUCCESS] Pre-installation completed successfully!"
else
    echo "[WARNING] Some components may need manual verification"
fi

EOF

log "Pre-install complete. System validation score: $validation_checks/5"
log "Now switch to chroot and run post-install."
