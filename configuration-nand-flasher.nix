# NAND flasher — single-purpose SD card that flashes UBI to SPI NAND.
#
# Boots from SD card using the NAND DTS so SPI NAND partitions are visible
# as /dev/mtd0-4. On first boot, a finit task erases the UBI partition and
# writes ubi.img through the kernel MTD stack.
#
# Usage:
#   1. Write this SD image:      nix run .#flash-nand-sd
#   2. Insert SD, power on — board boots SD, flashes NAND UBI, reboots
#
# This is a fallback. Primary path: nix run .#flash-nand (usbplug + rkdeveloptool)
{ pkgs, finixModules, board, ... }:
{
  imports = [
    ./profiles/base.nix
    finixModules.sysklogd
  ];

  networking.hostName = "nand-flasher";

  boot.initrd.kernelModules = [ "mmc_block" "ext4" ];

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
    dtbPath = "/dtb/rk3506g-luckfox-lyra-nand.dtb";
    bootDevice = "/dev/mmcblk0";
  };

  users.users.root = {
    password = "$6$cqZKvfwHmoQwVp28$61S9QwBIB3Q5c8mUJt6sZW2cejQIta86KxSeFhDDd1CukI45/Nq0VL7GMVVsqOh9sHySkok2K4M3XpY1i404b/";
  };

  # No getty by default — the flash script handles the serial console.
  # If the user aborts flashing, the script spawns a login shell instead.

  services.mdevd.enable = true;
  services.sysklogd.enable = true;

  environment.systemPackages = with pkgs; [
    mtdutils
  ];

  # Oneshot flash task — runs at boot on the serial console.
  # Shows a countdown; press any key to abort and get a login shell.
  finit.tasks.flash-nand = {
    command = let
      flashScript = pkgs.writeShellApplication {
        name = "flash-nand.sh";
        runtimeInputs = with pkgs; [ busybox mtdutils ];
        text = ''
          TTY=/dev/ttyFIQ0
          exec 0< "$TTY"
          exec 1> "$TTY"
          exec 2>&1

          abort_to_shell() {
            echo ""
            echo "Aborted. Dropping to login shell..."
            echo ""
            exec login -f root
          }

          echo ""
          echo "================================================"
          echo "  NAND Flasher — Luckfox Lyra (RK3506)"
          echo "================================================"
          echo ""

          UBI_IMG="/flash/ubi.img"
          DONE_MARKER="/flash/.flashed"
          MTD_DEV=""

          # Skip if already flashed
          if [ -f "$DONE_MARKER" ]; then
            echo "Already flashed (marker exists at $DONE_MARKER)."
            echo "Remove it to re-flash, or dropping to shell."
            abort_to_shell
          fi

          # Check ubi.img exists
          if [ ! -f "$UBI_IMG" ]; then
            echo "ERROR: $UBI_IMG not found!"
            echo "The SD image was not built correctly."
            abort_to_shell
          fi

          # Countdown — press any key to abort
          TIMEOUT=5
          echo "Flashing will begin in $TIMEOUT seconds."
          echo "Press any key to abort and get a login shell."
          echo ""
          for i in $(seq "$TIMEOUT" -1 1); do
            printf "\r  Starting in %d... " "$i"
            if read -r -t 1 -n 1 2>/dev/null; then
              abort_to_shell
            fi
          done
          printf "\r                      \r"
          echo ""

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
            abort_to_shell
          fi

          echo "Found UBI partition: $MTD_DEV"
          echo "UBI image: $UBI_IMG ($(du -h "$UBI_IMG" | cut -f1))"
          echo ""

          echo ">>> Erasing $MTD_DEV..."
          flash_erase "$MTD_DEV" 0 0
          echo "    Done."
          echo ""

          echo ">>> Writing UBI image to $MTD_DEV..."
          nandwrite -p "$MTD_DEV" "$UBI_IMG"
          echo "    Done."
          echo ""

          # Mark as flashed
          touch "$DONE_MARKER"
          sync

          echo "================================================"
          echo "  NAND flash complete!"
          echo "  Remove the SD card and reboot to boot from NAND."
          echo "================================================"
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
