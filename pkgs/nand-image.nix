# Bootable SPI NAND components for Luckfox Lyra (RK3506G2).
#
# Produces individual flash components for partition-based flashing
# via rkdeveloptool. Matches the Rockchip/Luckfox NAND partition layout.
#
# Flash layout (256 MiB SPI NAND, Winbond W25N02KV):
#   Offset 0        : GPT (protective MBR + GPT header + entries)
#   Offset 256K     : idblock.img (DDR init + U-Boot SPL, IDB format)
#   Offset 512K     : u-boot.itb (FIT: U-Boot + OP-TEE + DTB)
#   Offset 4M       : boot partition (FAT16: kernel, initrd, DTB, extlinux)
#   Offset 24M      : UBI rootfs (UBIFS, LZO compressed)
#
# SPI NAND geometry (Winbond W25N02KV, 2 Gbit):
#   Page size:     2048 bytes
#   OOB per page:  128 bytes
#   Pages/block:   64
#   Block size:    128 KiB (PEB = 131072)
#   LEB size:      126976 bytes (PEB - 2 pages overhead for UBI)
#   Total blocks:  2048
#   Total size:    256 MiB (268435456 bytes)
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
    "ubi.mtd=ubi"
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
  totalFlashBytes = 256 * 1024 * 1024;  # W25N02KV = 2 Gbit = 256 MiB
  # mtd_blk reserves the last NANDDEV_BBT_SCAN_MAXBLOCKS (4) erase blocks
  # for bad block table scanning. The virtual block device is smaller than
  # raw flash: 524288 - (4 * 256) = 523264 sectors.
  # GPT must match the exported LBA count, not raw flash capacity.
  bbtReservedBlocks = 4;
  bbtReservedSectors = bbtReservedBlocks * blockSize / 512;  # 1024
  totalSectors = totalFlashBytes / 512 - bbtReservedSectors;  # 523264
  # Reserve last 33 sectors for backup GPT
  ubiEndSector = totalSectors - 33 - 1;

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
    gptfdisk
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
    cat > ubinize.cfg << 'UBICFG'
    [rootfs]
    mode=ubi
    vol_id=0
    vol_name=rootfs
    vol_type=dynamic
    vol_flags=autoresize
    image=rootfs.ubifs
UBICFG
    sed -i 's/^    //' ubinize.cfg

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

    mcopy -i boot.img extlinux.conf ::extlinux/extlinux.conf
    mcopy -i boot.img ${kernelPath} ::kernel
    mcopy -i boot.img ${initrdPath} ::initrd
    mcopy -i boot.img ${kernelDtbs}/${dtbName} ::dtb/${dtbName}

    echo "  Boot partition: $(du -sh boot.img | cut -f1)"

    # --- GPT for SPI NAND ---
    # U-Boot's mtd_blk layer presents SPI NAND as a block device.
    # distro_bootcmd → mtd_boot → scan_dev_for_boot_part needs a GPT
    # to discover the boot partition and run extlinux from it.
    echo ">>> Generating GPT image..."
    totalSectors=${toString totalSectors}
    truncate -s $(( totalSectors * 512 )) gpt.img

    # --set-alignment=1: disable sgdisk's default 2048-sector alignment.
    # SPI NAND offsets are fixed by Rockchip conventions, not disk geometry.
    sgdisk --set-alignment=1 \
      --new=1:${toString ubootStartSector}:${toString (bootStartSector - 1)} --change-name=1:uboot --typecode=1:8300 \
      --new=2:${toString bootStartSector}:${toString bootEndSector} --change-name=2:boot --typecode=2:8300 --attributes=2:set:2 \
      --new=3:${toString ubiStartSector}:${toString ubiEndSector} --change-name=3:ubi --typecode=3:8300 \
      gpt.img

    echo "  GPT partition table:"
    sgdisk --print gpt.img

    # Extract just the GPT header area (protective MBR + GPT header + entries).
    # Sectors 0..33 = 17 KiB. We write this to sector 0 on NAND.
    dd if=gpt.img of=gpt-primary.img bs=512 count=34

    # Extract the backup GPT (last 33 sectors of the device).
    backupStart=$(( totalSectors - 33 ))
    dd if=gpt.img of=gpt-backup.img bs=512 skip=$backupStart count=33

    # --- parameter.txt for upgrade_tool di commands ---
    cat > parameter.txt << 'PARAMEOF'
FIRMWARE_VER:8.1
MACHINE_MODEL:RK3506
TYPE: GPT
GROW_ALIGN: 0
CMDLINE:mtdparts=:0x00001c00@0x00000400(uboot),0x0000a000@0x00002000(boot),-@0x0000c000(rootfs:grow)
PARAMEOF

    echo "  parameter.txt:"
    cat parameter.txt

    # --- Assemble single contiguous NAND image ---
    echo ">>> Assembling full NAND image..."
    truncate -s $(( totalSectors * 512 )) nand.img

    # GPT primary (sectors 0..33)
    dd if=gpt-primary.img of=nand.img bs=512 seek=0 conv=notrunc

    # idblock (sector 512 = 256K)
    dd if=${u-boot-rk3506}/bin/idblock.img of=nand.img bs=512 seek=${toString idblockStartSector} conv=notrunc

    # u-boot.itb (sector 1024 = 512K)
    dd if=${u-boot-rk3506}/bin/u-boot.itb of=nand.img bs=512 seek=${toString ubootStartSector} conv=notrunc

    # boot partition (sector 8192 = 4M)
    dd if=boot.img of=nand.img bs=512 seek=${toString bootStartSector} conv=notrunc

    # UBI rootfs (sector 49152 = 24M)
    dd if=ubi.img of=nand.img bs=512 seek=${toString ubiStartSector} conv=notrunc

    # GPT backup (last 33 sectors)
    dd if=gpt-backup.img of=nand.img bs=512 seek=$backupStart conv=notrunc

    echo "  Full NAND image: $(du -sh nand.img | cut -f1)"

    # --- Output ---
    echo ">>> Copying flash components..."

    # Full contiguous image for single-command flash
    cp nand.img "$out/"

    # Loader for rkdeveloptool db / upgrade_tool ul
    cp ${u-boot-rk3506}/bin/download.bin "$out/"

    # Individual components (for SD flasher and debugging)
    cp ${u-boot-rk3506}/bin/idblock.img  "$out/"
    cp ${u-boot-rk3506}/bin/idbloader.img "$out/"
    cp ${u-boot-rk3506}/bin/u-boot.itb   "$out/"
    cp gpt-primary.img "$out/"
    cp gpt-backup.img  "$out/"
    cp boot.img "$out/"
    cp ubi.img  "$out/"

    # For upgrade_tool di commands — named to match parameter.txt partitions
    cp ${u-boot-rk3506}/bin/u-boot.itb "$out/uboot.img"
    cp ubi.img "$out/rootfs.img"
    cp parameter.txt "$out/"

    # Write a layout metadata file for the flash script
    cat > layout.env << LAYOUT
IDBLOCK_SECTOR=${toString idblockStartSector}
UBOOT_SECTOR=${toString ubootStartSector}
BOOT_SECTOR=${toString bootStartSector}
UBI_SECTOR=${toString ubiStartSector}
GPT_BACKUP_SECTOR=$backupStart
TOTAL_SECTORS=$totalSectors
LAYOUT
    cp layout.env "$out/"

    echo ""
    echo "=== NAND flash components built ==="
    echo "  Flash with: nix run .#flash-nand"
    echo ""
    echo "  Layout:"
    echo "    gpt          @ sector 0"
    echo "    idblock.img  @ sector ${toString idblockStartSector} ($(( ${toString idblockStartSector} * 512 / 1024 ))K)"
    echo "    u-boot.itb   @ sector ${toString ubootStartSector} ($(( ${toString ubootStartSector} * 512 / 1024 ))K)"
    echo "    boot.img     @ sector ${toString bootStartSector} ($(( ${toString bootStartSector} * 512 / 1024 ))K)"
    echo "    ubi.img      @ sector ${toString ubiStartSector} ($(( ${toString ubiStartSector} * 512 / 1024 ))K)"
    echo "    gpt-backup   @ sector $backupStart"
    echo ""
    echo "  Full image:    nand.img ($(du -sh nand.img | cut -f1))"
  '';
}
