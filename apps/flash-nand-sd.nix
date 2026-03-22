# Write the NAND flasher SD card image to an SD card.
#
# This SD image auto-flashes the NAND UBI partition on boot using the
# kernel MTD stack, bypassing the buggy Rockchip Loader firmware.
#
# Workflow:
#   1. nix run .#flash-nand-sd          — write this SD image
#   2. Insert SD, power on — auto-flashes NAND UBI partition, reboots
#
# Primary flash path is nix run .#flash-nand (usbplug + rkdeveloptool).
# This SD flasher is a fallback for writing UBI only.
#
# Usage: nix run .#flash-nand-sd
{ pkgs, mkApp, sdCardById, nandFlasherImage }:

mkApp "flash-nand-sd" ''
  set -euo pipefail

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash-nand-sd"
    echo ""
    echo "Write the NAND flasher SD card image."
    echo ""
    echo "This SD image boots Linux and auto-flashes the NAND UBI partition"
    echo "using flash_erase + nandwrite through the kernel MTD stack."
    echo ""
    echo "Writes to: ${sdCardById}"
    echo ""
    echo "Full workflow:"
    echo "  1. nix run .#flash-nand-sd          (write this SD card)"
    echo "  2. Insert SD into board, power on"
    echo "  3. Wait for auto-flash + reboot"
    echo "  4. Remove SD card — board boots from NAND"
    echo ""
    echo "Primary flash path: nix run .#flash-nand (full image via USB)"
    exit 0
  fi

  export PATH="${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.pv ]}:$PATH"

  DEVICE="${sdCardById}"

  if [ ! -e "$DEVICE" ]; then
    echo "ERROR: SD card reader not found at:"
    echo "  $DEVICE"
    echo ""
    echo "Plug in the correct USB reader and try again."
    echo "Find your reader with: ls -la /dev/disk/by-id/ | grep usb"
    echo ""
    echo "Then update sdCardById in apps/default.nix"
    exit 1
  fi

  REAL_DEV=$(readlink -f "$DEVICE")
  echo "Found SD card reader: $DEVICE -> $REAL_DEV"

  if [ "$(cat /sys/block/$(basename "$REAL_DEV")/removable 2>/dev/null)" != "1" ]; then
    echo "ERROR: $REAL_DEV is not a removable device. Refusing to continue."
    exit 1
  fi

  SIZE=$(lsblk -bdno SIZE "$REAL_DEV" 2>/dev/null)
  SIZE_GB=$(( SIZE / 1073741824 ))

  IMG_FILE="${nandFlasherImage}/finix-rk3506-nand-flasher.img"

  if [ ! -f "$IMG_FILE" ]; then
    echo "ERROR: Image not found at $IMG_FILE"
    exit 1
  fi

  IMG_SIZE=$(stat -c%s "$IMG_FILE")
  IMG_SIZE_MB=$(( IMG_SIZE / 1048576 ))

  echo ""
  echo "Image:  $IMG_FILE (''${IMG_SIZE_MB}MB)"
  echo "Target: $DEVICE -> $REAL_DEV (''${SIZE_GB}GB)"
  echo ""
  echo "This is the NAND FLASHER image — it will:"
  echo "  1. Boot Linux from SD"
  echo "  2. Erase + write UBI partition on SPI NAND"
  echo "  3. Reboot into NAND"
  echo ""
  echo "THIS WILL ERASE ALL DATA ON THE SD CARD."
  read -p "Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi

  echo "Flashing..."
  pv "$IMG_FILE" | sudo dd of="$REAL_DEV" bs=4M oflag=direct status=none
  sudo sync
  echo "Done! Insert the SD card into the Luckfox Lyra and power on."
''
