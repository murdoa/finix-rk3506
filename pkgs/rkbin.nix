# Rockchip binary blobs (DDR init, SPL, TEE) required for the RK3506 boot chain.
#
# These are proprietary blobs from Rockchip's rkbin repository. They run before
# U-Boot and are not replaceable with open-source alternatives at this time.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

stdenvNoCC.mkDerivation {
  pname = "rkbin-rk3506";
  version = "unstable-2025-03-21";

  src = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "rkbin";
    rev = "74213af1e952c4683d2e35952507133b61394862";
    # NOTE: hash needs to be computed on first build — use lib.fakeHash then replace
    hash = lib.fakeHash;
  };

  # Only install the RK3506-relevant blobs, not the entire 2GB+ repo
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    # DDR initialisation blob
    cp bin/rk35/rk3506_ddr_750MHz_v1.06.bin $out/bin/

    # Miniloader / SPL
    cp bin/rk35/rk3506_spl_v1.11.bin $out/bin/

    # OP-TEE (TrustZone)
    cp bin/rk35/rk3506_tee_v2.10.bin $out/bin/

    # USB firmware download tool blob
    cp bin/rk35/rk3506_usbplug_v1.03.bin $out/bin/

    # Boot pack configs
    cp RKBOOT/RK3506MINIALL.ini $out/bin/

    # Trust config
    cp RKTRUST/RK3506TOS.ini $out/bin/

    # Tools
    mkdir -p $out/tools
    cp -r tools/* $out/tools/ 2>/dev/null || true

    runHook postInstall
  '';

  dontBuild = true;
  dontFixup = true;

  meta = {
    description = "Rockchip RK3506 binary blobs (DDR, SPL, TEE)";
    homepage = "https://github.com/rockchip-linux/rkbin";
    license = lib.licenses.unfreeRedistributable;
    platforms = lib.platforms.all;
  };
}
