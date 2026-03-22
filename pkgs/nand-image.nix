# Bootable SPI NAND components for Luckfox Lyra (RK3506G2).
#
# Produces individual flash components for partition-based flashing
# via rkdeveloptool. Matches the Rockchip/Luckfox NAND partition layout.
#
# Flash layout (128 MiB SPI NAND):
#   Offset 0        : (reserved / env)
#   Offset 256K     : idblock.img (DDR init + U-Boot SPL, IDB format)
#   Offset 512K     : u-boot.itb (FIT: U-Boot + OP-TEE + DTB)
#   Offset 1M       : boot partition (FAT16: kernel, initrd, DTB, extlinux)
#   Offset 8M       : UBI rootfs (UBIFS, LZO compressed)
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
    "ubi.mtd=4"
    "root=ubi0:rootfs"
    "rootfstype=ubifs"
  ];

  # SPI NAND geometry
  pageSize = 2048;
  pagesPerBlock = 64;
  blockSize = pageSize * pagesPerBlock;  # 128 KiB = 131072
  lebSize = blockSize - 2 * pageSize;    # 126976 bytes

  # Partition layout (in 512-byte sectors)
  # Matches Rockchip/Luckfox convention for SPI NAND
  idblockStartSector = 512;     # 256K — BootROM scans for IDB here
  ubootStartSector = 1024;      # 512K
  bootStartSector = 8192;       # 4M (u-boot.itb is ~860K, leave room)
  bootSizeMB = 20;              # 20 MiB (boot ends at 24M)
  bootSectors = bootSizeMB * 1024 * 1024 / 512;
  bootEndSector = bootStartSector + bootSectors - 1;
  ubiStartSector = 49152;       # 24M
  totalFlashBytes = 128 * 1024 * 1024;
  totalSectors = totalFlashBytes / 512;
  ubiEndSector = totalSectors - 1;

  # UBI partition size
  ubiPartBytes = (ubiEndSector - ubiStartSector + 1) * 512;
  ubiPebCount = ubiPartBytes / blockSize;
  ubiOverheadPebs = 4 + ubiPebCount / 100 + 1;
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
    util-linux
    coreutils
    perl
  ];

  buildCommand = ''
    set -euo pipefail

    mkdir -p "$out"

    echo "=== Building SPI NAND flash components ==="
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
    mkfs.vfat -n FINIX_BOOT boot.img

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

    sed -i 's/^    //' extlinux.conf

    mcopy -i boot.img extlinux.conf ::extlinux/extlinux.conf
    mcopy -i boot.img ${kernelPath} ::kernel
    mcopy -i boot.img ${initrdPath} ::initrd
    mcopy -i boot.img ${kernelDtbs}/${dtbName} ::dtb/${dtbName}

    echo "  Boot partition: $(du -sh boot.img | cut -f1)"

    # --- Output individual components ---
    echo ">>> Copying flash components..."

    # Boot loader components (from u-boot build with boot_merger)
    cp ${u-boot-rk3506}/bin/download.bin "$out/"   # for rkdeveloptool db
    cp ${u-boot-rk3506}/bin/idblock.img  "$out/"   # IDB format for NAND
    cp ${u-boot-rk3506}/bin/idbloader.img "$out/"  # rksd format for SD
    cp ${u-boot-rk3506}/bin/u-boot.itb   "$out/"

    # Filesystem images
    cp boot.img "$out/"
    cp ubi.img  "$out/"

    # Write a layout metadata file for the flash script
    cat > "$out/layout.env" << 'LAYOUT'
    IDBLOCK_SECTOR=${toString idblockStartSector}
    UBOOT_SECTOR=${toString ubootStartSector}
    BOOT_SECTOR=${toString bootStartSector}
    UBI_SECTOR=${toString ubiStartSector}
    LAYOUT

    sed -i 's/^    //' "$out/layout.env"

    echo ""
    echo "=== NAND flash components built ==="
    echo "  Flash with: nix run .#flash-nand"
    echo ""
    echo "  Layout:"
    echo "    idblock.img  @ sector ${toString idblockStartSector} ($(( ${toString idblockStartSector} * 512 / 1024 ))K)"
    echo "    u-boot.itb   @ sector ${toString ubootStartSector} ($(( ${toString ubootStartSector} * 512 / 1024 ))K)"
    echo "    boot.img     @ sector ${toString bootStartSector} ($(( ${toString bootStartSector} * 512 / 1024 ))K)"
    echo "    ubi.img      @ sector ${toString ubiStartSector} ($(( ${toString ubiStartSector} * 512 / 1024 ))K)"
  '';
}
