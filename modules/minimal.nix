# Closure size reductions for embedded use.
# Import this module to strip desktop/workstation bloat from the image.
#
# Cumulative savings vs default finix configuration:
#   - xdg.mime (shared-mime-info + glib chain):  ~22.5 MiB
#   - xdg.portal (desktop-portal + deps):        avoided
#   - perl → bash setup-etc rewrite:             ~51 MiB  (etc-setup-bash.nix)
#   - security-wrapper linuxHeaders leak:        ~16.6 MiB  (overlay in flake.nix)
#   - u-boot removed from system-path:           ~30 MiB  (x86 glibc chain)
#   - strip default system packages:             ~25 MiB  (curl, gawk, tar, etc.)
#   - DTBs → single board only:                  ~20 MiB  (kernel postInstall)
#   - System.map removal:                        ~2.7 MiB (kernel postInstall)
#   - locale stripping:                          ~2.9 MiB
#   - util-linux → util-linuxMinimal:            ~30 MiB  (kills sqlite, systemd-libs, coreutils)
#   - FUSE disabled:                             ~1 MiB   (fusermount + fuse2/3 wrappers)
#   - mdevd PATH → busybox + util-linuxMinimal:  (part of util-linux swap)
{ config, pkgs, lib, finixSrc, ... }:

let
  # Build a minimal finix-setup plugin using util-linuxMinimal for mount/swap/fsck.
  # The upstream finit module builds finix-setup with full util-linux, pulling
  # sqlite (4.9M), systemd-minimal-libs (3.6M), util-linux-lib (12.8M), etc.
  finix-setup-minimal = pkgs.callPackage "${finixSrc}/pkgs/finix-setup" {
    util-linux = pkgs.util-linuxMinimal;
    unixtools = pkgs.unixtools // {
      fsck = pkgs.runCommand "fsck-util-linux-minimal-${pkgs.util-linuxMinimal.version}" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.util-linuxMinimal}/bin/fsck $out/bin/fsck
      '';
    };
  };
in

{
  imports = [ ./etc-setup-bash.nix ];

  # shared-mime-info (7.5 MiB) + glib dependency chain (~15 MiB).
  xdg.mime.enable = false;

  # xdg-desktop-portal: D-Bus interfaces for sandboxed desktop apps.
  xdg.portal.enable = false;

  # Override finix's fat default systemPackages. The upstream default pulls in
  # curl (+ openssl + krb5 + nghttp chain), gawk, gnutar, cpio, diffutils,
  # gnupatch, coreutils-full (dupe of coreutils), etc.
  #
  # Stripped to bare minimum for an offline serial-only embedded system.
  # Busybox replaces coreutils, findutils, procps, grep, sed, less, which,
  # gzip, and provides ash as a lightweight shell.
  environment.systemPackages = lib.mkForce (with pkgs; [
    # Busybox provides: sh, ls, cp, mv, rm, cat, echo, grep, sed, find,
    # ps, top, free, mount, umount, dmesg, less, which, gzip, vi, etc.
    busybox

    # Full bash for scripts that need it (finix activation uses bash)
    bashInteractive

    # util-linuxMinimal: no lastlog2 (kills sqlite 4.9M), no libudev
    # (kills systemd-minimal-libs 3.6M), minimal lib (1.9M vs 12.8M).
    util-linuxMinimal

    # terminfo for serial console
    ncurses

    # Board-specific — overlay patches mount.ubifs to use util-linuxMinimal
    mtdutils
  ]);

  # Strip locales to just C/POSIX + UTF-8. Default ships full locale archive.
  i18n.supportedLocales = [ "C.UTF-8/UTF-8" ];

  # Finix default pathsToLink includes emacs, hunspell, themes, vulkan, etc.
  # Strip to what actually matters.
  environment.pathsToLink = lib.mkForce [
    "/bin"
    "/sbin"
    "/lib"
    "/share/terminfo"
  ];

  # Override finit to use our minimal finix-setup plugin.
  # The finit module's `apply` function appends --with-plugin-path pointing
  # to a finix-setup built with full util-linux. We can't prevent that, but
  # configureFlags is a list and the apply does old ++ [bloated-path].
  # We override again after apply to filter out the bloated path and add ours.
  # This works because the module option system evaluates: apply(merge(defs)),
  # and we wrap the RESULT with another overrideAttrs.
  #
  # Actually — we can't post-process after apply from the config side.
  # Instead, we accept that finit will be built with TWO --with-plugin-path
  # flags. In autotools, the LAST one wins. The apply appends after our
  # overrideAttrs, so the bloated path wins. We work around this by
  # using postConfigure to patch the generated config.h directly.
  finit.package = let
    base = pkgs.finit;
  in base.overrideAttrs (old: {
    postConfigure = (old.postConfigure or "") + ''
      # The module's apply function adds --with-plugin-path with full
      # util-linux. Replace the baked-in path in config.h with our minimal one.
      sed -i 's|EXTERNAL_PLUGIN_PATH "[^"]*"|EXTERNAL_PLUGIN_PATH "${finix-setup-minimal}/lib/finit/plugins"|' config.h
    '';
  });

  # No VGA/HDMI console — serial only. Kills kbd (2.5 MiB) and VESA blanking.
  hardware.console.enable = false;

  # Replace GNU coreutils/findutils/grep in activation PATH with busybox.
  # Finix hardcodes these in system.activation.path for the activate script.
  # net-tools (hostname) and getent are also not needed on an offline board.
  system.activation.path = lib.mkForce (with pkgs; map lib.getBin [
    busybox         # coreutils, findutils, grep, sed, etc.
    shadow          # needed by user activation
    util-linuxMinimal  # mount, mountpoint — no sqlite/systemd-libs bloat
  ]);

  # Replace finit's default PATH packages with busybox.
  # Upstream defaults: coreutils, findutils, gnugrep, gnused, util-linux.mount
  finit.path = lib.mkForce [
    pkgs.busybox
    config.finit.package  # finit itself needs to be in PATH
    pkgs.util-linuxMinimal.mount # required by finit on shutdown
  ];

  # Replace shebangCompatibility to use busybox env instead of coreutils (1.7 MiB).
  system.activation.scripts.shebangCompatibility = lib.mkForce ''
    mkdir -p -m 0755 /usr/bin /bin
    ln -sfn ${pkgs.busybox}/bin/env /usr/bin/env
    ln -sfn "${pkgs.bashInteractive}/bin/sh" /bin/sh
  '';

  # /etc/profile references coreutils for dircolors. Replace with busybox.
  environment.etc.profile.text = lib.mkForce ''
    if [ "$TERM" != "dumb" ]; then
      PROMPT_COLOR="1;31m"
      ((UID)) && PROMPT_COLOR="1;32m"
      PS1="\n\[\033[$PROMPT_COLOR\][\u@\h:\w]\\$\[\033[0m\] "
    fi
    export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin
  '';

  # remount-nix-store.sh uses coreutils in runtimeInputs. Replace with busybox.
  finit.tasks.remount-nix-store.command = lib.mkForce (pkgs.writeShellApplication {
    name = "remount-nix-store.sh";
    runtimeInputs = with pkgs; [
      busybox
      util-linuxMinimal
    ];
    text = ''
      chown -f 0:30000 /nix/store
      chmod -f 1775 /nix/store
      if ! [[ "$(findmnt --noheadings --output OPTIONS /nix/store)" =~ ro(,|$) ]]; then
        mount --bind /nix/store /nix/store
        mount -o remount,ro,bind /nix/store
      fi
    '';
  });

  # Replace procps sysctl (2.8 MiB) with busybox sysctl.
  finit.tasks.sysctl.command = lib.mkForce
    "${pkgs.busybox}/bin/sysctl -p ${config.environment.etc."sysctl.d/60-finix.conf".source}";

  # Override security wrappers mount/umount to use util-linuxMinimal.
  # Default points to full util-linux (set in wrappers/default.nix).
  security.wrappers.mount.source = lib.mkForce
    "${lib.getBin pkgs.util-linuxMinimal}/bin/mount";
  security.wrappers.umount.source = lib.mkForce
    "${lib.getBin pkgs.util-linuxMinimal}/bin/umount";

  # No FUSE on a serial-only embedded board. Kills fusermount/fuse2/fuse3
  # security wrappers and their dependency chains.
  boot.supportedFilesystems.fuse.enable = false;

  # Override mdevd's finit service PATH to use busybox + util-linuxMinimal
  # instead of coreutils + full util-linux.
  finit.services.mdevd.path = lib.mkForce (with pkgs; [
    busybox          # replaces coreutils
    execline         # mdevd scripts use execline
    kmod             # modprobe for modalias
    util-linuxMinimal  # blkid for disk symlinks
  ]);

  # Override suid-sgid-wrappers task PATH: uses coreutils (1.7 MiB) for cp/chmod.
  # Busybox provides these same utilities.
  finit.tasks.suid-sgid-wrappers.path = lib.mkForce [ pkgs.busybox ];

  # The shadow module hardcodes pam_xauth in su's PAM config, pulling in
  # xauth → libX11 → libxcb (~4.2 MiB of X11 on a headless board).
  # Override with the same config minus the xauth line.
  security.pam.services.su.text = lib.mkForce ''
    # Account management.
    account required pam_unix.so # unix (order 10900)

    # Authentication management.
    auth sufficient pam_rootok.so # rootok (order 10200)
    auth required pam_faillock.so # faillock (order 10400)
    auth sufficient pam_unix.so likeauth try_first_pass # unix (order 11500)
    auth required pam_deny.so # deny (order 12300)

    # Password management.
    password sufficient pam_unix.so nullok yescrypt # unix (order 10200)

    # Session management.
    session required pam_env.so conffile=/etc/security/pam_env.conf readenv=0 # env (order 10100)
    session required pam_unix.so # unix (order 10200)
  '';
}
