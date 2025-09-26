# Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot

This repository contains **automated scripts and documentation** to set up a modern, reproducible Arch Linux system from scratch, with full-disk encryption, BTRFS subvolumes, snapshotting, ZRAM, and Secure Boot — all in one go.

## Features

* **BTRFS on LUKS**

  * Full-disk encryption (LUKS2).
  * Clean subvolume layout: `@`, `@home`, `@.snapshots`, `@srv`, `@var_log`, `@var_pkgs`.
  * Transparent compression (`zstd`).

* **Snapper integration**

  * Automatic snapshots triggered by `pacman`, `yay`, and `paru`.
  * `@.snapshots` subvolume pre-configured for rollback.

* **ZRAM swap**

  * Managed by `zram-generator`.
  * No need for a swap partition or file.

* **Secure Boot from day one**

  * Your **own custom Machine Owner Keys (MOKs)**, not Microsoft’s.
  * Uses [shim](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Shim) + [systemd-boot](https://wiki.archlinux.org/title/Systemd-boot).
  * Automatically signs `systemd-boot` and kernels via pacman hooks.
  * MokManager used once to enroll your key (`MOK.cer`).

* **systemd-boot**

  * Lightweight bootloader.
  * Fallback entries and loader configs pre-generated.
  * No GRUB required.

## Scripts

* `pre-install.sh`
  Run from the **live Arch ISO** after partitioning. Handles:

  * Formatting ESP and LUKS setup.
  * BTRFS + subvolume creation.
  * Mounting subvolumes + ESP.
  * Bootstrapping Arch (`pacstrap`).
  * Generating fstab, locale, users, sudoers.
  * Installing and configuring systemd-boot with multiple entries (main + fallback, LTS + fallback).

* `post-install.sh`
  Run **inside the freshly installed system after first boot**. Handles:

  * Fixing `/boot` and `/boot/loader/random-seed` permissions.
  * Generating + enrolling your Secure Boot keys (RSA 2048 MOK).
  * Installing `shim-signed` from AUR.
  * Signing `systemd-boot` (renamed to `grubx64.efi` for shim) and kernels.
  * Creating pacman hooks to auto-re-sign on kernel/systemd updates.
  * Setting up EFI boot entries with `efibootmgr`.

## Workflow

1. **Boot Arch ISO** and partition your disk (ESP + LUKS root).
2. Run `pre-install.sh` → this installs Arch with BTRFS + systemd-boot.
3. Reboot into your new Arch install.
4. Run `post-install.sh` → this enables Secure Boot and auto-signing.
5. Reboot again → enroll your key (`MOK.cer`) with MokManager once.

From now on, kernel/systemd updates are signed automatically — no manual intervention needed.

## Requirements

* UEFI firmware with Secure Boot enabled.
* ESP (FAT32) + encrypted root partition.
* Internet access during installation.
* Firmware **not in “Setup Mode”** (works fine with MokManager method).

## References

* [Arch Wiki: Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
* [Arch Wiki: systemd-boot](https://wiki.archlinux.org/title/Systemd-boot)
* [Arch Wiki: Snapper](https://wiki.archlinux.org/title/Snapper)
* [Arch Wiki: Zram-generator](https://wiki.archlinux.org/title/Zram-generator)
