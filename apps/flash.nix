{ pkgs, mkApp, sdCardById, sdImage }:

mkApp "flash" ''
  set -euo pipefail

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash"
    echo ""
    echo "Build and write the SD card image for the Luckfox Lyra."
    echo ""
    echo "Writes to a hardcoded USB card reader only:"
    echo "  ${sdCardById}"
    echo ""
    echo "Safety: refuses non-removable devices, requires interactive confirmation."
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

  # Sanity check: must be removable
  if [ "$(cat /sys/block/$(basename "$REAL_DEV")/removable 2>/dev/null)" != "1" ]; then
    echo "ERROR: $REAL_DEV is not a removable device. Refusing to continue."
    exit 1
  fi

  SIZE=$(lsblk -bdno SIZE "$REAL_DEV" 2>/dev/null)
  SIZE_GB=$(( SIZE / 1073741824 ))

  IMG_FILE="${sdImage}/finix-rk3506.img"

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
  echo "THIS WILL ERASE ALL DATA ON THE SD CARD."
  read -p "Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi

  echo "Flashing..."
  pv "$IMG_FILE" | sudo dd of="$REAL_DEV" bs=4M oflag=direct status=none
  sudo sync
  echo "Done! SD card is ready."
''
