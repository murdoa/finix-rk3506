# Build a bootable SD card image for Luckfox Lyra (RK3506G2).
#
# Produces a raw `.img` file suitable for dd-ing to an SD card.
# No root or loopback devices required — uses fakeroot + mkfs tools.
#
# GPT layout:
#   Raw area:  sector 64 (32KB)    — idbloader.img (DDR init + SPL)
#   Part 1:    sector 8192 (4MB)   — u-boot.itb (FIT: U-Boot + OP-TEE)  4MB
#   Part 2:    sector 16384 (8MB)  — FAT32 /boot (extlinux.conf, kernel, initrd, DTB)  32MB
#   Part 3:    sector 81920 (40MB) — ext4 rootfs (Nix store closure)  grows
#
# Usage:
#   nix build .#sdImage
#   dd if=result/finix-rk3506.img of=/dev/sdX bs=4M status=progress
{
  pkgs,         # cross pkgs (target = armv7l)
  pkgsNative,   # native build host pkgs (x86_64)
  lib,
  systemTopLevel,
  u-boot-rk3506,
  kernel,
}:

let
  # Closure info for the Nix store — everything needed to run the system
  closureInfo = pkgsNative.closureInfo { rootPaths = [ systemTopLevel ]; };

  # Kernel package for DTB access
  kernelDtbs = "${kernel}/dtbs";

  # Boot partition config
  kernelPath = "${systemTopLevel}/kernel";
  initrdPath = "${systemTopLevel}/initrd";
  dtbName = "rk3506g-luckfox-lyra-sd.dtb";

  # Kernel params from configuration.nix (duplicated here for extlinux.conf)
  kernelParams = "console=ttyFIQ0 earlycon=uart8250,mmio32,0xff0a0000 rootwait rw root=/dev/mmcblk0p3 rootfstype=ext4 fw_devlink=permissive";
in
pkgsNative.stdenv.mkDerivation {
  name = "finix-rk3506.img";

  # No source — we're assembling from other derivations
  dontUnpack = true;

  nativeBuildInputs = with pkgsNative; [
    dosfstools    # mkfs.vfat, fsck.vfat
    mtools        # mcopy, mmd (populate FAT without mount)
    e2fsprogs     # mkfs.ext4, fsck.ext4, resize2fs, dumpe2fs
    libfaketime   # deterministic timestamps
    fakeroot      # fake UID 0 for ext4 ownership
    gptfdisk      # sgdisk (GPT partition table)
    util-linux    # sfdisk, partx
    coreutils
    perl          # for size calculations if needed
  ];

  buildCommand = ''
    set -euo pipefail

    img="$out/finix-rk3506.img"
    mkdir -p "$out"

    echo "=== Building Luckfox Lyra SD card image ==="

    # ---------------------------------------------------------------
    # 1. Build the ext4 rootfs image
    # ---------------------------------------------------------------
    echo "--- Creating rootfs ---"

    mkdir -p rootImage/nix/store

    # Copy the entire Nix store closure
    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${closureInfo}/store-paths

    # Nix DB registration (for nix-store --load-db on first boot)
    cp ${closureInfo}/registration rootImage/nix-path-registration

    # Create basic directory structure
    mkdir -p rootImage/{boot,dev,etc,proc,run,sys,tmp,var}
    mkdir -p rootImage/var/{cache,db,empty,lib,log,spool}
    ln -sfn /run rootImage/var/run

    # Symlink /run/current-system so activation works
    # (the real symlink is set up by the activation script, but we need
    # the directory to exist)

    # Calculate rootfs size
    numInodes=$(find ./rootImage | wc -l)
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * 1.20) }')
    bytes=$((2 * 4096 * numInodes + 4096 * numDataBlocks))
    echo "rootfs: $bytes bytes (numInodes=$numInodes, numDataBlocks=$numDataBlocks)"

    # Round up to nearest MiB
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

    # Verify
    fsck.ext4 -n -f rootfs.img

    # Shrink to fit, then add 16MiB headroom
    resize2fs -M rootfs.img
    new_size=$(dumpe2fs -h rootfs.img | awk -F: \
      '/Block count/{count=$2} /Block size/{size=$2} END{print int((count*size+16*2^20)/size)}')
    resize2fs rootfs.img $new_size

    rootfsSizeBytes=$(stat -c%s rootfs.img)
    rootfsSectors=$((rootfsSizeBytes / 512))
    echo "rootfs image: $rootfsSizeBytes bytes ($rootfsSectors sectors)"

    # ---------------------------------------------------------------
    # 2. Build the FAT32 boot partition image
    # ---------------------------------------------------------------
    echo "--- Creating boot partition ---"

    # 32MB boot partition — kernel (~6MB) + initrd (~8MB) + DTB + extlinux.conf
    bootSizeMB=32
    bootSectors=$((bootSizeMB * 1024 * 1024 / 512))
    truncate -s $((bootSectors * 512)) boot.img

    mkfs.vfat -F 16 -n FINIX_BOOT boot.img

    # Create directory structure
    mmd -i boot.img ::extlinux
    mmd -i boot.img ::dtb

    # Write extlinux.conf
    cat > extlinux.conf << 'EXTEOF'
DEFAULT finix
TIMEOUT 30
PROMPT 0

LABEL finix
  MENU LABEL finix
  LINUX /kernel
  INITRD /initrd
  FDT /dtb/${dtbName}
  APPEND init=${systemTopLevel}/init ${kernelParams}
EXTEOF

    mcopy -i boot.img extlinux.conf ::extlinux/extlinux.conf

    # Copy kernel, initrd, DTB
    mcopy -i boot.img ${kernelPath} ::kernel
    mcopy -i boot.img ${initrdPath} ::initrd
    mcopy -i boot.img ${kernelDtbs}/${dtbName} ::dtb/${dtbName}

    # Verify FAT
    fsck.vfat -vn boot.img

    echo "boot partition OK"

    # ---------------------------------------------------------------
    # 3. Assemble the full SD card image
    # ---------------------------------------------------------------
    echo "--- Assembling SD card image ---"

    # Layout:
    #   0-63:         GPT header + protective MBR
    #   64-8191:      raw idbloader.img (DDR init + SPL)
    #   8192-16383:   partition 1 (uboot) — u-boot.itb     4MB
    #   16384-<end>:  partition 2 (boot)  — FAT32           32MB
    #   <boot_end>+:  partition 3 (rootfs) — ext4           grows

    bootStartSector=16384
    bootEndSector=$((bootStartSector + bootSectors - 1))
    rootfsStartSector=$((bootEndSector + 1))

    # Total image size
    totalSectors=$((rootfsStartSector + rootfsSectors + 34))  # +34 for backup GPT
    truncate -s $((totalSectors * 512)) "$img"

    # Write GPT partition table
    sgdisk \
      --clear \
      --set-alignment=1 \
      --new=1:8192:16383     --change-name=1:uboot  --typecode=1:8300 \
      --new=2:$bootStartSector:$bootEndSector --change-name=2:boot --typecode=2:EF00 \
      --new=3:$rootfsStartSector:$((rootfsStartSector + rootfsSectors - 1)) --change-name=3:rootfs --typecode=3:8300 \
      --partition-guid=3:614e0000-0000-4b53-8000-1d28000054a9 \
      "$img"

    # Write idbloader.img at sector 64 (raw, before partitions)
    dd if=${u-boot-rk3506}/bin/idbloader.img of="$img" bs=512 seek=64 conv=notrunc

    # Write u-boot.itb into partition 1
    dd if=${u-boot-rk3506}/bin/u-boot.itb of="$img" bs=512 seek=8192 conv=notrunc

    # Write boot partition image
    dd if=boot.img of="$img" bs=512 seek=$bootStartSector conv=notrunc

    # Write rootfs partition image
    dd if=rootfs.img of="$img" bs=512 seek=$rootfsStartSector conv=notrunc

    echo ""
    echo "=== SD card image built ==="
    echo "  Image: $img"
    echo "  Size:  $(du -h "$img" | awk '{print $1}')"
    echo ""
    echo "Flash with:"
    echo "  dd if=$img of=/dev/sdX bs=4M status=progress"
  '';
}
