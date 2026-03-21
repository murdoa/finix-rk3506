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

      allowRkbin = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "rkbin-rk3506" ];

      pkgsCross = import nixpkgs {
        localSystem = buildSystem;
        crossSystem = targetSystem;
        config.allowUnfreePredicate = allowRkbin;
        overlays = [
          # Embedded kernels have most drivers built-in, not as loadable modules.
          # The module closure builder doesn't know about builtins and errors out.
          # Same trick as nixos-xlnx/nixos-zedboard — let missing .ko files slide.
          (final: prev: {
            makeModulesClosure = x:
              prev.makeModulesClosure (x // { allowMissing = true; });
          })
        ];
      };

      pkgsNative = import nixpkgs {
        system = buildSystem;
        config.allowUnfreePredicate = allowRkbin;
      };

      finixModules = import "${finix}/modules";

      finixSystem =
        { modules ? [ ] }:
        pkgsCross.lib.evalModules {
          specialArgs = {
            # Pass finix module set so configs can import optional modules
            inherit finixModules;
            # Raw finix source path — needed by cross-toplevel.nix to reference
            # files like finit/switch-to-configuration.sh
            finixSrc = finix;
          };
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
          ./modules/cross-toplevel.nix
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
