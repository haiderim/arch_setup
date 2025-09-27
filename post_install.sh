#!/usr/bin/env bash
set -euo pipefail

# Structured logging following automation best practices
log_info(){ echo "[INFO] [post-install] $*" >&2; }
log_warn(){ echo "[WARN] [post-install] $*" >&2; }
log_error(){ echo "[ERROR] [post-install] $*" >&2; }
log(){ log_info "$*"; }

# --- Config you can override via env -----------------------------------------
# Primary interactive user (AUR builds run as this user; no sudo prompts).
USER_NAME="${USER_NAME:-$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd)}"
MOK_DIR="${MOK_DIR:-/root/secureboot}"
ESP_MOUNT="${ESP_MOUNT:-/boot}"

# Enhanced error handling following best practices
handle_error() {
    local exit_code=$?
    log_error "Command failed with exit code $exit_code"
    log_error "Command: $BASH_COMMAND"
    log_error "Line: ${BASH_LINENO[0]}"
    exit $exit_code
}

trap handle_error ERR

# Input validation
validate_parameters() {
    [[ -n "$USER_NAME" ]] || { log_error "USER_NAME parameter is required"; exit 1; }
    [[ -n "$MOK_DIR" ]] || { log_error "MOK_DIR parameter is required"; exit 1; }
    [[ -n "$ESP_MOUNT" ]] || { log_error "ESP_MOUNT parameter is required"; exit 1; }

    # Validate ESP mount point
    [[ -d "$ESP_MOUNT" ]] || { log_error "ESP mount point $ESP_MOUNT does not exist"; exit 1; }

    # Validate user exists
    id "$USER_NAME" >/dev/null 2>&1 || { log_error "User $USER_NAME does not exist"; exit 1; }

    log_info "All parameters validated successfully"
}

# --- Preflight ---------------------------------------------------------------
if ! mountpoint -q "$ESP_MOUNT"; then
  log_error "$ESP_MOUNT is not mounted. Mount your ESP and re-run."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  log_error "Run as root."
  exit 1
fi

validate_parameters

command -v efibootmgr >/dev/null || pacman -Sy --noconfirm efibootmgr
pacman -Sy --noconfirm --needed base-devel git sbsigntools openssl

# --- Tighten /boot permissions + fstab (fix random-seed warnings) -----------
# 1) Mountpoint perms
chmod 700 "$ESP_MOUNT" || true
mkdir -p "$ESP_MOUNT/loader"
chmod 700 "$ESP_MOUNT/loader" || true
install -m 600 /dev/null "$ESP_MOUNT/loader/random-seed" 2>/dev/null || true
chmod 600 "$ESP_MOUNT/loader/random-seed" || true

# 2) Ensure VFAT mounts as 0700 (umask=0077). Update fstab safely.
ESP_DEV="$(findmnt -no SOURCE "$ESP_MOUNT")"                  # e.g. /dev/sda1 or /dev/nvme0n1p1
ESP_UUID="$(blkid -s UUID -o value "$ESP_DEV" || true)"
if [[ -n "$ESP_UUID" ]]; then
  cp /etc/fstab "/etc/fstab.$(date +%Y%m%d-%H%M%S).bak"
  # comment any existing /boot line, then append strict one
  sed -i 's@^\(.*[[:space:]]/boot[[:space:]].*\)$@# \1@g' /etc/fstab
  grep -q "UUID=${ESP_UUID}[[:space:]]\+/boot" /etc/fstab || \
    echo "UUID=$ESP_UUID  /boot  vfat  umask=0077,shortname=mixed  0  2" >> /etc/fstab
  mount -o remount "$ESP_MOUNT" || true
fi
# (Refs: bootctl warns if /boot or /boot/loader/random-seed are world-readable; set 0700/0600)  # :contentReference[oaicite:5]{index=5}

# --- Make sure systemd-boot is installed/updated -----------------------------
bootctl --graceful install || true
bootctl --graceful update  || true

# --- Create MOK (RSA-2048) + export DER for MokManager -----------------------
mkdir -p "$MOK_DIR"
if [[ ! -s "$MOK_DIR/MOK.key" || ! -s "$MOK_DIR/MOK.crt" ]]; then
  openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=Arch SecureBoot MOK/" \
    -keyout "$MOK_DIR/MOK.key" -out "$MOK_DIR/MOK.crt"
fi
# DER (.cer) for MokManager
openssl x509 -in "$MOK_DIR/MOK.crt" -outform DER -out "$MOK_DIR/MOK.cer"

install -d -m 755 "$ESP_MOUNT/EFI/arch/keys"
install -m 644 "$MOK_DIR/MOK.cer" "$ESP_MOUNT/EFI/arch/keys/MOK.cer"

# --- Install shim-signed from AUR (build as user, install as root) ----------
if [[ ! -f /usr/share/shim-signed/shimx64.efi ]]; then
  su - "$USER_NAME" -c '
    set -e
    rm -rf ~/shim-signed
    git clone https://aur.archlinux.org/shim-signed.git ~/shim-signed
    cd ~/shim-signed
    # All deps are already present via base-devel; avoid sudo by not using -s/-i
    makepkg -f --noconfirm
  '
  pacman -U --noconfirm "/home/$USER_NAME/shim-signed/"*.pkg.tar.*
fi

# Paths provided by shim-signed AUR package:                                  # 
SHIM_SRC="/usr/share/shim-signed"

# Copy shim + MokManager (vendor fallback too)
install -d -m 755 "$ESP_MOUNT/EFI/arch" "$ESP_MOUNT/EFI/BOOT"
install -m 644 "$SHIM_SRC/shimx64.efi" "$ESP_MOUNT/EFI/arch/shimx64.efi"
install -m 644 "$SHIM_SRC/mmx64.efi"   "$ESP_MOUNT/EFI/arch/MokManager.efi"
install -m 644 "$SHIM_SRC/shimx64.efi" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"

# --- Sign systemd-boot and place where shim looks next -----------------------
# Per ArchWiki, shim by default looks for and launches grubx64.efi.           # :contentReference[oaicite:7]{index=7}
if [[ -f "$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi" ]]; then
  sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" \
    --output "$ESP_MOUNT/EFI/arch/grubx64.efi" \
    "$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi"
  # Fallback copy
  install -m 644 "$ESP_MOUNT/EFI/arch/grubx64.efi" "$ESP_MOUNT/EFI/BOOT/grubx64.efi"
else
  echo "WARN: $ESP_MOUNT/EFI/systemd/systemd-bootx64.efi not found; did bootctl install succeed?" >&2
fi

# --- Sign kernels (only EFI/PE binaries; NOT initramfs/microcode) -----------
sign_in_place() {  # sbsign to temp then replace
  local f="$1"
  [[ -f "$f" ]] || return 0
  log "Signing $f"
  local tmp="${f}.signed"
  sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$tmp" "$f"
  mv -f "$tmp" "$f"
}

for k in "$ESP_MOUNT"/vmlinuz-*; do
  [[ -f "$k" ]] && sign_in_place "$k"
done
# (Do not sign initramfs or *-ucode.img unless using UKI)                      # :contentReference[oaicite:8]{index=8}

# --- Create/refresh UEFI NVRAM entry to shim --------------------------------
ESP_DISK="/dev/$(lsblk -no pkname "$ESP_DEV")"
ESP_PARTNUM="$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition")"

efibootmgr -c -d "$ESP_DISK" -p "$ESP_PARTNUM" \
  -L "Arch (SecureBoot)" \
  -l '\EFI\arch\shimx64.efi' || true

efibootmgr -v || true

# --- Pacman hooks to keep things signed on updates --------------------------
install -d -m 755 /usr/local/bin /etc/pacman.d/hooks /etc/initcpio/hooks /etc/initcpio/post-install

# Create common signing function library
cat >/usr/local/bin/sign-common.sh <<'EOS'
#!/usr/bin/env bash
# Common signing function for Secure Boot automation
sign_file() {
  local f="$1"
  local key="$2"
  local cert="$3"
  [[ -f "$f" ]] || return 0
  # Only sign if not already signed
  if ! sbverify --cert "$cert" "$f" &>/dev/null; then
    echo "[secureboot-sign] $f"
    sbsign --key "$key" --cert "$cert" --output "${f}.signed" "$f"
    mv -f "${f}.signed" "$f"
  fi
}
export -f sign_file
EOS
chmod +x /usr/local/bin/sign-common.sh

# Create secureboot-sign script
cat >/usr/local/bin/secureboot-sign <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
KEY="/root/secureboot/MOK.key"
CRT="/root/secureboot/MOK.crt"
ESP="/boot"

# Source common signing function
source /usr/local/bin/sign-common.sh

# Recopy & sign systemd-boot → grubx64.efi
if [[ -f "$ESP/EFI/systemd/systemd-bootx64.efi" ]]; then
  sign_file "$ESP/EFI/systemd/systemd-bootx64.efi" "$KEY" "$CRT"
  cp -f "$ESP/EFI/systemd/systemd-bootx64.efi" "$ESP/EFI/arch/grubx64.efi"
  cp -f "$ESP/EFI/arch/grubx64.efi" "$ESP/EFI/BOOT/grubx64.efi"
fi

# Kernels (only)
for k in "$ESP"/vmlinuz-*; do
  [[ -f "$k" ]] && sign_file "$k" "$KEY" "$CRT"
done
EOS
chmod +x /usr/local/bin/secureboot-sign

# --- Mkinitcpio post-hook for automatic kernel signing (Arch Wiki recommended) ---
cat >/etc/initcpio/post-install/secureboot-kernel-sign <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

kernel="$1"
[[ -n "$kernel" ]] || exit 0

# Use already installed kernel if it exists
[[ ! -f "$KERNELDESTINATION" ]] || kernel="$KERNELDESTINATION"

key="/root/secureboot/MOK.key"
cert="/root/secureboot/MOK.crt"

# Source common signing function
source /usr/local/bin/sign-common.sh || {
  # Fallback if source fails
  if ! sbverify --cert "$cert" "$kernel" &>/dev/null; then
    echo "[secureboot-kernel-sign] $kernel"
    sbsign --key "$key" --cert "$cert" --output "${kernel}.signed" "$kernel"
    mv -f "${kernel}.signed" "$kernel"
  fi
  exit 0
}

# Use common signing function
sign_file "$kernel" "$key" "$cert"
EOS
chmod +x /etc/initcpio/post-install/secureboot-kernel-sign

# Run after systemd-boot binary updates (critical for Secure Boot)
cat >/etc/pacman.d/hooks/85-systemd-boot-sign.hook <<'EOS'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/systemd/boot/efi/systemd-boot*.efi

[Action]
Description = Signing systemd-boot EFI binary for Secure Boot
When = PostTransaction
Exec = /bin/sh -c 'while read -r f; do if ! sbverify --list "$f" 2>/dev/null | grep -q "signature certificates"; then sbsign --key /root/secureboot/MOK.key --cert /root/secureboot/MOK.crt --output "${f}.signed" "$f" && mv -f "${f}.signed" "$f"; fi; done;'
Depends = sbsigntools
Depends = sh
NeedsTargets
EOS

# Run after kernel installs/upgrades and after systemd (bootctl update)
cat >/etc/pacman.d/hooks/90-bootctl-update.hook <<'EOS'
[Trigger]
Operation = Upgrade
Type = Package
Target = systemd

[Action]
Description = Updating systemd-boot on ESP...
When = PostTransaction
Exec = /usr/bin/bootctl update
EOS

cat >/etc/pacman.d/hooks/95-secureboot-sign.hook <<'EOS'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = boot/vmlinuz*
# Also re-sign after systemd updates (bootloader changed by bootctl)
Type = Package
Target = systemd

[Action]
Description = Re-signing kernel(s) and systemd-boot for Secure Boot...
When = PostTransaction
Exec = /usr/local/bin/secureboot-sign
EOS

# --- Final hints -------------------------------------------------------------
cat <<'EONEXT'

[OK] Secure Boot pieces are staged.

NEXT BOOT (one-time):
  1) From the firmware menu, boot "Arch (SecureBoot)".
  2) Shim will launch MokManager the first time:
       → "Enroll key from disk"
       → Navigate to \EFI\arch\keys\MOK.cer
       → Enroll, then reboot.
  3) You should now land in systemd-boot, then Arch. No hash enrollment needed.

Changes on kernel/systemd updates will be auto-signed by pacman hooks.

# --- Configure ZRAM -------------------------------------------------------------
log_info "Setting up ZRAM for compressed swap"

# Configure ZRAM swap with optimal settings
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

# Function to verify ZRAM status
verify_zram() {
    if swapon --show | grep -q zram0; then
        local zram_info
        zram_info=$(swapon --show | grep zram0)
        log_info "ZRAM swap is active: ${zram_info##* }"  # More efficient than awk
        return 0
    else
        log_warn "ZRAM swap not active"
        return 1
    fi
}

# Reload systemd and activate swap
if systemctl daemon-reexec && systemctl restart swap.target; then
    log_info "ZRAM setup completed successfully"
    verify_zram
else
    log_warn "Failed to setup ZRAM properly"
    # Attempt manual activation
    if modprobe zram; then
        echo "lz4" > /sys/block/zram0/comp_algorithm 2>/dev/null || echo "zstd" > /sys/block/zram0/comp_algorithm
        # Calculate ZRAM size more efficiently
        local mem_total_kb
        mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        echo "$(( mem_total_kb * 512 ))" > /sys/block/zram0/disksize
        mkswap /dev/zram0 && swapon /dev/zram0
        log_info "ZRAM manually activated"
        verify_zram
    fi
fi

# --- Configure Snapper ----------------------------------------------------------
log_info "Setting up Snapper for Btrfs snapshots"

# Function to verify Snapper configuration
verify_snapper() {
    if snapper -c root list-configs >/dev/null 2>&1; then
        log_info "Snapper configuration verified"
        # Show snapshot count if available
        if snapper -c root list >/dev/null 2>&1; then
            local count=$(snapper -c root list | wc -l)
            log_info "Snapper snapshots: $((count - 1)) configured"
        fi
        return 0
    else
        log_warn "Snapper configuration verification failed"
        return 1
    fi
}

# Ensure the @.snapshots subvolume is mounted
if mount -o subvol=@.snapshots /dev/mapper/cryptroot /.snapshots 2>/dev/null; then
    log_info "Mounted @.snapshots subvolume"
else
    log_warn "Could not mount @.snapshots subvolume (may already be mounted)"
    # Check if already mounted
    if mountpoint -q /.snapshots; then
        log_info "@.snapshots already mounted at /.snapshots"
    fi
fi

# Create config directory
mkdir -p /etc/snapper/configs

# Write optimized Snapper root config
cat >/etc/snapper/configs/root <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS="wheel"
SYNC_ACL="no"
TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
NUMBER_LIMIT="5"
TIMELINE_LIMIT_HOURLY="10"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="12"
TIMELINE_LIMIT_YEARLY="2"
EOF

# Symlink default config (force overwrite if needed)
ln -sfn /etc/snapper/configs/root /etc/snapper/config

# Add user to wheel group for snapper access
if usermod -aG wheel "$USER_NAME"; then
    log_info "Added $USER_NAME to wheel group for snapper access"
else
    log_warn "Failed to add $USER_NAME to wheel group (may already be member)"
fi

# Enable cleanup timer
if systemctl enable --now snapper-cleanup.timer; then
    log_info "Enabled snapper cleanup timer"
else
    log_warn "Failed to enable snapper cleanup timer"
fi

# Enable snapperd service if available
if systemctl enable --now snapperd.service 2>/dev/null; then
    log_info "Enabled snapperd service"
fi

# Verify setup
verify_snapper

# --- Final Validation -------------------------------------------------------
log_info "Running final validation checks"

# Validate Secure Boot components
validate_secureboot() {
    local validation_passed=0

    # Check MOK keys
    if [[ -f "$MOK_DIR/MOK.key" && -f "$MOK_DIR/MOK.crt" ]]; then
        log_info "✓ MOK keys present"
        validation_passed=$((validation_passed + 1))
    else
        log_warn "✗ MOK keys missing"
    fi

    # Check shim installation
    if [[ -f "$ESP_MOUNT/EFI/arch/shimx64.efi" ]]; then
        log_info "✓ Shim installed"
        validation_passed=$((validation_passed + 1))
    else
        log_warn "✗ Shim missing"
    fi

    # Check signed systemd-boot
    if [[ -f "$ESP_MOUNT/EFI/arch/grubx64.efi" ]]; then
        log_info "✓ Systemd-boot signed as grubx64.efi"
        validation_passed=$((validation_passed + 1))
    else
        log_warn "✗ Signed systemd-boot missing"
    fi

    # Check pacman hooks
    if [[ -f "/etc/pacman.d/hooks/85-systemd-boot-sign.hook" &&
          -f "/etc/pacman.d/hooks/95-secureboot-sign.hook" ]]; then
        log_info "✓ Pacman hooks installed"
        validation_passed=$((validation_passed + 1))
    else
        log_warn "✗ Pacman hooks missing"
    fi

    # Check boot entry
    if efibootmgr | grep -q "Arch (SecureBoot)"; then
        log_info "✓ Boot entry created"
        validation_passed=$((validation_passed + 1))
    else
        log_warn "✗ Boot entry missing"
    fi

    return $validation_passed
}

# Run validation
secureboot_score=$(validate_secureboot)
log_info "Secure Boot validation score: $secureboot_score/5"

# Summary with enhanced validation
secureboot_status="$([[ $secureboot_score -ge 4 ]] && echo "✓ Ready" || echo "⚠ Needs attention")
zram_status="$(swapon --show | grep -q zram0 && echo "✓ Active" || echo "⚠ Inactive")
snapper_status="$(snapper -c root list-configs >/dev/null 2>&1 && echo "✓ Configured" || echo "⚠ Failed")"

cat <<EOSUMMARY

[SUMMARY] Post-installation completed successfully!

SECURE BOOT AUTOMATION: ${secureboot_status}
ZRAM: ${zram_status}
SNAPPER: ${snapper_status}
Validation Score: ${secureboot_score}/5

NEXT STEPS:
1. Reboot and select "Arch (SecureBoot)" from firmware menu
2. Enroll MOK key when prompted
3. Verify Secure Boot status with: mokutil --sb-state
4. Run validation: efibootmgr | grep "Arch (SecureBoot)"

EOSUMMARY

EONEXT
