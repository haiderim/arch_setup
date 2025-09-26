#!/bin/bash
set -euo pipefail

log() { echo "[post-install] $*"; }

# --- dependencies ---
if ! command -v sbsign >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed sbsigntools
fi
if ! command -v efibootmgr >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed efibootmgr
fi

# --- secureboot signing tool ---
install -Dm0755 /dev/stdin /usr/local/bin/secureboot-sign <<'EOF'
#!/bin/bash
set -euo pipefail
KEY="/root/secureboot/MOK.key"
CERT="/root/secureboot/MOK.crt"
BOOT="/boot"
SBSIGN="/usr/bin/sbsign"

sign_inplace() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local tmp="${f}.signed"
  echo "[sign] $f"
  "$SBSIGN" --key "$KEY" --cert "$CERT" --output "$tmp" "$f"
  mv -f "$f" "${f}.unsigned" 2>/dev/null || true
  mv -f "$tmp" "$f"
}

# sign systemd-boot, install alongside shim
if [[ -f "$BOOT/EFI/systemd/systemd-bootx64.efi" ]]; then
  sign_inplace "$BOOT/EFI/systemd/systemd-bootx64.efi"
  install -Dm0644 "$BOOT/EFI/systemd/systemd-bootx64.efi" "$BOOT/EFI/arch/grubx64.efi"
  mkdir -p "$BOOT/EFI/BOOT"
  cp -f "$BOOT/EFI/arch/shimx64.efi" "$BOOT/EFI/BOOT/BOOTX64.EFI" || true
  cp -f "$BOOT/EFI/arch/grubx64.efi" "$BOOT/EFI/BOOT/grubx64.efi" || true
fi

# sign kernels, initramfs, microcode
for f in "$BOOT"/vmlinuz-* "$BOOT"/initramfs-*.img "$BOOT"/*-ucode.img; do
  [[ -f "$f" ]] && sign_inplace "$f"
done

# copy cert to ESP for MokManager enrollment
mkdir -p "$BOOT/EFI/arch/keys"
cp -f "$CERT" "$BOOT/EFI/arch/keys/MOK.crt" || true
EOF

# --- pacman hook ---
install -Dm0644 /dev/stdin /etc/pacman.d/hooks/95-secureboot-sign.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = boot/vmlinuz*
Target = boot/initramfs-*.img
Target = boot/*-ucode.img
Target = EFI/systemd/systemd-bootx64.efi

[Action]
Description = Re-sign kernels/initramfs/microcode and systemd-boot for Secure Boot (MOK)
When = PostTransaction
Exec = /usr/local/bin/secureboot-sign
EOF

# --- fix fstab ESP perms ---
ESP_UUID=$(blkid -s UUID -o value "$(findmnt -no SOURCE /boot)")
grep -q "$ESP_UUID" /etc/fstab && \
  sed -i "s|$ESP_UUID.*vfat.*|$ESP_UUID  /boot  vfat  umask=0077,shortname=mixed,utf8,errors=remount-ro  0  2|" /etc/fstab

# --- ensure boot entry exists ---
ESP_SRC="$(findmnt -no SOURCE /boot)"
ROOT_DISK="$(lsblk -no pkname "$ESP_SRC")"
ESP_PART_NUM="$(sed -E 's/.*[^0-9]([0-9]+)$/\1/' <<<"$ESP_SRC")"

efibootmgr -c -d "/dev/$ROOT_DISK" -p "$ESP_PART_NUM" \
  -L "Arch (SecureBoot)" \
  -l '\EFI\arch\shimx64.efi' || true

efibootmgr -v || true

log "Post-install completed."
