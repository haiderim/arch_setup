# Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot

Automated scripts to install **Arch Linux** with:

* **Btrfs on LUKS** (full-disk encryption, clean subvol layout)
* **systemd-boot** (fast) but chainloaded via **shim** for **Secure Boot**
* Your own **MOK (RSA-2048)**; kernels + `systemd-boot` auto-signed on updates
* **Snapper** + `snap-pac` preinstalled (ready for config)
* **zram-generator** preinstalled (ready for config)

> These scripts are designed for machines where Secure Boot is **enabled** and you **cannot** put firmware in “Setup Mode”. We use **shim + MokManager** so you only enroll your **certificate once**—no more hash enrollment per kernel.

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
  * Adds an NVRAM boot entry **“Arch (SecureBoot)”** pointing to `\EFI\arch\shimx64.efi`
  * Installs **pacman hooks** to re-sign on kernel/systemd updates

---

## Prerequisites (from the Arch ISO)

1. **UEFI boot** the official Arch ISO.
2. **Networking** (pick one):

   * Ethernet: usually plug-and-play.
   * Wi-Fi (iwd):

     ```bash
     iwctl
     # within iwctl:
     device list
     station <wlan> scan
     station <wlan> get-networks
     station <wlan> connect "<SSID>"
     quit
     ```
3. **Time sync**:

   ```bash
   timedatectl set-ntp true
   ```

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
* Creates/refreshes the boot entry **“Arch (SecureBoot)”**.
* Adds **pacman hooks** to keep signatures fresh on updates.

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

## Optional: enable ZRAM now

`zram-generator` is installed; add a minimal config:

```bash
# Configure ZRAM swap with zram-generator
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

# Reload systemd and activate swap
systemctl daemon-reexec
systemctl restart swap.target

# Verify
swapon --show
zramctl
```
---

## Optional: initialize Snapper now

`snapper` and `snap-pac` are installed; create a root config:

```bash

# Ensure the @.snapshots subvolume is mounted
mount -o subvol=@.snapshots /dev/mapper/cryptroot /.snapshots || true

# Create config directory
mkdir -p /etc/snapper/configs

# Write Snapper root config
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
EOF

# Symlink default config (force overwrite if needed)
ln -sfn /etc/snapper/configs/root /etc/snapper/config

# Add user to wheel group for snapper access
usermod -aG wheel "$USERNAME" || true

# Enable cleanup timer
systemctl enable --now snapper-cleanup.timer

# Verify setup
snapper -c root list-configs || true
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

## Troubleshooting (common)

* **AUR build complains about running as root**
  That’s expected; the script builds as `USER_NAME` with `su - USER_NAME` and then installs as root. Make sure `USER_NAME` exists (created by pre-install) and you ran `post-install.sh` as **root**.

* **Boot lands back at firmware menu**
  Check `efibootmgr -v` for **“Arch (SecureBoot)”** entry. If missing, rerun `post-install.sh`. Also verify `\EFI\arch\shimx64.efi` and `\EFI\arch\grubx64.efi` exist on the ESP.

* **MokManager still asks to enroll hashes**
  Ensure your MOK is **RSA-2048** (these scripts generate RSA), and that both **`systemd-bootx64.efi` → `grubx64.efi`** and **kernels** are signed. Re-run `post-install.sh` if unsure.

* **`bootctl` warns about random-seed being world-readable**
  `post-install.sh` tightens perms and updates `/etc/fstab` to mount the ESP with `umask=0077`. If you edited `/boot` manually, re-run `post-install.sh`.

---

Yes — absolutely. Having a “Validation / Sanity Checks” section in the README is very helpful, especially for Secure Boot setups which are prone to subtle errors. I'll add a section with commands (and reasoning) that users can run to verify each major component is working as intended. I'll base them on Arch docs & trusted community guides.

---

## 🔍 Validation / Sanity Checks

After you finish installation (post-install, first reboot), run these commands to ensure everything is working correctly:

| Component                                | Check Command(s)                                          | What to Expect / Notes                                                                                                                       |                                                                                 |
| ---------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| **SecureBoot state**                     | `mokutil --sb-state`                                      | Should show **SecureBoot enabled**. If it says disabled, shim/MOK didn’t detect properly.                                                    |                                                                                 |
| **Boot entry present**                   | `efibootmgr -v`                                            | grep -A1 "Arch (SecureBoot)"`                                                                                                                | Should show an entry pointing to `\EFI\arch\shimx64.efi`.                       |
| **Shim → loader handshake**              | Inspect ESP                                               | Under `EFI/arch` you should see `shimx64.efi`, `MokManager.efi`. Under `EFI/arch/grubx64.efi` should be signed stub linking to systemd-boot. |                                                                                 |
| **Loader config + entries**              | `ls /boot/loader/entries`                                 | You should see `arch.conf`, `arch-fallback.conf`, `arch-lts*.conf` etc.                                                                      |                                                                                 |
| **Kernel signatures**                    | `sbverify --list /boot/vmlinuz-linux` and for LTS         | It should report valid signature(s).                                                                                                         |                                                                                 |
| **swap via ZRAM**                        | `swapon --show` and `zramctl`                             | `/dev/zram0` should appear with expected size and compression.                                                                               |                                                                                 |
| **Snapper config**                       | `snapper -c root list-configs` and `snapper -c root list` | Should list the `root` config and snapshots (if any).                                                                                        |                                                                                 |
| **Permissions on /boot and random-seed** | `ls -ld /boot` and `ls -l /boot/loader/random-seed`       | `/boot` should be `drwx------` (0700) or similar, and the random-seed file `-rw-------` (0600).                                              |                                                                                 |
| **EFI variable permissions**             | `ls /sys/firmware/efi/efivars`                             | grep SetupMode                                                                                                                              | You should see `SetupMode-…` and possibly `SecureBoot-…` among other variables. |
| **Pacman hook trigger**                  | Install a test kernel or simulate update                  | After the update, check `/usr/local/bin/secureboot-sign` or your pacman hooks ran, sign outputs appear.                                      |                                                                                 |

---

## License

MIT (see `LICENSE`).
