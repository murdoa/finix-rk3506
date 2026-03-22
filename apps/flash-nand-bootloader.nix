# Flash NAND bootloader components only (no UBI rootfs).
#
# Writes GPT, idblock, u-boot.itb, and boot.img via rkdeveloptool.
# These small components flash reliably through the Loader firmware.
# The UBI rootfs is flashed separately via SD card (flash-nand-sd).
#
# Usage: nix run .#flash-nand-bootloader
{ pkgs, mkApp, nandImage, rkbin }:

mkApp "flash-nand-bootloader" ''
  set -euo pipefail

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash-nand-bootloader [--no-erase]"
    echo ""
    echo "Flash NAND bootloader components only (no UBI rootfs)."
    echo "The UBI rootfs is flashed via SD card: nix run .#flash-nand-sd"
    echo ""
    echo "Components flashed:"
    echo "  - GPT (primary + backup)"
    echo "  - idblock.img (DDR init + SPL)"
    echo "  - u-boot.itb (U-Boot + OP-TEE)"
    echo "  - boot.img (kernel, initrd, DTB, extlinux)"
    echo ""
    echo "The board must be in Maskrom mode:"
    echo "  1. Hold the BOOT button"
    echo "  2. Connect USB-C"
    echo "  3. Release BOOT button"
    exit 0
  fi

  NAND="${nandImage}"
  DB_LOADER="$NAND/download.bin"

  . "$NAND/layout.env"

  if [ ! -f "$NAND/idblock.img" ]; then
    echo "ERROR: NAND components not found at $NAND"
    exit 1
  fi

  if ! command -v rkdeveloptool &>/dev/null; then
    echo "ERROR: rkdeveloptool not found in PATH"
    echo "Install it with: nix-shell -p rkdeveloptool"
    exit 1
  fi

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
  echo "Bootloader components (NO rootfs):"
  echo "  idblock.img  @ sector $IDBLOCK_SECTOR ($(( IDBLOCK_SECTOR * 512 / 1024 ))K)"
  echo "  u-boot.itb   @ sector $UBOOT_SECTOR ($(( UBOOT_SECTOR * 512 / 1024 ))K)"
  echo "  boot.img     @ sector $BOOT_SECTOR ($(( BOOT_SECTOR * 512 / 1024 ))K)"
  echo ""
  echo "UBI rootfs will NOT be flashed (use flash-nand-sd for that)."
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
    echo ">>> Erasing flash (skip with --no-erase)..."
    rkdeveloptool ef
    sleep 1
  fi

  echo ">>> Writing GPT (primary) @ sector 0..."
  rkdeveloptool wl 0 "$NAND/gpt-primary.img"

  echo ">>> Writing idblock @ sector $IDBLOCK_SECTOR..."
  rkdeveloptool wl $IDBLOCK_SECTOR "$NAND/idblock.img"

  echo ">>> Writing u-boot.itb @ sector $UBOOT_SECTOR..."
  rkdeveloptool wl $UBOOT_SECTOR "$NAND/u-boot.itb"

  echo ">>> Writing boot.img @ sector $BOOT_SECTOR..."
  rkdeveloptool wl $BOOT_SECTOR "$NAND/boot.img"

  echo ">>> Writing GPT (backup) @ sector $GPT_BACKUP_SECTOR..."
  rkdeveloptool wl $GPT_BACKUP_SECTOR "$NAND/gpt-backup.img"

  echo ">>> Resetting device..."
  rkdeveloptool rd

  echo ""
  echo "Done! Bootloader components flashed."
  echo ""
  echo "Next: flash UBI rootfs via SD card:"
  echo "  nix run .#flash-nand-sd"
''
