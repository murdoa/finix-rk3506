# Rockchip proprietary upgrade_tool — alternative to rkdeveloptool.
#
# Unlike rkdeveloptool (open-source, libusb-based), upgrade_tool is
# Rockchip's closed-source flashing utility with additional commands
# including WriteSector (WS) with page-size-aware NAND writes.
#
# Statically linked x86_64 binary — just needs a udev rule for USB access.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
}:

stdenvNoCC.mkDerivation {
  pname = "rockchip-upgrade-tool";
  version = "2.1";

  src = fetchurl {
    url = "https://raw.githubusercontent.com/vicharak-in/Linux_Upgrade_Tool/master/upgrade_tool";
    hash = "sha256-gBfOlIDq/srvF3Hn1G1QWGjPIH7Ads2G2yHMriqG0pg=";
  };

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin $out/etc/udev/rules.d

    cp $src $out/bin/upgrade_tool
    chmod +x $out/bin/upgrade_tool

    # udev rule for Rockchip USB devices (same VID as rkdeveloptool)
    cat > $out/etc/udev/rules.d/99-rockchip.rules << 'EOF'
    # Rockchip Maskrom / Loader mode
    SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0666", GROUP="plugdev"
    EOF
    sed -i 's/^    //' $out/etc/udev/rules.d/99-rockchip.rules
  '';

  meta = {
    description = "Rockchip proprietary firmware upgrade tool";
    homepage = "https://github.com/vicharak-in/Linux_Upgrade_Tool";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "x86_64-linux" ];
    mainProgram = "upgrade_tool";
  };
}
