# Cross-compilation fix for finix's system.topLevel derivation.
#
# finix's system/activation/default.nix hardcodes ${pkgs.coreutils}/bin/ln
# in buildCommand. When cross-compiling, that's TARGET coreutils which can't
# run on the BUILD host. We disable the upstream module and redefine topLevel
# using buildPackages.coreutils.
{
  config,
  pkgs,
  lib,
  finixSrc,
  ...
}:
let
  checkAssertWarn = lib.asserts.checkAssertWarn config.assertions config.warnings;
  hostCoreutils = pkgs.buildPackages.coreutils;

  scriptOpts = {
    options = {
      deps = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "List of dependencies. The script will run after these.";
      };
      text = lib.mkOption {
        type = lib.types.lines;
        description = "The content of the script.";
      };
    };
  };
in
{
  disabledModules = [
    "${finixSrc}/modules/system/activation"
  ];

  # specialisation.nix is imported by the directory module we just disabled,
  # so we need to re-import it ourselves
  imports = [
    "${finixSrc}/modules/system/activation/specialisation.nix"
  ];

  # Redefine the options from the disabled module
  options.system.topLevel = lib.mkOption {
    type = lib.types.path;
    description = "top-level system derivation";
    readOnly = true;
  };

  options.system.activation = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable system activation scripts.";
    };

    scripts = lib.mkOption {
      type = with lib.types; attrsOf (coercedTo str lib.noDepEntry (submodule scriptOpts));
      default = { };
      description = "A set of shell script fragments executed during activation.";
    };

    path = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = "Packages added to PATH of activation scripts.";
    };

    out = lib.mkOption {
      type = lib.types.path;
      description = "the actual script to run on activation";
      readOnly = true;
    };
  };

  config = {
    system.activation.out =
      let
        set' = lib.mapAttrs (
          a: v:
          v
          // {
            text = ''
              #### Activation script snippet ${a}:
              _localstatus=0
              ${v.text}

              if (( _localstatus > 0 )); then
                printf "Activation script snippet '%s' failed (%s)\n" "${a}" "$_localstatus"
              fi
            '';
          }
        ) config.system.activation.scripts;
      in
      pkgs.writeScript "activate" ''
        #!${pkgs.runtimeShell}

        systemConfig='@systemConfig@'

        export PATH=/empty
        for i in ${toString config.system.activation.path}; do
            PATH=$PATH:$i/bin:$i/sbin
        done

        _status=0
        trap "_status=1 _localstatus=\$?" ERR

        umask 0022

        ${lib.textClosureMap lib.id set' (lib.attrNames set')}

        ln -sfn "$(readlink -f "$systemConfig")" /run/current-system

        exit $_status
      '';

    system.activation.scripts.specialfs = ''
      mkdir -p /run /tmp /var
      ln -sfn /run /var/run
    '';

    finit.tmpfiles.rules = [
      "d /etc"
      "d /run"
      "d /tmp"
      "d /var"
      "d /var/cache"
      "d /var/db"
      "d /var/empty"
      "d /var/lib"
      "d /var/log"
      "d /var/spool"
      "L+ /var/run - - - - /run"
    ];

    system.activation.path =
      with pkgs;
      map lib.getBin [
        coreutils
        gnugrep
        findutils
        getent
        stdenv.cc.libc
        shadow
        nettools
        util-linux
      ];

    # THE FIX: use hostCoreutils (buildPackages.coreutils) instead of pkgs.coreutils
    system.topLevel = checkAssertWarn (
      pkgs.stdenvNoCC.mkDerivation {
        name = "finix-system";
        preferLocalBuild = true;
        allowSubstitutes = false;
        buildCommand = ''
          mkdir -p $out $out/bin

          echo -n "finix" > $out/nixos-version

          cp ${config.system.activation.out} $out/activate

          substituteInPlace $out/activate --subst-var-by systemConfig $out

          ${hostCoreutils}/bin/ln -sr ${config.finit.package}/bin/finit $out/init
          ${hostCoreutils}/bin/ln -s ${config.environment.path} $out/sw

          mkdir $out/specialisation

          ${lib.concatMapAttrsStringSep "\n" (
            k: v: "ln -s ${v.system.topLevel} $out/specialisation/${lib.escapeShellArg k}"
          ) config.specialisation}
        ''
        + lib.optionalString config.boot.kernel.enable ''
          # ARM32 produces zImage (not bzImage). Detect which one exists.
          if [ -e ${config.boot.kernelPackages.kernel}/bzImage ]; then
            ${hostCoreutils}/bin/ln -s ${config.boot.kernelPackages.kernel}/bzImage $out/kernel
          else
            ${hostCoreutils}/bin/ln -s ${config.boot.kernelPackages.kernel}/zImage $out/kernel
          fi
          ${hostCoreutils}/bin/ln -s ${config.system.modulesTree} $out/kernel-modules
          ${hostCoreutils}/bin/ln -s ${config.hardware.firmware}/lib/firmware $out/firmware
        ''
        + lib.optionalString config.boot.initrd.enable ''
          ${hostCoreutils}/bin/ln -s ${config.boot.initrd.package}/initrd $out/initrd
        ''
        + lib.optionalString config.finit.enable ''
          cp ${finixSrc}/modules/finit/switch-to-configuration.sh $out/bin/switch-to-configuration
          substituteInPlace $out/bin/switch-to-configuration \
            --subst-var out \
            --subst-var-by bash ${pkgs.bash} \
            --subst-var-by distroId finix \
            --subst-var-by finit ${config.finit.package} \
            --subst-var-by installHook ${config.providers.bootloader.installHook}
        ''
        + lib.optionalString config.boot.bootspec.enable ''
          ${config.boot.bootspec.writer}
        ''
        + lib.optionalString (config.boot.bootspec.enable && config.boot.bootspec.enableValidation) ''
          ${config.boot.bootspec.validator} "$out/${config.boot.bootspec.filename}"
        '';
      }
    );
  };
}
