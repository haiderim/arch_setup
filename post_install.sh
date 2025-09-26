#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[post-install] $*"; }

# --- Config you can override via env -----------------------------------------
# Primary interactive user (AUR builds run as this user; no sudo prompts).
USER_NAME="${USER_NAME:-$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd)}"
MOK_DIR="${MOK_DIR:-/root/secureboot}"
ESP_MOUNT="${ESP_MOUNT:-/boot}"

# --- Preflight ---------------------------------------------------------------
if ! mountpoint -q "$ESP_MOUNT"; then
  echo "ERROR: $ESP_MOUNT is not mounted. Mount your ESP and re-run." >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2
  exit 1
fi

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
  grep -q "UUID=$ESP_UUID[[:space:]]\+/boot" /etc/fstab || \
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
install -d -m 755 /usr/local/bin /etc/pacman.d/hooks

cat >/usr/local/bin/secureboot-sign <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
KEY="/root/secureboot/MOK.key"
CRT="/root/secureboot/MOK.crt"
ESP="/boot"

sign_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  echo "[secureboot-sign] $f"
  sbsign --key "$KEY" --cert "$CRT" --output "${f}.signed" "$f"
  mv -f "${f}.signed" "$f"
}

# Recopy & sign systemd-boot → grubx64.efi
if [[ -f "$ESP/EFI/systemd/systemd-bootx64.efi" ]]; then
  sign_file "$ESP/EFI/systemd/systemd-bootx64.efi"
  cp -f "$ESP/EFI/systemd/systemd-bootx64.efi" "$ESP/EFI/arch/grubx64.efi"
  cp -f "$ESP/EFI/arch/grubx64.efi" "$ESP/EFI/BOOT/grubx64.efi"
fi

# Kernels (only)
for k in "$ESP"/vmlinuz-*; do
  [[ -f "$k" ]] && sign_file "$k"
done
EOS
chmod +x /usr/local/bin/secureboot-sign

# Run after kernel installs/upgrades and after systemd (bootctl update)        # :contentReference[oaicite:9]{index=9}
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

EONEXT
