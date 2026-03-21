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
      # Build host
      buildSystem = "x86_64-linux";

      # Target
      targetSystem = "armv7l-linux";

      pkgsCross = import nixpkgs {
        localSystem = buildSystem;
        crossSystem = targetSystem;
      };

      pkgsNative = import nixpkgs { system = buildSystem; };

      finixModules = import "${finix}/modules";

      finixSystem =
        { modules ? [ ] }:
        pkgsCross.lib.evalModules {
          modules = [
            finixModules.default
            { nixpkgs.pkgs = pkgsCross; }
          ] ++ modules;
        };
    in
    {
      nixosConfigurations.rk3506 = finixSystem {
        modules = [
          ./configuration.nix
          ./modules/u-boot-rockchip
        ];
      };

      packages.${buildSystem} = {
        # Cross-compiled packages for the target
        rkbin = pkgsNative.callPackage ./pkgs/rkbin.nix { };
        linux-rockchip-rk3506 = pkgsCross.callPackage ./pkgs/linux-rockchip-rk3506.nix { };
        u-boot-rk3506 = pkgsCross.callPackage ./pkgs/u-boot-rk3506.nix {
          rkbin = self.packages.${buildSystem}.rkbin;
        };
      };
    };
}
