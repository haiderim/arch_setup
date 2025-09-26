# Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot

A collection of automated scripts and step-by-step documentation that turns a blank UEFI machine into a hardened **Arch Linux** system with:

* **Full-disk encryption (LUKS2)** with **BTRFS** subvolumes
* **systemd-boot** as the bootloader (fast, simple, no GRUB)
* **Secure Boot** enabled using your own keys (signed bootloader & kernel, no Microsoft keys)
* **Snapper** snapshots automatically triggered by `pacman`, `yay`, and `paru`
* **ZRAM** swap (no swap partition/file required)
* Post-install fixes for Secure Boot, `random-seed` permissions, and loader entries

---

## Features

* 🔒 **Secure by default**: Encrypted root, signed boot chain, SBAT-compliant shim.
* 📦 **Automated snapshotting**: Snapper runs pre/post `pacman` and AUR transactions.
* ⚡ **Optimized memory usage**: ZRAM provides compressed in-RAM swap without disk overhead.
* 🖥️ **Fast boot**: systemd-boot replaces GRUB, keeping configs simple and boot times low.
* 📜 **Step-by-step scripts**: Includes `pre-install.sh` and `post-install.sh` to automate tedious setup.

---

## What’s Included

* `pre-install.sh` – Prepares partitions, sets up LUKS, formats BTRFS with subvolumes, mounts correctly.
* `post-install.sh` – Installs base system, configures mkinitcpio hooks, Secure Boot keys, shim/systemd-boot, Snapper, ZRAM, and fixes random-seed permissions.
* Example **loader entries** for Arch (regular, LTS, and fallbacks).
* Instructions for managing Secure Boot keys with `sbsigntools` + `efibootmgr`.

---

## Requirements

* UEFI firmware with Secure Boot support (CSM disabled).
* Internet access during installation.
* Willingness to use your **own Secure Boot keys** (Microsoft’s keys are not used).

---

## Usage

1. Boot Arch ISO in UEFI mode.
2. Clone this repo into RAM or USB.
3. Run `pre-install.sh` to set up encrypted BTRFS.
4. `arch-chroot` into `/mnt` and run `post-install.sh`.
5. Reboot into your new Arch system (Secure Boot enabled).

---

## Notes

* This setup **does not use GRUB** at all — only systemd-boot via shim.
* The shim package (`shim-signed`) comes from AUR and is handled inside the scripts.
* Secure Boot signing is fully automated — kernel and initramfs are signed at install/update.
* Snapper integration ensures rollback safety after any system update.

---

✅ This way, anyone reading knows:

* It’s using **shim + systemd-boot**, not GRUB.
* `shim-signed` is **AUR**, not Arch repo.
* Both **pre-** and **post-install** scripts are included.
* Secure Boot, Snapper, ZRAM are all automated.
