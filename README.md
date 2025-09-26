# Arch-Linux-BTRFS-Snapper-ZRAM-SecureBoot

A collection of automated scripts and step-by-step documentation that turns a blank UEFI machine into an **Arch Linux** system with:

* **BTRFS** on LUKS (full-disk encryption)  
* **Snapper** snapshots automatically triggered by `pacman` , `yay` and `paru`  
* **ZRAM** swap (no swap partition/file needed)  
* **Secure Boot** enabled and signed from day one (your own keys, no Microsoft keys)  
* **systemd-boot** as the bootloader (lightning-fast, no GRUB)
