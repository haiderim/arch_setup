# Arch Linux Secure Boot Installation

> **⚠️ CRITICAL:**  
> You **MUST** run `post_install.sh` **BEFORE** rebooting! The system will **NOT BOOT** with Secure Boot enabled without the shim and MOK setup that `post_install.sh` provides.  
>  
> **💡 Always review scripts before execution**, whether you clone or download them.

---

## 📚 Table of Contents

1. [🚀 Quick Start](#quick-start)
2. [🎯 Use Case](#use-case-locked-machines-with-forced-secure-boot)
3. [📋 Prerequisites](#prerequisites)
4. [💿 Disk Preparation](#partition-the-disk)
5. [📥 Installation](#installation)
6. [⚙️ Configuration](#configuration-run-post_installsh-in-chroot)
7. [🔍 Verification](#verification)
8. [📖 Reference](#reference-environment-variables)
9. [🛠️ Troubleshooting](#troubleshooting)
10. [🔧 Advanced](#advanced-maintenance-recovery)
11. [❓ FAQ](#faq)

---

## 🚀 Quick Start

For experienced users: install Arch with full-disk encryption and Secure Boot in 5 minutes.

### 1. Prepare Environment
```bash
# Boot from Arch ISO, ensure network and time sync
timedatectl set-ntp true
ping -c 1 archlinux.org
```

### 2. Prepare Disk
```bash
# WARNING: Destroys all data on target disk
DISK=/dev/sda    # or /dev/nvme0n1

# NOTE: For NVMe devices, your partitions are /dev/nvme0n1p1 and /dev/nvme0n1p2
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"Linux LUKS" "$DISK"
partprobe "$DISK"
```

### 3. Run Installation
```bash
DISK=/dev/sda \
HOSTNAME=your-hostname \
USERNAME=your-user \
ROOT_PASS='your-root-password' \
USER_PASS='your-user-password' \
./pre_install.sh
```
- **Password requirements:** Minimum 8 characters, must include uppercase, lowercase, and numbers.  
- If not set as environment variables, you will be prompted interactively.

### 4. Complete Setup (Secure Boot Configuration)
```bash
# Copy scripts into chroot and run post-install
cp -r /path/to/arch_setup /mnt/root/
arch-chroot /mnt
cd /root/arch_setup
USER_NAME=your-user ./post_install.sh
# After post-install completes, exit and reboot
exit
umount -R /mnt
cryptsetup close cryptroot
reboot
```
**Do not reboot before running post_install.sh in chroot!**

---

## 🎯 Use Case: Locked Machines with Forced Secure Boot

Use these scripts if:
- Secure Boot **cannot** be disabled in firmware (corporate, enterprise, or restricted firmware).
- Your firmware **won't boot unsigned EFI binaries**.
- You want **full-disk encryption** and Secure Boot compliance.

Don't use if:
- You can disable Secure Boot in firmware.
- You have admin access to UEFI settings.
- You're installing on personal hardware with flexible firmware.

---

## 📋 Prerequisites

**Tools Required:**
- `git`, `wget`, `base-devel`, `iwd` (for Wi-Fi), `snapper`, `zram-generator`, `sbsigntools`, `sgdisk`, `efibootmgr`
- Arch ISO booted in UEFI mode

**Network Setup:**
- Ethernet: usually plug-and-play. Test with `ping`.
- Wi-Fi (using iwd):
    ```bash
    iwctl
    # then: device list; station <wlan> scan; station <wlan> connect "<SSID>"; quit
    ```

**Time Sync:**  
```bash
timedatectl set-ntp true
timedatectl status
```

---

## 💿 Partition the Disk

> **SATA:** `/dev/sda1`, `/dev/sda2`  
> **NVMe:** `/dev/nvme0n1p1`, `/dev/nvme0n1p2`  
> **Set `DISK` accordingly!**

```bash
DISK=/dev/sda    # or /dev/nvme0n1
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"Linux LUKS" "$DISK"
partprobe "$DISK"
# You now have:
# - ESP: ${DISK}1 (e.g. /dev/sda1 or /dev/nvme0n1p1)
# - LUKS root: ${DISK}2 (e.g. /dev/sda2 or /dev/nvme0n1p2)
```

---

## 📥 Installation

### Option 1: Clone Repository (Recommended)
```bash
pacman -Sy --noconfirm git
git clone https://github.com/haiderim/arch_setup.git
cd arch_setup
chmod +x pre_install.sh post_install.sh
```
**Review scripts before running them!**

### Option 2: Download Scripts Directly
```bash
wget https://raw.githubusercontent.com/haiderim/arch_setup/main/pre_install.sh
wget https://raw.githubusercontent.com/haiderim/arch_setup/main/post_install.sh
chmod +x pre_install.sh post_install.sh
```
**Review scripts before running them!**

---

## Run **pre_install.sh** (from ISO)

```bash
DISK=/dev/sda \
HOSTNAME=your-host \
USERNAME=your-user \
ROOT_PASS='your-root-password' \
USER_PASS='your-user-password' \
./pre_install.sh
```
- LUKS-format root, create/mount Btrfs subvolumes
- Format + mount ESP
- `pacstrap` base + kernels + tools
- Generate loader entries for `linux` and `linux-lts`
- Create root and user, set passwords

**When finished, DO NOT reboot. Run post-install in chroot.**

---

## ⚙️ Configuration: Run post_install.sh (in chroot)

**You must run `post_install.sh` before reboot!**

### Option 1: Continue from Current Chroot
```bash
cp -r /path/to/arch_setup /mnt/root/
cd /mnt/root/arch_setup
USER_NAME=your-user ./post_install.sh
```

### Option 2: Re-enter Chroot
```bash
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt
mount /dev/sda1 /mnt/boot  # or /dev/nvme0n1p1
arch-chroot /mnt
cd /root/arch_setup
USER_NAME=your-user ./post_install.sh
```

**What to expect:**  
- Fixes `/boot` permissions, updates `/etc/fstab` for strict ESP mount.
- Creates MOK (`/root/secureboot/`) and copies `MOK.cer` to `\EFI\arch\keys`.
- Builds AUR `shim-signed` as your user, installs via `pacman -U`.
- Signs `systemd-bootx64.efi` → `grubx64.efi` and all `/boot/vmlinuz-*` kernels.
- Creates/refreshes boot entry **"Arch (SecureBoot)"**.
- Adds pacman hooks for signature refresh.
- Configures ZRAM and Snapper automatically.

---

## 🔍 Verification

After first boot, check:

**Secure Boot Status**
```bash
mokutil --sb-state    # Should show SecureBoot enabled
efibootmgr -v | grep -A1 "Arch (SecureBoot)"  # Entry pointing to \EFI\arch\shimx64.efi
```

**EFI Files**
```bash
ls -la /boot/EFI/arch/  # Should show shimx64.efi, MokManager.efi, grubx64.efi
```

**Kernel Signatures**
```bash
sbverify --list /boot/vmlinuz-linux
sbverify --list /boot/vmlinuz-linux-lts
# Should report valid signature(s)
```

**ZRAM & Snapper**
```bash
swapon --show
zramctl
snapper -c root list-configs
ls -la /.snapshots
```

**Permissions**
```bash
ls -ld /boot    # Should be drwx------ (0700)
ls -l /boot/loader/random-seed    # Should be -rw------- (0600)
```

**Pacman Hooks**
```bash
ls /etc/pacman.d/hooks/
# Should see: 85-systemd-boot-sign.hook, 90-bootctl-update.hook, 95-secureboot-sign.hook
```

**MOK Keys**
```bash
ls -la /root/secureboot/
# Should see: MOK.key, MOK.crt, MOK.cer
```

---

## 📖 Reference: Environment Variables

| Variable      | Default         | Purpose                 | Valid Values              | Notes                                         |
|---------------|----------------|-------------------------|---------------------------|-----------------------------------------------|
| `DISK`        | `/dev/sda`     | Target disk             | `/dev/sd*`, `/dev/nvme*`  | For NVMe use `/dev/nvme0n1`                   |
| `HOSTNAME`    | `archhost`     | System hostname         | Valid hostname            | FQDN or short name                            |
| `USERNAME`    | `user`         | Primary user            | Valid username            | Added to wheel group                          |
| `ROOT_PASS`   | `rootpass`     | Root password           | Min 8 chars, mixed case   | Uppercase, lowercase, numbers required        |
| `USER_PASS`   | `userpass`     | User password           | Min 8 chars, mixed case   | Uppercase, lowercase, numbers required        |
| `USER_NAME`   | auto-detect    | AUR build user          | Existing username         | Defaults to first UID≥1000 non-nobody user    |
| `MOK_DIR`     | `/root/secureboot` | Key storage location | Directory path            | RSA-2048 keys stored here                     |
| `ESP_MOUNT`   | `/boot`        | EFI mount point         | Directory path            | Must be mountable                             |

**Note:**  
- `USER_NAME` is usually the same as `USERNAME` unless you have a special config (multiple users).
- If multiple users exist, script will use the first non-nobody, UID≥1000 user it finds.

---

## 🛠️ Troubleshooting

**Disk device ambiguity:**  
- If using NVMe, always use `/dev/nvme0n1p1` and `/dev/nvme0n1p2` for partitions.

**Pacman hook not firing:**  
- Check existence of `85-systemd-boot-sign.hook`, `90-bootctl-update.hook`, `95-secureboot-sign.hook`.  
- Test with `pacman -Syu --debug`.

**Custom Btrfs layouts:**  
- If you set up different subvolumes, update mount instructions and Snapper config accordingly.

**MokManager enrollment:**  
- On first boot, MokManager will appear.  
- Navigate to `\EFI\arch\keys\MOK.cer` and select “Enroll”—follow on-screen instructions.

**Permissions:**  
- The script sets strict permissions on `/boot` and random-seed.  
- If using a multi-user system, changing these may reduce security.

**Other common issues:**  
- See [FAQ](#faq) below for more troubleshooting.

---

## 🔧 Advanced Maintenance & Recovery

**Unlock, mount, and chroot into an encrypted Arch install:**
```bash
cryptsetup open /dev/sdX2 cryptroot
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt
mount /dev/sdX1 /mnt/boot  # Adjust for your disk type
# Create additional mount points as needed
arch-chroot /mnt
# ...maintenance commands...
exit
umount -R /mnt
cryptsetup close cryptroot
```
**Subvolume names:**  
- By default, these scripts create `@`, `@home`, `@.snapshots`, `@srv`, `@var_log`, `@var_pkgs`.  
- If you changed names, adjust mount commands.

---

## ❓ FAQ

**Q: What if I reboot before running post_install.sh?**  
A: System won’t boot with Secure Boot enabled. Re-enter chroot and run post_install.sh.

**Q: Do I need to manually sign kernels after every update?**  
A: No, pacman hooks automate kernel and bootloader signing.

**Q: How do I enroll the MOK key?**  
A: On first boot, MokManager appears. Navigate to the key, enroll, and reboot.

**Q: What if I use a custom Btrfs layout or disable ZRAM?**  
A: Update mount instructions and Snapper config. ZRAM setup is auto, but you can disable or modify as needed.

**Q: How do I recover or reset the bootloader?**  
A: Use the Advanced Maintenance section above.

**Q: Can I use these scripts for other distros?**  
A: Only tested for Arch Linux. Adapt at your own risk.

---

**If you encounter issues not covered here, please open a GitHub issue or discussion.**
