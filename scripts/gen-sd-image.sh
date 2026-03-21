#!/usr/bin/env bash
#
# Generate an SD card image for booting finix on RK3506G2.
#
# SD card layout (standard Rockchip):
#   Sector 0-63:      Reserved (partition table)
#   Sector 64-8191:   idbloader.img (DDR init + SPL)
#   Sector 8192-16383: Reserved
#   Sector 16384+:    u-boot.itb
#   Partition 1:      /boot (FAT32, ~128MB) — extlinux.conf, DTBs
#   Partition 2:      / (ext4, rest) — Nix store, system
#
# Usage:
#   ./scripts/gen-sd-image.sh <system-toplevel> <u-boot-pkg> <output.img>
#
# Example:
#   nix build .#nixosConfigurations.rk3506.config.system.topLevel
#   nix build .#packages.x86_64-linux.u-boot-rk3506
#   ./scripts/gen-sd-image.sh ./result ./result-1 sdcard.img
#
set -euo pipefail

SYSTEM_TOPLEVEL="${1:?Usage: $0 <system-toplevel> <u-boot-pkg> <output.img>}"
UBOOT_PKG="${2:?Usage: $0 <system-toplevel> <u-boot-pkg> <output.img>}"
OUTPUT="${3:?Usage: $0 <system-toplevel> <u-boot-pkg> <output.img>}"

# Image size (2GB default — adjust for your store closure size)
IMG_SIZE_MB=2048

echo "=== finix RK3506 SD card image generator ==="
echo "System: ${SYSTEM_TOPLEVEL}"
echo "U-Boot: ${UBOOT_PKG}"
echo "Output: ${OUTPUT}"
echo ""

# Create empty image
echo "[1/6] Creating ${IMG_SIZE_MB}MB image..."
dd if=/dev/zero of="${OUTPUT}" bs=1M count="${IMG_SIZE_MB}" status=progress

# Partition: 128MB FAT32 boot + rest ext4 root
echo "[2/6] Partitioning..."
parted -s "${OUTPUT}" \
  mklabel msdos \
  mkpart primary fat32 32MiB 160MiB \
  mkpart primary ext4 160MiB 100% \
  set 1 boot on

# Write bootloader images to raw sectors
echo "[3/6] Writing bootloader..."
if [ -f "${UBOOT_PKG}/bin/idbloader.img" ]; then
  dd if="${UBOOT_PKG}/bin/idbloader.img" of="${OUTPUT}" seek=64 conv=notrunc status=none
  echo "  idbloader.img written at sector 64"
fi

if [ -f "${UBOOT_PKG}/bin/u-boot.itb" ]; then
  dd if="${UBOOT_PKG}/bin/u-boot.itb" of="${OUTPUT}" seek=16384 conv=notrunc status=none
  echo "  u-boot.itb written at sector 16384"
fi

echo "[4/6] Setting up loop device..."
LOOP=$(sudo losetup --show -fP "${OUTPUT}")
trap "sudo losetup -d ${LOOP}" EXIT

echo "[5/6] Formatting and populating boot partition..."
sudo mkfs.vfat -F 32 -n BOOT "${LOOP}p1"
BOOT_MNT=$(mktemp -d)
sudo mount "${LOOP}p1" "${BOOT_MNT}"

sudo mkdir -p "${BOOT_MNT}/extlinux"
sudo mkdir -p "${BOOT_MNT}/dtb"

# Copy kernel DTBs
if [ -d "${SYSTEM_TOPLEVEL}/kernel-modules/lib/modules" ]; then
  KVER=$(ls "${SYSTEM_TOPLEVEL}/kernel-modules/lib/modules/" | head -1)
  if [ -d "${SYSTEM_TOPLEVEL}/kernel-modules/lib/modules/${KVER}/dtbs" ]; then
    sudo cp "${SYSTEM_TOPLEVEL}/kernel-modules/lib/modules/${KVER}/dtbs/"rk3506*.dtb "${BOOT_MNT}/dtb/" 2>/dev/null || true
  fi
fi

# Copy U-Boot DTBs as fallback
if [ -d "${UBOOT_PKG}/dtb" ]; then
  sudo cp "${UBOOT_PKG}/dtb/"rk3506*.dtb "${BOOT_MNT}/dtb/" 2>/dev/null || true
fi

# Write extlinux.conf
sudo tee "${BOOT_MNT}/extlinux/extlinux.conf" > /dev/null << EOF
DEFAULT finix
TIMEOUT 30
PROMPT 0

LABEL finix
  MENU LABEL finix on RK3506
  LINUX /kernel
  INITRD /initrd
  FDT /dtb/rk3506g-evb1-v10.dtb
  APPEND init=${SYSTEM_TOPLEVEL}/init console=ttyFIQ0 earlycon=uart8250,mmio32,0xff0a0000 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw
EOF

# Copy kernel + initrd to boot partition
sudo cp "${SYSTEM_TOPLEVEL}/kernel" "${BOOT_MNT}/kernel"
sudo cp "${SYSTEM_TOPLEVEL}/initrd" "${BOOT_MNT}/initrd"

sudo umount "${BOOT_MNT}"
rmdir "${BOOT_MNT}"

echo "[6/6] Formatting and populating root partition..."
sudo mkfs.ext4 -L nixos "${LOOP}p2"
ROOT_MNT=$(mktemp -d)
sudo mount "${LOOP}p2" "${ROOT_MNT}"

# Copy the Nix store closure
echo "  Copying Nix store closure (this may take a while)..."
sudo mkdir -p "${ROOT_MNT}/nix/store"
nix-store --query --requisites "${SYSTEM_TOPLEVEL}" | while read path; do
  sudo cp -a "${path}" "${ROOT_MNT}/nix/store/"
done

# Create the system profile link
sudo mkdir -p "${ROOT_MNT}/run"
sudo ln -sfn "${SYSTEM_TOPLEVEL}" "${ROOT_MNT}/run/current-system"

sudo umount "${ROOT_MNT}"
rmdir "${ROOT_MNT}"

echo ""
echo "=== Done! ==="
echo "Write to SD card with:"
echo "  sudo dd if=${OUTPUT} of=/dev/sdX bs=4M status=progress"
echo ""
echo "Or use bmaptool for faster writes:"
echo "  sudo bmaptool copy ${OUTPUT} /dev/sdX"
