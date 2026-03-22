# finix system configuration for the NAND flasher SD card.
#
# Boots from SD card but uses the NAND DTS so the SPI NAND partitions
# are visible as /dev/mtd0-4. On first boot, a finit task erases the
# UBI partition (mtd4) and writes ubi.img through the kernel MTD stack,
# bypassing the broken Rockchip Loader firmware write path.
#
# The ubi.img is placed at /flash/ubi.img on the ext4 rootfs by the
# SD image builder (sd-nand-flasher-image.nix).
#
# Usage:
#   1. Write this SD image:      nix run .#flash-nand-sd
#   2. Insert SD, power on — board boots SD, flashes NAND UBI, reboots
#
# This is a fallback. Primary path: nix run .#flash-nand (usbplug + rkdeveloptool)
{
  config,
  pkgs,
  lib,
  finixModules,
  ...
}:
let
  linux-rockchip-rk3506 = pkgs.callPackage ./pkgs/linux-rockchip-rk3506.nix { };
  u-boot-rk3506 = pkgs.callPackage ./pkgs/u-boot-rk3506.nix {
    rkbin = pkgs.callPackage ./pkgs/rkbin.nix { };
  };
in
{
  imports = [ finixModules.sysklogd ];

  networking.hostName = "nand-flasher";

  boot.kernelPackages = pkgs.linuxPackagesFor linux-rockchip-rk3506;

  boot.kernelParams = [
    "console=ttyFIQ0"
    "earlycon=uart8250,mmio32,0xff0a0000"
    "rootwait"
    "rw"
  ];

  boot.initrd.availableKernelModules = lib.mkForce [
    "dw_mmc"
    "dw_mmc_rockchip"
    "mmc_block"
    "ext4"
    "spi_rockchip"
    "spi_mem"
    "mtd"
  ];

  boot.initrd.kernelModules = [ "mmc_block" "ext4" ];

  # SD card rootfs — same as configuration.nix
  fileSystems."/" = {
    device = "/dev/mmcblk0p3";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/mmcblk0p2";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  programs.u-boot-rockchip = {
    enable = true;
    package = u-boot-rk3506;
    dtbPath = "/dtb/rk3506g-luckfox-lyra-nand.dtb";
    bootDevice = "/dev/mmcblk0";
  };

  providers.bootloader.backend = "u-boot-rockchip";

  users.users.root = {
    password = "$6$cqZKvfwHmoQwVp28$61S9QwBIB3Q5c8mUJt6sZW2cejQIta86KxSeFhDDd1CukI45/Nq0VL7GMVVsqOh9sHySkok2K4M3XpY1i404b/";
  };

  finit.ttys.ttyFIQ0 = {
    runlevels = "2345";
    nowait = true;
  };

  services.mdevd.enable = true;
  services.sysklogd.enable = true;

  environment.systemPackages = with pkgs; [
    mtdutils
  ];

  # Oneshot flash task — runs at boot, flashes ubi.img to NAND, reboots.
  # The flash script is a finit task that runs once at runlevel 2.
  finit.tasks.flash-nand = {
    command = let
      flashScript = pkgs.writeShellApplication {
        name = "flash-nand.sh";
        runtimeInputs = with pkgs; [ busybox mtdutils ];
        text = ''
          UBI_IMG="/flash/ubi.img"
          DONE_MARKER="/flash/.flashed"
          MTD_DEV=""

          echo "=== NAND Flasher ==="

          # Skip if already flashed
          if [ -f "$DONE_MARKER" ]; then
            echo "Already flashed (marker exists). Remove $DONE_MARKER to re-flash."
            exit 0
          fi

          # Check ubi.img exists
          if [ ! -f "$UBI_IMG" ]; then
            echo "ERROR: $UBI_IMG not found!"
            echo "The SD image was not built correctly."
            exit 1
          fi

          # Find the MTD device for the "ubi" partition
          while IFS=': ' read -r dev _size _erasesize name; do
            clean_name="$(echo "$name" | tr -d '"')"
            if [ "$clean_name" = "ubi" ]; then
              MTD_DEV="/dev/$dev"
              break
            fi
          done < /proc/mtd

          if [ -z "$MTD_DEV" ]; then
            echo "ERROR: No MTD partition named 'ubi' found!"
            echo "Contents of /proc/mtd:"
            cat /proc/mtd
            echo ""
            echo "Is the correct DTB loaded? Need rk3506g-luckfox-lyra-nand.dtb"
            exit 1
          fi

          echo "Found UBI partition: $MTD_DEV"
          echo "UBI image: $UBI_IMG ($(du -h "$UBI_IMG" | cut -f1))"
          echo ""

          echo ">>> Erasing $MTD_DEV..."
          flash_erase "$MTD_DEV" 0 0
          echo "    Done."

          echo ">>> Writing UBI image to $MTD_DEV..."
          nandwrite -p "$MTD_DEV" "$UBI_IMG"
          echo "    Done."

          # Mark as flashed so we don't re-flash on next boot
          touch "$DONE_MARKER"
          sync

          echo ""
          echo "=== NAND flash complete! ==="
          echo "Remove the SD card and reboot to boot from NAND."
          echo ""
          echo "Rebooting in 5 seconds..."
          sleep 5
          reboot
        '';
      };
    in flashScript;
    runlevels = "2";
  };
}
