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
{ config, pkgs, lib, ... }:

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

    # util-linux is still needed — security wrappers reference mount/umount
    # by full store path, and finit modules use agetty, etc.
    util-linux

    # terminfo for serial console
    ncurses

    # Board-specific
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

  # No VGA/HDMI console — serial only. Kills kbd (2.5 MiB) and VESA blanking.
  hardware.console.enable = false;

  # Replace GNU coreutils/findutils/grep in activation PATH with busybox.
  # Finix hardcodes these in system.activation.path for the activate script.
  # net-tools (hostname) and getent are also not needed on an offline board.
  system.activation.path = lib.mkForce (with pkgs; map lib.getBin [
    busybox         # coreutils, findutils, grep, sed, etc.
    shadow          # needed by user activation
    util-linux      # mount, mountpoint
  ]);

  # Replace finit's default PATH packages with busybox.
  # Upstream defaults: coreutils, findutils, gnugrep, gnused, util-linux.mount
  finit.path = lib.mkForce [
    pkgs.busybox
    config.finit.package  # finit itself needs to be in PATH
    pkgs.util-linux.mount # required by finit on shutdown
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
      util-linux
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
