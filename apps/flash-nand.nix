# Flash SPI NAND on Luckfox Lyra via rkdeveloptool (Maskrom mode).
#
# Flashes partitions individually matching Rockchip NAND conventions:
#   1. db download.bin       — enter Loader mode
#   2. wl <sector> component — write each partition
#
# Usage: nix run .#flash-nand
{ pkgs, mkApp, nandImage, rkbin }:

mkApp "flash-nand" ''
  set -euo pipefail

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash-nand [--erase-first]"
    echo ""
    echo "Flash SPI NAND on Luckfox Lyra via rkdeveloptool."
    echo ""
    echo "The board must be in Maskrom mode:"
    echo "  1. Hold the BOOT button"
    echo "  2. Connect USB-C"
    echo "  3. Release BOOT button"
    echo ""
    echo "Options:"
    echo "  --erase-first   Erase flash before writing"
    echo ""
    exit 0
  fi

  NAND="${nandImage}"
  DB_LOADER="$NAND/download.bin"

  # Source layout offsets
  . "$NAND/layout.env"

  if [ ! -f "$NAND/idblock.img" ]; then
    echo "ERROR: NAND components not found at $NAND"
    exit 1
  fi

  # Check for rkdeveloptool
  if ! command -v rkdeveloptool &>/dev/null; then
    echo "ERROR: rkdeveloptool not found in PATH"
    echo "Install it with: nix-shell -p rkdeveloptool"
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
    exit 1
  fi

  echo "Found device in Maskrom mode."
  echo ""
  echo "Components:"
  echo "  idblock.img  @ sector $IDBLOCK_SECTOR ($(( IDBLOCK_SECTOR * 512 / 1024 ))K)"
  echo "  u-boot.itb   @ sector $UBOOT_SECTOR ($(( UBOOT_SECTOR * 512 / 1024 ))K)"
  echo "  boot.img     @ sector $BOOT_SECTOR ($(( BOOT_SECTOR * 512 / 1024 ))K)"
  echo "  ubi.img      @ sector $UBI_SECTOR ($(( UBI_SECTOR * 512 / 1024 ))K)"
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

  if [[ "''${1:-}" == "--erase-first" ]]; then
    echo ">>> Erasing flash..."
    rkdeveloptool ef
    sleep 1
  fi

  echo ">>> Writing idblock @ sector $IDBLOCK_SECTOR..."
  rkdeveloptool wl $IDBLOCK_SECTOR "$NAND/idblock.img"

  echo ">>> Writing u-boot.itb @ sector $UBOOT_SECTOR..."
  rkdeveloptool wl $UBOOT_SECTOR "$NAND/u-boot.itb"

  echo ">>> Writing boot.img @ sector $BOOT_SECTOR..."
  rkdeveloptool wl $BOOT_SECTOR "$NAND/boot.img"

  echo ">>> Writing ubi.img @ sector $UBI_SECTOR..."
  rkdeveloptool wl $UBI_SECTOR "$NAND/ubi.img"

  echo ">>> Resetting device..."
  rkdeveloptool rd

  echo ""
  echo "Done! The Luckfox Lyra should boot from SPI NAND."
''
