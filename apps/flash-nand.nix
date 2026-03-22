# Flash full SPI NAND image on Luckfox Lyra via rkdeveloptool (Maskrom mode).
#
# Uses an open-source U-Boot usbplug that replaces Rockchip's proprietary
# rk3506_usbplug_v1.03.bin, which corrupts page 63 of random erase blocks.
# The U-Boot usbplug uses the same MTD stack as the kernel — correct ECC.
#
# Usage: nix run .#flash-nand
{ pkgs, mkApp, nandImage, usbplug, ... }:

mkApp "flash-nand" ''
  set -euo pipefail
  export PATH="${pkgs.lib.makeBinPath [ pkgs.rkdeveloptool pkgs.coreutils ]}:$PATH"

  if [[ "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
    echo "Usage: nix run .#flash-nand [--erase-flash]"
    echo ""
    echo "Flash full SPI NAND image on Luckfox Lyra via rkdeveloptool."
    echo "Uses open-source U-Boot usbplug for correct SPI NAND writes."
    echo ""
    echo "The board must be in Maskrom mode:"
    echo "  1. Hold the BOOT button"
    echo "  2. Connect USB-C"
    echo "  3. Release BOOT button"
    echo ""
    echo "Options:"
    echo "  --erase-flash   Erase full chip before writing"
    echo ""
    exit 0
  fi

  NAND="${nandImage}"
  DB_LOADER="${usbplug}/bin/download.bin"
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
  echo "Loader:  $DB_LOADER (open-source U-Boot usbplug)"
  echo "Image:   $NAND_IMG ($(du -h "$NAND_IMG" | awk '{print $1}'))"
  echo ""
  echo "THIS WILL ERASE THE SPI NAND FLASH."
  read -p "Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi

  echo ""
  echo ">>> Downloading U-Boot usbplug (Maskrom → Loader)..."
  rkdeveloptool db "$DB_LOADER"
  sleep 3

  if [[ "''${1:-}" == "--erase-flash" ]]; then
    echo ">>> Erasing flash..."
    rkdeveloptool ef
    sleep 1
  fi

  echo ">>> Writing nand.img @ sector 0..."
  rkdeveloptool wl 0 "$NAND_IMG"

  echo ""
  echo "Done! Power cycle the board to boot from SPI NAND."
''
