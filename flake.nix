{
  description = "finix on Rockchip RK3506G2";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    finix = {
      url = "github:finix-community/finix/0509ea488d45d79f39fd1663d106ab8591a8b06e";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      finix,
    }:
    let
      buildSystem = "x86_64-linux";
      targetSystem = "armv7l-linux";

      allowRkbin = pkg: (nixpkgs.lib.getName pkg) == "rkbin-rk3506";

      pkgsCross = import nixpkgs {
        localSystem = buildSystem;
        crossSystem = targetSystem;
        config.allowUnfreePredicate = allowRkbin;
        overlays = import ./overlays { lib = nixpkgs.lib; };
      };

      pkgsNative = import nixpkgs {
        system = buildSystem;
        config.allowUnfreePredicate = allowRkbin;
      };

      finixModules = import "${finix}/modules";

      # Shared module list — every config gets these
      baseModules = [
        ./modules/minimal.nix
        ./modules/u-boot-rockchip
        ./modules/cross-toplevel.nix
      ];

      finixSystem = configModule:
        pkgsCross.lib.evalModules {
          specialArgs = {
            inherit finixModules;
            finixSrc = finix;
          };
          modules = [
            finixModules.default
            { nixpkgs.pkgs = pkgsCross; }
            configModule
          ] ++ baseModules;
        };

      # Shared args for image builders
      rkbin = pkgsNative.callPackage ./pkgs/rkbin.nix { };
      kernel = pkgsCross.callPackage ./pkgs/linux-rockchip-rk3506.nix { };
      u-boot = pkgsCross.callPackage ./pkgs/u-boot-rk3506.nix { inherit rkbin; };

      mkImage = builder: configModule: extraArgs:
        pkgsNative.callPackage builder ({
          pkgs = pkgsCross;
          inherit pkgsNative;
          lib = pkgsCross.lib;
          systemTopLevel = (finixSystem configModule).config.system.topLevel;
          u-boot-rk3506 = u-boot;
          inherit kernel;
        } // extraArgs);
    in
    {
      nixosConfigurations = {
        rk3506 = finixSystem ./configuration.nix;
        rk3506-nand = finixSystem ./configuration-nand.nix;
        rk3506-nand-flasher = finixSystem ./configuration-nand-flasher.nix;
      };

      packages.${buildSystem} = rec {
        inherit rkbin kernel;
        linux-rockchip-rk3506 = kernel;
        u-boot-rk3506 = u-boot;
        u-boot-usbplug-rk3506 = pkgsCross.callPackage ./pkgs/u-boot-usbplug-rk3506.nix {
          inherit rkbin;
        };

        sdImage = mkImage ./pkgs/sd-image.nix ./configuration.nix { };

        nandImage = mkImage ./pkgs/nand-image.nix ./configuration-nand.nix { };

        nandFlasherImage = mkImage ./pkgs/sd-nand-flasher-image.nix ./configuration-nand-flasher.nix {
          ubiImage = "${nandImage}/ubi.img";
        };
      };

      apps.${buildSystem} = import ./apps {
        pkgs = pkgsNative;
        sdImage = self.packages.${buildSystem}.sdImage;
        nandImage = self.packages.${buildSystem}.nandImage;
        nandFlasherImage = self.packages.${buildSystem}.nandFlasherImage;
        usbplug = self.packages.${buildSystem}.u-boot-usbplug-rk3506;
      };
    };
}
