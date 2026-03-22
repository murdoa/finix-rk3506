# Bootable SPI NAND image for Luckfox Lyra (RK3506G2).
#
# Produces a raw image that can be flashed via rkdeveloptool in Maskrom mode.
# The image contains:
#   1. idbloader.img at sector 64 (32KB) — BootROM loads DDR init + SPL
#   2. GPT partition table at sector 0
#   3. u-boot.itb in the "uboot" GPT partition
#   4. FAT16 boot partition with extlinux.conf, kernel, initrd, DTB
#   5. UBI image with UBIFS rootfs (LZO compressed)
#
# Flash layout (128 MiB / 0x8000000):
#   Sector 0      : GPT protective MBR + header
#   Sector 64     : idbloader.img (overlaps GPT area, BootROM reads raw)
#   Sector 8192   : u-boot.itb (4 MiB partition "uboot")
#   Sector 16384  : boot partition (24 MiB, FAT16, "boot", bootable)
#   Sector 65536  : UBI partition (rest, ~96 MiB)
#
# SPI NAND geometry (typical 128 MiB):
#   Page size:     2048 bytes
#   OOB per page:  64 bytes
#   Pages/block:   64
#   Block size:    128 KiB (PEB = 131072)
#   LEB size:      126976 bytes (PEB - 2 pages overhead for UBI)
#   Total blocks:  1024
#   Total size:    128 MiB (134217728 bytes)
{
  pkgs,
  pkgsNative,
  lib,
  systemTopLevel,
  u-boot-rk3506,
  kernel,
}:

let
  closureInfo = pkgsNative.closureInfo { rootPaths = [ systemTopLevel ]; };
  kernelDtbs = "${kernel}/dtbs";
  kernelPath = "${systemTopLevel}/kernel";
  initrdPath = "${systemTopLevel}/initrd";
  dtbName = "rk3506g-luckfox-lyra-nand.dtb";

  kernelParams = lib.concatStringsSep " " [
    "console=ttyFIQ0"
    "earlycon=uart8250,mmio32,0xff0a0000"
    "rootwait"
    "rw"
    "ubi.mtd=3"
    "root=ubi0:rootfs"
    "rootfstype=ubifs"
  ];

  # SPI NAND geometry
  pageSize = 2048;
  pagesPerBlock = 64;
  blockSize = pageSize * pagesPerBlock;  # 128 KiB = 131072
  # UBI overhead: 2 pages per PEB (for EC and VID headers)
  lebSize = blockSize - 2 * pageSize;    # 126976 bytes

  # Flash layout (in 512-byte sectors)
  ubootStartSector = 8192;     # 4 MiB
  bootStartSector = 16384;     # 8 MiB
  bootSizeMB = 24;
  bootSectors = bootSizeMB * 1024 * 1024 / 512;   # 49152 sectors
  bootEndSector = bootStartSector + bootSectors - 1;
  ubiStartSector = bootEndSector + 1;  # 32 MiB
  totalFlashBytes = 128 * 1024 * 1024;  # 128 MiB
  totalSectors = totalFlashBytes / 512;
  ubiEndSector = totalSectors - 34;     # Leave room for backup GPT

  # UBI partition size in bytes
  ubiPartBytes = (ubiEndSector - ubiStartSector + 1) * 512;
  # Number of PEBs available for UBI
  ubiPebCount = ubiPartBytes / blockSize;
  # Reserve PEBs for UBI overhead (typically 4 + ~1% for wear leveling)
  ubiOverheadPebs = 4 + ubiPebCount / 100 + 1;
  # Max LEBs available for UBIFS
  maxLebCount = ubiPebCount - ubiOverheadPebs;
in
pkgsNative.stdenv.mkDerivation {
  name = "finix-rk3506-nand.img";

  dontUnpack = true;

  nativeBuildInputs = with pkgsNative; [
    dosfstools
    mtools
    mtdutils
    libfaketime
    fakeroot
    gptfdisk
    util-linux
    coreutils
    perl
  ];

  buildCommand = ''
    set -euo pipefail

    img="$out/finix-rk3506-nand.img"
    mkdir -p "$out"

    echo "=== Building SPI NAND image ==="
    echo "  Flash size: ${toString totalFlashBytes} bytes (${toString (totalFlashBytes / 1024 / 1024)} MiB)"
    echo "  UBI partition: ${toString ubiPartBytes} bytes (${toString (ubiPartBytes / 1024 / 1024)} MiB)"
    echo "  PEB size: ${toString blockSize}, LEB size: ${toString lebSize}"
    echo "  UBI PEBs: ${toString ubiPebCount}, max LEBs for UBIFS: ${toString maxLebCount}"

    # --- UBIFS rootfs ---
    echo ">>> Building UBIFS rootfs..."
    mkdir -p rootImage/nix/store
    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${closureInfo}/store-paths
    cp ${closureInfo}/registration rootImage/nix-path-registration
    mkdir -p rootImage/{boot,dev,etc,proc,run,sys,tmp,var}
    mkdir -p rootImage/var/{cache,db,empty,lib,log,spool}
    ln -sfn /run rootImage/var/run

    echo "  Rootfs tree size: $(du -sh rootImage | cut -f1)"

    mkfs.ubifs \
      --min-io-size=${toString pageSize} \
      --leb-size=${toString lebSize} \
      --max-leb-cnt=${toString maxLebCount} \
      --compr=lzo \
      --root=rootImage \
      --output=rootfs.ubifs

    echo "  UBIFS image size: $(du -sh rootfs.ubifs | cut -f1)"

    # --- UBI image (wraps UBIFS volume) ---
    echo ">>> Building UBI image..."
    cat > ubinize.cfg << EOF
    [rootfs]
    mode=ubi
    vol_id=0
    vol_name=rootfs
    vol_type=dynamic
    vol_flags=autoresize
    image=rootfs.ubifs
    EOF

    ubinize \
      --min-io-size=${toString pageSize} \
      --peb-size=${toString blockSize} \
      --sub-page-size=${toString pageSize} \
      --output=ubi.img \
      ubinize.cfg

    echo "  UBI image size: $(du -sh ubi.img | cut -f1)"

    ubiSizeBytes=$(stat -c%s ubi.img)
    if [ "$ubiSizeBytes" -gt "${toString ubiPartBytes}" ]; then
      echo "ERROR: UBI image ($ubiSizeBytes bytes) exceeds partition (${toString ubiPartBytes} bytes)!"
      echo "The closure is too large for the NAND flash."
      exit 1
    fi

    # --- FAT16 boot partition ---
    echo ">>> Building boot partition..."
    bootSizeBytes=$((${toString bootSectors} * 512))
    truncate -s $bootSizeBytes boot.img
    mkfs.vfat -F 16 -n FINIX_BOOT boot.img

    mmd -i boot.img ::extlinux
    mmd -i boot.img ::dtb

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

    # Strip leading whitespace (nix heredoc indentation)
    sed -i 's/^    //' extlinux.conf

    mcopy -i boot.img extlinux.conf ::extlinux/extlinux.conf
    mcopy -i boot.img ${kernelPath} ::kernel
    mcopy -i boot.img ${initrdPath} ::initrd
    mcopy -i boot.img ${kernelDtbs}/${dtbName} ::dtb/${dtbName}

    echo "  Boot partition: $(du -sh boot.img | cut -f1)"

    # --- Assemble full NAND image ---
    echo ">>> Assembling NAND image..."
    truncate -s ${toString totalFlashBytes} "$img"

    # Write GPT partition table
    sgdisk \
      --clear \
      --set-alignment=1 \
      --new=1:${toString ubootStartSector}:${toString (bootStartSector - 1)} \
        --change-name=1:uboot --typecode=1:8300 \
      --new=2:${toString bootStartSector}:${toString bootEndSector} \
        --change-name=2:boot --typecode=2:EF00 --attributes=2:set:2 \
      --new=3:${toString ubiStartSector}:${toString ubiEndSector} \
        --change-name=3:ubi --typecode=3:8300 \
      "$img"

    # Write idbloader at sector 64 (32KB) — same as SD card convention
    # The BootROM reads from this fixed offset.
    dd if=${u-boot-rk3506}/bin/idbloader.img of="$img" bs=512 seek=64 conv=notrunc status=none

    # Write u-boot.itb into the uboot partition
    dd if=${u-boot-rk3506}/bin/u-boot.itb of="$img" bs=512 seek=${toString ubootStartSector} conv=notrunc status=none

    # Write boot partition
    dd if=boot.img of="$img" bs=512 seek=${toString bootStartSector} conv=notrunc status=none

    # Write UBI image
    dd if=ubi.img of="$img" bs=512 seek=${toString ubiStartSector} conv=notrunc status=none

    echo ""
    echo "=== NAND image built: $img ==="
    echo "  Total size: $(du -sh "$img" | cut -f1)"
    echo ""
    echo "  Flash with rkdeveloptool in Maskrom mode:"
    echo "    rkdeveloptool db ${u-boot-rk3506}/bin/idbloader.img"
    echo "    rkdeveloptool wl 0 $img"
    echo ""
    echo "  Or flash individual components:"
    echo "    rkdeveloptool wl 0x40 ${u-boot-rk3506}/bin/idbloader.img"
    echo "    rkdeveloptool wl ${toString ubootStartSector} ${u-boot-rk3506}/bin/u-boot.itb"

    # Also output individual components for flexible flashing
    cp ${u-boot-rk3506}/bin/idbloader.img "$out/"
    cp ${u-boot-rk3506}/bin/u-boot.itb "$out/"
    cp ubi.img "$out/"
    cp boot.img "$out/"
  '';
}
