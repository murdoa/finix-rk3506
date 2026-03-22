# Flash the SPI NAND image to a Luckfox Lyra via rkdeveloptool (Maskrom mode).
#
# Usage: nix run .#flash-nand
#
# Prerequisites:
#   1. Connect board via USB-C while holding BOOT button (enters Maskrom mode)
#   2. rkdeveloptool must be in PATH (or install via: nix-shell -p rkdeveloptool)
{ pkgs, mkApp, nandImage }:

mkApp "flash-nand" ''
  set -euo pipefail

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash-nand"
    echo ""
    echo "Flash the SPI NAND image to a Luckfox Lyra via rkdeveloptool."
    echo ""
    echo "The board must be in Maskrom mode:"
    echo "  1. Hold the BOOT button"
    echo "  2. Connect USB-C"
    echo "  3. Release BOOT button"
    echo ""
    echo "Options:"
    echo "  --idb-only    Flash only the idbloader (for recovery)"
    echo "  --no-idb      Flash everything except idbloader"
    echo ""
    exit 0
  fi

  IMG="${nandImage}/finix-rk3506-nand.img"
  IDB="${nandImage}/idbloader.img"

  if [ ! -f "$IMG" ]; then
    echo "ERROR: NAND image not found at $IMG"
    exit 1
  fi

  # Check for rkdeveloptool
  if ! command -v rkdeveloptool &>/dev/null; then
    echo "ERROR: rkdeveloptool not found in PATH"
    echo ""
    echo "Install it with: nix-shell -p rkdeveloptool"
    echo "Or add it to your flake's devShells."
    exit 1
  fi

  # Check for Maskrom device
  if ! rkdeveloptool ld 2>/dev/null | grep -qi 'maskrom\|loader'; then
    echo "ERROR: No device found in Maskrom/Loader mode."
    echo ""
    echo "Enter Maskrom mode:"
    echo "  1. Hold the BOOT button on the Luckfox Lyra"
    echo "  2. Connect USB-C to your host"
    echo "  3. Release BOOT button"
    echo ""
    echo "Check with: rkdeveloptool ld"
    exit 1
  fi

  echo "Found device in Maskrom mode."
  echo ""

  if [[ "''${1:-}" == "--idb-only" ]]; then
    echo "Flashing idbloader only..."
    rkdeveloptool db "$IDB"
    echo "Done! idbloader flashed."
    exit 0
  fi

  IMG_SIZE=$(stat -c%s "$IMG")
  IMG_SIZE_MB=$(( IMG_SIZE / 1048576 ))

  echo "Image: $IMG (''${IMG_SIZE_MB} MiB)"
  echo ""
  echo "THIS WILL ERASE THE ENTIRE SPI NAND FLASH."
  read -p "Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi

  echo ""

  if [[ "''${1:-}" != "--no-idb" ]]; then
    echo ">>> Downloading idbloader (enter Loader mode)..."
    rkdeveloptool db "$IDB"
    sleep 1
  fi

  echo ">>> Writing full NAND image..."
  rkdeveloptool wl 0 "$IMG"

  echo ">>> Resetting device..."
  rkdeveloptool rd

  echo ""
  echo "Done! The Luckfox Lyra should boot from SPI NAND."
''
