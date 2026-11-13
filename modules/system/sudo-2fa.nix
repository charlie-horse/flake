# sudo with two factors (custom.sudo2fa.enable; off by default).
#
# When on, sudo (and polkit, where enabled) needs admin's PASSWORD and ALSO
# one of:
#   (a) pam_rssh: a signature from the FIDO2 resident key `ssh:admin`
#       (rsshKeys; by default admin's sk- SSH login keys) through the
#       ssh-agent forwarded into the session (`ssh -A`); the touch happens
#       on the YubiKey at the client;
#   (b) pam_u2f: a touch on a YubiKey plugged into this host (console),
#       registered in ./sudo-2fa-u2f-keys with origin pam://neurosis.
# A password leaked from one host (every host shares admin's password, and
# root on any host can read it from /run/secrets-for-users) is then useless
# without the YubiKey. Design, rollout, lockout and recovery:
# docs/sudo-2fa.md.
#
# The auth stack this builds (for each service in `services`):
#
#   auth [success=1 default=ignore] pam_rssh.so ...  # sudo2fa-rssh
#   auth required                   pam_u2f.so  ...  # sudo2fa-u2f
#   auth sufficient                 pam_unix.so ...  # unix (NixOS's own)
#   auth required                   pam_deny.so      # deny (NixOS's own)
#
# rssh success jumps over pam_u2f; rssh failure (no agent, no ssh:admin key
# in it, no touch) is ignored and pam_u2f becomes required. pam_unix stays
# `sufficient`, which in Linux-PAM returns success only if no earlier
# `required` module failed; otherwise the stack ends in pam_deny. So: the
# password is always needed, plus one of the two factors. The assertions
# below refuse any configuration where another module could short-circuit
# this (a `sufficient` fprintd/u2f/ssh_agent_auth/..., a reordered rule,
# NOPASSWD sudo rules, sudo-rs).
#
# Servers import this file from modules/server/default.nix; the desktops
# get it with modules/ wholesale (the option stays off there).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    all
    any
    concatLines
    concatStringsSep
    elem
    filter
    findFirst
    genAttrs
    hasInfix
    hasPrefix
    imap0
    mkEnableOption
    mkForce
    mkIf
    mkOption
    optional
    sort
    splitString
    trim
    types
    versionAtLeast
    ;

  cfg = config.custom.sudo2fa;

  # One registration (pamu2fcfg -o/-i) is valid on every host only if the
  # origin and appid are the same everywhere.
  u2fOrigin = "pam://neurosis";

  # Mapping lines of the u2f key file; `#` comments and blank lines dropped.
  u2fMappings = filter (l: l != "" && !(hasPrefix "#" l)) (
    map trim (splitString "\n" (builtins.readFile cfg.u2fKeysFile))
  );
  # `admin:<KeyHandle>,<UserKey>,<CoseType>,<Options>[:<more keys>]`.
  u2fMappingValid = l: builtins.match "admin(:[^,:]+,[^,:]+,[^,:]+,[^:]*)+" l != null;

  # Root-owned, immutable files in the store (never a user-writable file:
  # admin could otherwise add its own keys).
  u2fAuthFile = pkgs.writeText "sudo-2fa-u2f-keys" (concatLines u2fMappings);
  rsshKeyFile = pkgs.writeText "sudo-2fa-rssh-keys" (concatLines cfg.rsshKeys);

  # `cue` (a "touch the device" prompt) exists from pam_rssh 1.2.0 on; an
  # unknown option makes pam_rssh fail outright. The desktop pin carries
  # 1.2.0-rc2, which lacks it.
  rsshHasCue =
    versionAtLeast pkgs.pam_rssh.version "1.2.0" && !(hasInfix "-rc" pkgs.pam_rssh.version);

  # Controls that cannot end the auth stack with success or jump over rules.
  harmlessControls = [
    "required"
    "requisite"
    "optional"
  ];

  # Built-in NixOS rules that would let a factor replace the password.
  # Forced off on the 2FA services; the assertion catches any others.
  builtinBypassRules = [
    "rssh"
    "u2f"
    "ssh_agent_auth"
    "fprintd"
    "howdy"
    "p11"
    "yubico"
    "ussh"
    "systemd_home"
  ];

  # Checks the rendered auth rules of one service: rssh, u2f and unix are
  # adjacent in that order, unix is `sufficient`, and every other enabled
  # rule is harmless.
  checkService =
    svc:
    let
      rules = sort (a: b: a.order < b.order) (
        filter (r: r.enable) (builtins.attrValues config.security.pam.services.${svc}.rules.auth)
      );
      names = map (r: r.name) rules;
      idx = name: findFirst (x: x != null) (-1) (imap0 (i: n: if n == name then i else null) names);
      iR = idx "sudo2fa-rssh";
      iU = idx "sudo2fa-u2f";
      iX = idx "unix";
      unix = findFirst (r: r.name == "unix") null rules;
      others = filter (
        r:
        !(elem r.name [
          "sudo2fa-rssh"
          "sudo2fa-u2f"
          "unix"
        ])
      ) rules;
      bad = filter (r: !(elem r.control harmlessControls)) others;
    in
    [
      {
        assertion = iR >= 0 && iU == iR + 1 && iX == iU + 1 && unix != null && unix.control == "sufficient";
        message = ''
          custom.sudo2fa: /etc/pam.d/${svc} must have the auth rules
          sudo2fa-rssh, sudo2fa-u2f and a `sufficient` unix rule adjacent in
          that order (rssh's success=1 skips exactly one rule). Got:
          ${concatStringsSep ", " (map (r: "${r.name} (${r.control})") rules)}'';
      }
      {
        assertion = bad == [ ];
        message = ''
          custom.sudo2fa: /etc/pam.d/${svc} has auth rules that could skip
          admin's password or the second factor:
          ${concatStringsSep ", " (map (r: "${r.name} (${r.control})") bad)}'';
      }
      {
        assertion = hasInfix "# sudo2fa-u2f" config.security.pam.services.${svc}.text;
        message = "custom.sudo2fa: security.pam.services.${svc}.text is overridden; the 2FA rules would not apply.";
      }
    ];

  sudoRulesNoPasswd = any (
    rule:
    rule.users != [ "root" ] && any (c: builtins.isAttrs c && (elem "NOPASSWD" c.options)) rule.commands
  ) config.security.sudo.extraRules;
in
{
  options.custom.sudo2fa = {
    enable = mkEnableOption ''
      two-factor sudo: admin's password plus either the `ssh:admin` FIDO2
      key through a forwarded ssh-agent (pam_rssh) or a touch on a YubiKey
      plugged into the host (pam_u2f). See docs/sudo-2fa.md before
      enabling: a wrong setup locks sudo out'';

    services = mkOption {
      type = types.listOf types.str;
      default = [ "sudo" ] ++ optional config.security.polkit.enable "polkit-1";
      defaultText = lib.literalExpression ''[ "sudo" ] ++ optional config.security.polkit.enable "polkit-1"'';
      description = ''
        PAM services that get the two-factor auth stack. polkit-1 is
        included where polkit runs (m2mini): polkit lets wheel become root
        (pkexec, run0) with the password alone otherwise.
      '';
    };

    rsshKeys = mkOption {
      type = types.listOf types.str;
      # admin's FIDO2 (sk-) SSH login keys, set in modules/system/admin.nix:
      # one place to replace the key. Plain keys are left out: a key that
      # needs no touch on the YubiKey would not be a second factor.
      default = filter (hasPrefix "sk-") config.users.users.admin.openssh.authorizedKeys.keys;
      defaultText = lib.literalExpression ''filter (hasPrefix "sk-") config.users.users.admin.openssh.authorizedKeys.keys'';
      description = ''
        Public keys (authorized_keys format) whose signature through the
        forwarded ssh-agent counts as the second factor. By default
        admin's FIDO2 (`sk-`) SSH login keys (modules/system/admin.nix).
        Kept in a root-owned store file, never in a user-writable
        authorized_keys.
      '';
    };

    u2fKeysFile = mkOption {
      type = types.path;
      default = ./sudo-2fa-u2f-keys;
      description = ''
        pam_u2f mapping for admin (`pamu2fcfg -u admin -o pam://neurosis
        -i pam://neurosis` output, one line; public data). `#` lines are
        ignored. Enabling fails while it holds no mapping.
      '';
    };
  };

  config = mkIf cfg.enable {
    security.pam.services = genAttrs cfg.services (svc: {
      rules.auth =
        let
          unixOrder = config.security.pam.services.${svc}.rules.auth.unix.order;
        in
        {
          sudo2fa-rssh = {
            order = unixOrder - 2;
            control = "[success=1 default=ignore]";
            modulePath = "${pkgs.pam_rssh}/lib/libpam_rssh.so";
            settings = {
              auth_key_file = "${rsshKeyFile}";
              cue = rsshHasCue;
            };
          };
          sudo2fa-u2f = {
            order = unixOrder - 1;
            control = "required";
            modulePath = "${pkgs.pam_u2f}/lib/security/pam_u2f.so";
            settings = {
              authfile = "${u2fAuthFile}";
              origin = u2fOrigin;
              appid = u2fOrigin;
              cue = true;
              userpresence = 1;
            };
          };
        }
        // genAttrs builtinBypassRules (_: {
          enable = mkForce false;
        });
    });

    # pam_rssh finds the agent through SSH_AUTH_SOCK, which sudo would
    # otherwise drop before authenticating.
    security.sudo.extraConfig = mkIf (elem "sudo" cfg.services) ''
      # custom.sudo2fa: pam_rssh needs the forwarded agent's socket.
      Defaults env_keep+=SSH_AUTH_SOCK
    '';

    assertions = [
      {
        assertion =
          u2fMappings != [ ] && all u2fMappingValid u2fMappings && builtins.length u2fMappings == 1;
        message = ''
          custom.sudo2fa: custom.sudo2fa.u2fKeysFile (by default
          modules/system/sudo-2fa-u2f-keys) must hold exactly one
          `admin:<KeyHandle>,<UserKey>,<CoseType>,<Options>` line. Register
          the YubiKey first (docs/sudo-2fa.md, "Registering the YubiKey"):
            pamu2fcfg -u admin -o ${u2fOrigin} -i ${u2fOrigin}
          Without it the console path (pam_u2f) cannot work.'';
      }
      {
        assertion = cfg.rsshKeys != [ ];
        message = "custom.sudo2fa: rsshKeys is empty (by default admin's sk- keys in users.users.admin.openssh.authorizedKeys.keys, modules/system/admin.nix).";
      }
      {
        assertion =
          !(elem "sudo" cfg.services) || (config.security.sudo.enable && !config.security.sudo-rs.enable);
        message = "custom.sudo2fa: written for sudo (security.sudo), not sudo-rs.";
      }
      {
        # NOPASSWD or !authenticate skips PAM auth, and with it both factors.
        assertion =
          config.security.sudo.wheelNeedsPassword
          && !sudoRulesNoPasswd
          && !(hasInfix "NOPASSWD" config.security.sudo.extraConfig)
          && !(hasInfix "!authenticate" config.security.sudo.extraConfig);
        message = "custom.sudo2fa: a sudo rule skips authentication (NOPASSWD, !authenticate or wheelNeedsPassword = false).";
      }
    ]
    ++ lib.concatMap checkService cfg.services;
  };
}
