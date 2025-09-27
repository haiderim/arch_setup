# Arch Linux Secure Boot Installation

> **⚠️ IMPORTANT**: These scripts are designed specifically for **locked machines where Secure Boot cannot be disabled** and is **forced upon you**. If you can disable Secure Boot in your firmware, use standard Arch Linux installation methods instead.

## 📚 Table of Contents

1. [🚀 Quick Start](#-quick-start)
2. [🎯 Use Case](#-use-case-locked-machines-with-forced-secure-boot)
3. [📋 Prerequisites](#-prerequisites-from-the-arch-iso)
4. [💿 Disk Preparation](#-partition-the-disk-one-liner-example)
5. [📥 Installation](#-installation)
6. [⚙️ Configuration](#-first-login-new-system-then-run-post-installsh)
7. [🔍 Verification](#-quick-verification)
8. [📖 Reference](#-reference)
9. [🛠️ Troubleshooting](#-troubleshooting-common-issues-on-locked-machines)
10. [🔧 Advanced](#-arch-linux--encrypted-btrfs-maintenance--recovery-cheat-sheet)

---

## 🚀 Quick Start

**For experienced users**: Here's the essential workflow in 5 minutes.

### 1. Prepare Environment
```bash
# Boot from Arch ISO, ensure network and time sync
timedatectl set-ntp true
ping -c 1 archlinux.org
```

### 2. Prepare Disk
```bash
# ⚠️ WARNING: Destroys all data on target disk
DISK=/dev/sda    # or /dev/nvme0n1

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"Linux LUKS" "$DISK"
partprobe "$DISK"
```

### 3. Run Installation
```bash
# Set your configuration
DISK=/dev/sda \
HOSTNAME=your-hostname \
USERNAME=your-user \
ROOT_PASS='your-root-password' \
USER_PASS='your-user-password' \
./pre-install.sh

# Reboot into new system
reboot
```

### 4. Complete Setup
```bash
# After first boot, run post-install
sudo -i
cd /path/to/Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot
USER_NAME=your-user ./post-install.sh

# Reboot and enroll MOK key when prompted
reboot
```

**Need more details?** See the comprehensive sections below.

---

Automated scripts to install **Arch Linux** with:

* **Btrfs on LUKS** (full-disk encryption, clean subvol layout)
* **systemd-boot** (fast) but chainloaded via **shim** for **Secure Boot**
* Your own **MOK (RSA-2048)**; kernels + `systemd-boot` auto-signed on updates
* **Snapper** + `snap-pac` preinstalled and **automatically configured**
* **zram-generator** preinstalled and **automatically configured**

> These scripts are designed for machines where Secure Boot is **enabled** and you **cannot** put firmware in "Setup Mode". We use **shim + MokManager** so you only enroll your **certificate once**—no more hash enrollment per kernel.
>
> **TARGET AUDIENCE**: Users with **locked corporate laptops**, **restricted firmware**, or any machine where **Secure Boot is mandatory and cannot be disabled**.

---

## What the scripts do

* **`pre-install.sh`** (run from Arch ISO):

  * Formats ESP, sets up **LUKS2** and **Btrfs** with subvolumes:

    * `@`, `@home`, `@.snapshots`, `@srv`, `@var_log`, `@var_pkgs`
  * Mounts everything, installs base system (`linux` + `linux-lts`), generates initramfs
  * Installs + seeds **systemd-boot** and **loader entries** (Arch + LTS, + fallbacks)
  * Creates **root** and **user**, enables sudo for the `wheel` group

* **`post-install.sh`** (run inside the freshly installed Arch after first boot):

  * Fixes `/boot` + random-seed permissions and tightens ESP mount options
  * Generates **MOK (RSA-2048)**, exports `MOK.cer` to the ESP
  * Builds & installs **`shim-signed` (AUR)** as your user; root installs the package
  * Signs **systemd-boot** (as `grubx64.efi` for shim) and **kernels**
  * Adds an NVRAM boot entry **"Arch (SecureBoot)"** pointing to `\EFI\arch\shimx64.efi`
  * Installs **pacman hooks** to re-sign on kernel/systemd updates
  * **Automatically configures ZRAM** compressed swap with optimal settings
  * **Automatically configures Snapper** for Btrfs snapshot management

## 🎯 Use Case: Locked Machines with Forced Secure Boot

These scripts solve the specific problem of installing Arch Linux on machines where:

* **Secure Boot is mandatory** and cannot be disabled in firmware
* **Administrative access is restricted** (no "Setup Mode" available)
* **Corporate/enterprise environments** with locked-down firmware
* **UEFI firmware that won't allow** disabling Secure Boot or adding custom keys

### ✅ When to Use These Scripts

**USE THIS APPROACH WHEN:**
- You have a **locked corporate laptop** with Secure Boot enforced
- Your machine **won't boot** unsigned EFI binaries
- You **cannot access** firmware setup to disable Secure Boot
- IT department **controls firmware settings** and won't disable Secure Boot
- You need **full-disk encryption** with Secure Boot compliance

### ❌ Use Standard Arch Install When:
- You can **disable Secure Boot** in your firmware settings
- You have **administrative access** to UEFI settings
- You're installing on **personal hardware** with flexible firmware
- You don't need **Secure Boot compliance** for your use case

### 🔧 Why This Complex Approach?

Standard Arch Linux installation doesn't work when:
1. **Firmware locks out** unsigned bootloaders
2. **No "Setup Mode"** to enroll custom keys directly
3. **Corporate policies** require Secure Boot to remain enabled
4. **Hardware restrictions** prevent disabling security features

Our solution uses **shim + MOK** to create a trusted boot chain that complies with Secure Boot requirements while giving you full control over your system.

## 📋 Prerequisites (from the Arch ISO)

### 1. Boot Environment
- **UEFI boot** the official Arch ISO
- **Network connectivity** (see options below)
- **Time synchronization** (critical for package signing)

### 2. Network Setup

**Ethernet (usually plug-and-play):**
```bash
# Test connectivity
ping -c 1 archlinux.org
```

**Wi-Fi (using iwd):**
```bash
# Start iwd interactive mode
iwctl

# Within iwctl:
device list                    # Show wireless devices
station <wlan> scan           # Scan for networks
station <wlan> get-networks   # Show available networks
station <wlan> connect "<SSID>"  # Connect to network
quit                           # Exit iwd
```

### 3. System Preparation
```bash
# Sync time (critical for package verification)
timedatectl set-ntp true

# Verify time synchronization
timedatectl status

# Test internet connectivity
ping -c 1 archlinux.org
```

**💡 Pro Tip:** If network fails, try `dhcpd` or check `ip link` for interface names.

---

## Partition the disk (one-liner example)

> ⚠️ Destroys all data on the target disk.

* For **SATA/NVMe**, adjust device names: e.g. `/dev/sda` vs `/dev/nvme0n1` (its partitions are `/dev/nvme0n1p1`, `/dev/nvme0n1p2`).

```bash
DISK=/dev/sda    # or /dev/nvme0n1

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"Linux LUKS" "$DISK"
partprobe "$DISK"
```

You’ll now have:

* **ESP** → `${DISK}1` (e.g. `/dev/sda1`, `/dev/nvme0n1p1`)
* **LUKS root** → `${DISK}2` (e.g. `/dev/sda2`, `/dev/nvme0n1p2`)

---

## Get the scripts

```bash
# From the ISO shell:
pacman -Sy --noconfirm git
git clone https://github.com/<you>/Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot.git
cd Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot
chmod +x pre-install.sh post-install.sh
```

---

## Run **pre-install.sh** (from the ISO)

Set your values and run in **one** command:

```bash
DISK=/dev/sda \
HOSTNAME=x280-arch-01 \
USERNAME=ihaider \
ROOT_PASS='your-root-password' \
USER_PASS='your-user-password' \
./pre-install.sh
```

That script will:

* LUKS-format `${DISK}2`, create/mount Btrfs subvolumes
* Format + mount `${DISK}1` at `/mnt/boot`
* `pacstrap` base + kernels + needed tools (incl. `sbsigntools`, `iwd`, `snapper`, `zram-generator`)
* Generate **loader entries** for `linux` and `linux-lts`
* Create **root** and **$USERNAME** (passwords set)

When it finishes, **reboot** into the new system:

```bash
reboot
```

(If you prefer to be explicit: `umount -R /mnt && cryptsetup close cryptroot && reboot`.)

---

## First login (new system), then run **post-install.sh**

1. Log in as your **user** and escalate, or log in directly as **root**.
2. Make sure `/boot` is mounted (it is by default).
3. Run the script **as root**. Pass your user so AUR builds run unprivileged:

```bash
sudo -i
cd /path/to/Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot
USER_NAME=ihaider ./post-install.sh
```

What to expect:

* It fixes `/boot` permissions and updates `/etc/fstab` for a strict ESP mount.
* Creates your **MOK** in `/root/secureboot/` and copies **`MOK.cer`** to `\EFI\arch\keys`.
* Builds **AUR `shim-signed`** as `ihaider`, installs it via `pacman -U`.
* Signs:

  * `\EFI\systemd\systemd-bootx64.efi` → `\EFI\arch\grubx64.efi` (what shim loads)
  * All `/boot/vmlinuz-*` kernels
* Creates/refreshes the boot entry **"Arch (SecureBoot)"**.
* Adds **pacman hooks** to keep signatures fresh on updates.
* **Automatically configures ZRAM** compressed swap (ram/2, zstd compression).
* **Automatically configures Snapper** for Btrfs snapshots with cleanup policies.

**Reboot now.** On the next boot:

* Choose **“Arch (SecureBoot)”** in your firmware menu (or it’ll be default).
* **MokManager** appears once:

  * *Enroll key from disk* → `\EFI\arch\keys\MOK.cer` → enroll → reboot.
* You’ll land in **systemd-boot** → Arch. Done.

---

## Quick verification

Inside Arch:

```bash
# Secure Boot state
mokutil --sb-state

# Boot entry exists
efibootmgr -v | grep -A1 "Arch (SecureBoot)"

# Signatures present on kernel(s)
sbverify --list /boot/vmlinuz-linux
sbverify --list /boot/vmlinuz-linux-lts
```

---

## ZRAM Configuration (Automated)

ZRAM compressed swap is **automatically configured** by `post-install.sh` with optimal settings:

- **Size**: Half of available RAM (`ram / 2`)
- **Compression**: `zstd` (best compression ratio)
- **Priority**: `100` (high priority for swap)
- **Activation**: Enabled immediately after configuration

To verify ZRAM is working:
```bash
swapon --show  # Should show /dev/zram0
zramctl        # Should show size and compression info
```
---

## Snapper Configuration (Automated)

Snapper Btrfs snapshot management is **automatically configured** by `post-install.sh`:

- **Configuration**: Root filesystem snapshot management enabled
- **Subvolume**: `@.snapshots` automatically mounted and configured
- **Cleanup**: Automatic cleanup with 5 snapshot limit
- **Access**: User added to `wheel` group for snapshot management
- **Timer**: Cleanup timer enabled for automatic maintenance

The automated setup includes:
- **Btrfs subvolume**: `@.snapshots` mounted at `/.snapshots`
- **Configuration file**: `/etc/snapper/configs/root` with optimal settings
- **User permissions**: Primary user granted snapshot management access
- **Systemd timer**: Automatic cleanup of old snapshots

To verify Snapper is working:
```bash
snapper -c root list-configs  # Should show root config
ls -la /.snapshots             # Should show snapshot directory
systemctl status snapper-cleanup.timer  # Should be active
```

---

## Environment variables (knobs)

| Var         | Where           | Default            | Meaning                               |
| ----------- | --------------- | ------------------ | ------------------------------------- |
| `DISK`      | pre-install.sh  | `/dev/sda`         | Target disk (e.g. `/dev/nvme0n1`)     |
| `HOSTNAME`  | pre-install.sh  | `archhost`         | System hostname                       |
| `USERNAME`  | pre-install.sh  | `user`             | Primary user (wheel)                  |
| `ROOT_PASS` | pre-install.sh  | `rootpass`         | Root password                         |
| `USER_PASS` | pre-install.sh  | `userpass`         | User’s password                       |
| `USER_NAME` | post-install.sh | auto-detects       | Which user builds AUR (`shim-signed`) |
| `MOK_DIR`   | post-install.sh | `/root/secureboot` | Where keys live                       |
| `ESP_MOUNT` | post-install.sh | `/boot`            | ESP mount point                       |

---

## Troubleshooting (Common Issues on Locked Machines)

* **"Secure Boot is enabled but I can't disable it"**
  This is exactly what these scripts are designed for! Proceed with the installation - our shim + MOK approach works with mandatory Secure Boot.

* **"Firmware won't boot unsigned EFI binaries"**
  The scripts handle this by signing everything with your MOK and using shim as a trusted bootloader. Follow the MokManager enrollment process after first boot.

* **"Corporate laptop with restricted firmware settings"**
  These scripts are perfect for your situation. They work around IT restrictions by creating a trusted boot chain that complies with Secure Boot policies.

* **AUR build complains about running as root**
  That's expected; the script builds as `USER_NAME` with `su - USER_NAME` and then installs as root. Make sure `USER_NAME` exists (created by pre-install) and you ran `post-install.sh` as **root**.

* **Boot lands back at firmware menu**
  Check `efibootmgr -v` for **"Arch (SecureBoot)"** entry. If missing, rerun `post-install.sh`. Also verify `\EFI\arch\shimx64.efi` and `\EFI\arch\grubx64.efi` exist on the ESP.

* **MokManager still asks to enroll hashes**
  Ensure your MOK is **RSA-2048** (these scripts generate RSA), and that both **`systemd-bootx64.efi` → `grubx64.efi`** and **kernels** are signed. Re-run `post-install.sh` if unsure.

* **`bootctl` warns about random-seed being world-readable**
  `post-install.sh` tightens perms and updates `/etc/fstab` to mount the ESP with `umask=0077`. If you edited `/boot` manually, re-run `post-install.sh`.

* **ZRAM not active after boot**
  Check `systemctl status zram-generator.service` and `swapon --show`. The automated setup should activate ZRAM immediately. If not, run `systemctl restart swap.target`.

* **Snapper configuration not found**
  Verify `snapper -c root list-configs` shows the root configuration. The automated setup mounts `@.snapshots` and creates the config. If missing, ensure Btrfs subvolumes are properly mounted.

* **Pacman hooks not firing after updates**
  Check that all hooks exist in `/etc/pacman.d/hooks/`: `85-systemd-boot-sign.hook`, `90-bootctl-update.hook`, `95-secureboot-sign.hook`. Test with `pacman -Syu --debug`.

* **Secure Boot signatures not updating**
  Verify the signing script works: `/usr/local/bin/secureboot-sign`. Check that MOK keys exist in `/root/secureboot/` and that `sbsigntools` is installed.

* **"Machine refuses to boot any unsigned binaries"**
  This is normal for locked machines. Our scripts ensure all boot components are properly signed. Make sure you complete the MokManager enrollment process on first boot.

---

## 🤖 Automation Features

The scripts include comprehensive automation for Secure Boot, system updates, and maintenance:

### Secure Boot Automation
- **MOK Generation**: Automatic RSA-2048 key creation and enrollment
- **Kernel Signing**: Automatic signing during updates via mkinitcpio hooks
- **Bootloader Signing**: Systemd-boot automatically signed via pacman hooks
- **Smart Verification**: Only re-signs if signatures are missing/invalid

### System Maintenance Automation
- **ZRAM Management**: Compressed swap automatically configured and activated
- **Snapper Integration**: Btrfs snapshots with automatic cleanup
- **Update Resilience**: All signatures automatically refreshed on package updates
- **Permission Management**: ESP and boot directory permissions automatically secured

### Pacman Hook Chain
1. **85-systemd-boot-sign.hook**: Signs systemd-boot binaries when updated
2. **90-bootctl-update.hook**: Updates bootloader after systemd upgrades
3. **95-secureboot-sign.hook**: Signs kernels and maintains EFI chain

---

## 🔍 Validation / Sanity Checks

After you finish installation (post-install, first reboot), run these commands to ensure everything is working correctly:

| Component | Check Command(s) | What to Expect / Notes |
|-----------|------------------|------------------------|
| **SecureBoot state** | `mokutil --sb-state` | Should show **SecureBoot enabled**. If disabled, shim/MOK didn't detect properly. |
| **Boot entry present** | `efibootmgr -v \| grep -A1 "Arch (SecureBoot)"` | Should show an entry pointing to `\EFI\arch\shimx64.efi`. |
| **Shim → loader handshake** | `ls -la /boot/EFI/arch/` | Should see `shimx64.efi`, `MokManager.efi`, and `grubx64.efi` (signed systemd-boot). |
| **Loader config + entries** | `ls /boot/loader/entries/` | Should see `arch.conf`, `arch-fallback.conf`, `arch-lts*.conf` etc. |
| **Kernel signatures** | `sbverify --list /boot/vmlinuz-linux` and `sbverify --list /boot/vmlinuz-linux-lts` | Both should report valid signature(s). |
| **ZRAM swap active** | `swapon --show` and `zramctl` | `/dev/zram0` should appear with size = ram/2 and zstd compression. |
| **Snapper configured** | `snapper -c root list-configs` | Should list the `root` config with proper Btrfs settings. |
| **Permissions on /boot** | `ls -ld /boot` and `ls -l /boot/loader/random-seed` | `/boot` should be `drwx------` (0700), random-seed should be `-rw-------` (0600). |
| **Automation hooks** | `ls /etc/pacman.d/hooks/` | Should see `85-systemd-boot-sign.hook`, `90-bootctl-update.hook`, `95-secureboot-sign.hook`. |
| **MOK keys present** | `ls -la /root/secureboot/` | Should see `MOK.key`, `MOK.crt`, and `MOK.cer`. |

---

# Arch Linux – encrypted Btrfs maintenance / recovery cheat-sheet

> Generic checklist for unlocking, mounting and chrooting into an Arch installation  
> that lives inside a **LUKS** container with **Btrfs sub-volumes** and a separate **ESP**.

Replace device names (`/dev/sdX*`) and sub-volume names with your own.

---

## 1. Unlock the LUKS container
```bash
cryptsetup open /dev/sdX2 cryptroot   # choose any mapper name you like
```

---

## 2. Mount the root sub-volume
```bash
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt
```

---

## 3. Create missing mount-points
```bash
mkdir -p /mnt/{boot,home,root,.snapshots,srv,var/log,var/cache/pacman/pkg}
```

---

## 4. Mount remaining Btrfs sub-volumes
```bash
mount -o subvol=@home,compress=zstd       /dev/mapper/cryptroot /mnt/home
mount -o subvol=@root,compress=zstd       /dev/mapper/cryptroot /mnt/root
mount -o subvol=@.snapshots,compress=zstd /dev/mapper/cryptroot /mnt/.snapshots
mount -o subvol=@srv,compress=zstd        /dev/mapper/cryptroot /mnt/srv
mount -o subvol=@var_log                  /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@var_pkgs                 /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
```

---

## 5. Mount the EFI System Partition
```bash
mount /dev/sdX1 /mnt/boot
```

---

## 6. Enter the chroot environment
```bash
mount -t proc /proc /mnt/proc
mount --rbind /sys  /mnt/sys  && mount --make-rslave /mnt/sys
mount --rbind /dev  /mnt/dev  && mount --make-rslave /mnt/dev
mount --rbind /run  /mnt/run  && mount --make-rslave /mnt/run

arch-chroot /mnt
```

---

## 7. Finished – perform maintenance
- `pacman -Syu` / `mkinitcpio -P` / `grub-install` / `refind-install` / fix configs, etc.

## 8. Clean exit
```bash
exit                              # leave chroot
umount -R /mnt                    # unmount everything
cryptsetup close cryptroot        # close LUKS container
reboot

---
