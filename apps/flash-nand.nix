# Flash full SPI NAND image on Luckfox Lyra via rkdeveloptool (Maskrom mode).
#
# Writes a single contiguous 256 MiB image containing GPT, idblock,
# u-boot.itb, boot partition, and UBI rootfs in one rkdeveloptool wl command.
#
# Usage: nix run .#flash-nand
{ pkgs, mkApp, nandImage, rkbin }:

mkApp "flash-nand" ''
  set -euo pipefail

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash-nand [--no-erase]"
    echo ""
    echo "Flash full SPI NAND image on Luckfox Lyra via rkdeveloptool."
    echo "Writes a single contiguous image (GPT + bootloader + rootfs)."
    echo "Erases the full flash before writing (default)."
    echo ""
    echo "The board must be in Maskrom mode:"
    echo "  1. Hold the BOOT button"
    echo "  2. Connect USB-C"
    echo "  3. Release BOOT button"
    echo ""
    echo "Options:"
    echo "  --no-erase   Skip full-chip erase before writing"
    echo ""
    exit 0
  fi

  NAND="${nandImage}"
  DB_LOADER="$NAND/download.bin"
  NAND_IMG="$NAND/nand.img"

  if [ ! -f "$NAND_IMG" ]; then
    echo "ERROR: nand.img not found at $NAND"
    exit 1
  fi

  # Check for rkdeveloptool
  if ! command -v rkdeveloptool &>/dev/null; then
    echo "ERROR: rkdeveloptool not found in PATH"
    echo "Install it with: nix-shell -p rkdeveloptool"
    exit 1
  fi

  # Check for device and ensure Maskrom mode
  LD_OUTPUT=$(rkdeveloptool ld 2>/dev/null || true)
  if echo "$LD_OUTPUT" | grep -qi 'loader'; then
    echo "Device found in Loader mode — resetting to Maskrom..."
    rkdeveloptool rd 3
    sleep 3
    LD_OUTPUT=$(rkdeveloptool ld 2>/dev/null || true)
    if ! echo "$LD_OUTPUT" | grep -qi 'maskrom'; then
      echo "ERROR: Device did not re-enumerate in Maskrom mode after reset."
      echo "Try manually: hold BOOT, reconnect USB-C, release BOOT."
      exit 1
    fi
  elif ! echo "$LD_OUTPUT" | grep -qi 'maskrom'; then
    echo "ERROR: No device found in Maskrom/Loader mode."
    echo ""
    echo "Enter Maskrom mode:"
    echo "  1. Hold the BOOT button on the Luckfox Lyra"
    echo "  2. Connect USB-C to your host"
    echo "  3. Release BOOT button"
    exit 1
  fi

  echo "Found device in Maskrom mode."
  echo ""
  echo "Image: $NAND_IMG ($(du -h "$NAND_IMG" | awk '{print $1}'))"
  echo ""
  echo "THIS WILL ERASE THE SPI NAND FLASH."
  read -p "Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi

  echo ""
  echo ">>> Downloading loader (Maskrom → Loader)..."
  rkdeveloptool db "$DB_LOADER"
  sleep 2

  if [[ "''${1:-}" != "--no-erase" ]]; then
    echo ">>> Erasing flash..."
    rkdeveloptool ef
    sleep 1
  fi

  echo ">>> Writing nand.img @ sector 0..."
  rkdeveloptool wl 0 "$NAND_IMG"

  echo ">>> Resetting device..."
  rkdeveloptool rd

  echo ""
  echo "Done! The Luckfox Lyra should boot from SPI NAND."
''
