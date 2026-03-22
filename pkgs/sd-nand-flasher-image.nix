# SD card image that flashes NAND on boot.
#
# Same GPT layout as sd-image.nix, but:
#   - Uses the NAND DTB (so SPI NAND partitions are visible as MTD devices)
#   - Embeds ubi.img on the ext4 rootfs at /flash/ubi.img
#   - The NixOS config (configuration-nand-flasher.nix) runs flash_erase +
#     nandwrite at boot to program the UBI partition through the kernel MTD
#     stack, bypassing the buggy Rockchip Loader firmware.
#
# GPT layout (same as sd-image.nix):
#   Raw area:  sector 64 (32KB)    — idbloader.img (DDR init + SPL)
#   Part 1:    sector 8192 (4MB)   — u-boot.itb     4MB
#   Part 2:    sector 16384 (8MB)  — FAT32 /boot    32MB
#   Part 3:    sector 81920 (40MB) — ext4 rootfs     grows
{
  pkgs,
  pkgsNative,
  lib,
  systemTopLevel,
  u-boot-rk3506,
  kernel,
  ubiImage,
}:

let
  closureInfo = pkgsNative.closureInfo { rootPaths = [ systemTopLevel ]; };
  kernelDtbs = "${kernel}/dtbs";
  kernelPath = "${systemTopLevel}/kernel";
  initrdPath = "${systemTopLevel}/initrd";
  # Use NAND DTB — gives us fixed-partitions for the SPI NAND
  dtbName = "rk3506g-luckfox-lyra-nand.dtb";
  kernelParams = "console=ttyFIQ0 earlycon=uart8250,mmio32,0xff0a0000 rootwait rw root=/dev/mmcblk0p3 rootfstype=ext4";
in
pkgsNative.stdenv.mkDerivation {
  name = "finix-rk3506-nand-flasher.img";

  dontUnpack = true;

  nativeBuildInputs = with pkgsNative; [
    dosfstools
    mtools
    e2fsprogs
    libfaketime
    fakeroot
    gptfdisk
    util-linux
    coreutils
    perl
  ];

  buildCommand = ''
    set -euo pipefail

    img="$out/finix-rk3506-nand-flasher.img"
    mkdir -p "$out"

    # --- ext4 rootfs ---
    mkdir -p rootImage/nix/store
    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${closureInfo}/store-paths
    cp ${closureInfo}/registration rootImage/nix-path-registration
    mkdir -p rootImage/{boot,dev,etc,proc,run,sys,tmp,var}
    mkdir -p rootImage/var/{cache,db,empty,lib,log,spool}
    ln -sfn /run rootImage/var/run

    # Embed the NAND UBI image for the flash script
    mkdir -p rootImage/flash
    cp ${ubiImage} rootImage/flash/ubi.img

    echo "  UBI image embedded: $(du -sh rootImage/flash/ubi.img | cut -f1)"

    numInodes=$(find ./rootImage | wc -l)
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * 1.20) }')
    bytes=$((2 * 4096 * numInodes + 4096 * numDataBlocks))

    mebibyte=$((1024 * 1024))
    if (( bytes % mebibyte )); then
      bytes=$(( (bytes / mebibyte + 1) * mebibyte ))
    fi

    truncate -s $bytes rootfs.img
    faketime "1970-01-01 00:00:01" fakeroot mkfs.ext4 \
      -L FINIX_ROOT \
      -U 614e0000-0000-4b53-8000-1d28000054a9 \
      -d ./rootImage \
      rootfs.img
    fsck.ext4 -n -f rootfs.img

    resize2fs -M rootfs.img
    new_size=$(dumpe2fs -h rootfs.img | awk -F: \
      '/Block count/{count=$2} /Block size/{size=$2} END{print int((count*size+16*2^20)/size)}')
    resize2fs rootfs.img $new_size

    rootfsSizeBytes=$(stat -c%s rootfs.img)
    rootfsSectors=$((rootfsSizeBytes / 512))

    # --- FAT32 boot partition ---
    bootSizeMB=32
    bootSectors=$((bootSizeMB * 1024 * 1024 / 512))
    truncate -s $((bootSectors * 512)) boot.img
    mkfs.vfat -F 16 -n FINIX_BOOT boot.img

    mmd -i boot.img ::extlinux
    mmd -i boot.img ::dtb

    cat > extlinux.conf << 'EXTEOF'
DEFAULT finix
TIMEOUT 30
PROMPT 0

LABEL finix
  MENU LABEL finix-nand-flasher
  LINUX /kernel
  INITRD /initrd
  FDT /dtb/${dtbName}
  APPEND init=${systemTopLevel}/init ${kernelParams}
EXTEOF

    mcopy -i boot.img extlinux.conf ::extlinux/extlinux.conf
    mcopy -i boot.img ${kernelPath} ::kernel
    mcopy -i boot.img ${initrdPath} ::initrd
    mcopy -i boot.img ${kernelDtbs}/${dtbName} ::dtb/${dtbName}
    fsck.vfat -vn boot.img

    # --- Assemble image ---
    bootStartSector=16384
    bootEndSector=$((bootStartSector + bootSectors - 1))
    rootfsStartSector=$((bootEndSector + 1))
    totalSectors=$((rootfsStartSector + rootfsSectors + 34))
    truncate -s $((totalSectors * 512)) "$img"

    sgdisk \
      --clear \
      --set-alignment=1 \
      --new=1:8192:16383     --change-name=1:uboot  --typecode=1:8300 \
      --new=2:$bootStartSector:$bootEndSector --change-name=2:boot --typecode=2:EF00 \
      --new=3:$rootfsStartSector:$((rootfsStartSector + rootfsSectors - 1)) --change-name=3:rootfs --typecode=3:8300 \
      --partition-guid=3:614e0000-0000-4b53-8000-1d28000054a9 \
      "$img"

    dd if=${u-boot-rk3506}/bin/idbloader.img of="$img" bs=512 seek=64 conv=notrunc
    dd if=${u-boot-rk3506}/bin/u-boot.itb of="$img" bs=512 seek=8192 conv=notrunc
    dd if=boot.img of="$img" bs=512 seek=$bootStartSector conv=notrunc
    dd if=rootfs.img of="$img" bs=512 seek=$rootfsStartSector conv=notrunc

    echo "=== NAND flasher SD image: $img ($(du -h "$img" | awk '{print $1}')) ==="
    echo "  Embedded UBI image: $(du -sh ${ubiImage} | cut -f1)"
  '';
}
