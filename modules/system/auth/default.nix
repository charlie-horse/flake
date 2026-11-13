# Authentication policy for every host: sshd, sudo, polkit, the console
# and the desktop's YubiKey. Servers import this directory from
# modules/server/default.nix; the desktops get it with modules/ wholesale
# (modules/default.nix imports a directory's default.nix only, so the
# helper file u2f-keys is not a module). Design, path tables, rollout and
# recovery: docs/auth.md.
#
# Options (custom.auth.*):
#
#   sshd.keysOnly              true   sshd: no password or keyboard-
#                                     interactive auth (keys only)
#   hardwareFactor.enable      false  sudo/polkit/console as in the table
#                                     below ("hardware factor on")
#   hardwareFactor.sudoServices       [ "sudo" ] (+ "polkit-1" where polkit
#                                     runs): one hardware factor, no password
#   hardwareFactor.loginServices      [ "login" ]: password AND u2f touch
#   hardwareFactor.rsshKeys           admin's sk- SSH login keys
#   hardwareFactor.u2fKeysFile        ./u2f-keys (pamu2fcfg output)
#   desktopU2f.enable          false  pam_u2f as an alternative to the
#                                     password (set by custom.yubikey.enable,
#                                     modules/system/yubikey.nix)
#
# Per service:
#
#   | Service          | Default (both off)        | hardwareFactor.enable          | desktopU2f.enable            |
#   |------------------|---------------------------|--------------------------------|------------------------------|
#   | sshd             | keys only (sshd.keysOnly) | same                           | same                         |
#   | Tailscale SSH    | tailnet identity, no PAM  | same (`login -f` skips auth)   | same                         |
#   | sudo             | admin's password          | rssh OR u2f, no password       | password OR u2f touch        |
#   | polkit-1         | admin's password          | rssh OR u2f, no password       | password OR u2f touch        |
#   | login (console)  | password                  | password AND u2f touch         | password OR u2f touch        |
#   | su               | password (root locked)    | unchanged                      | password OR u2f touch        |
#   | greeter/hyprlock | password (Famine)         | unchanged                      | password OR u2f touch        |
#
# "OR u2f" for desktopU2f is NixOS's security.pam.u2f.enable: a
# `sufficient` pam_u2f in EVERY PAM service, per-user mappings in
# ~/.config/Yubico/u2f_keys (origin pam://sortofasian). hardwareFactor and
# desktopU2f are exclusive.
#
# hardwareFactor: prerequisite: a SECOND FIDO2 key registered (u2f-keys
# must hold two credentials); with one key, losing it means no sudo and no
# console login on every host that has this on.
#
#   sudo, polkit-1:
#     auth sufficient /…/libpam_rssh.so …  # hw-rssh: forwarded ssh:admin key
#     auth sufficient /…/pam_u2f.so …      # hw-u2f: YubiKey on this host
#     auth required   /…/pam_deny.so       # deny (NixOS's own)
#   login:
#     auth required   /…/pam_u2f.so …      # hw-u2f
#     auth sufficient /…/pam_unix.so …     # unix (NixOS's own): password
#     auth required   /…/pam_deny.so       # deny (NixOS's own)
#
# In Linux-PAM `sufficient` ends the stack with success only if no earlier
# `required` module failed, so on login a failed touch denies even with the
# right password; on sudo pam_unix is out of the stack, so the password
# never helps. The assertions refuse any configuration where another
# module could change these stacks (another `sufficient` or jumping rule,
# pam_unix in the sudo stack, an overridden text, NOPASSWD sudo rules,
# sudo-rs).
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
    attrValues
    concatLines
    concatMap
    concatStringsSep
    drop
    elem
    filter
    genAttrs
    hasInfix
    hasPrefix
    imap0
    length
    mkEnableOption
    mkForce
    mkIf
    mkMerge
    mkOption
    optional
    sort
    splitString
    take
    trim
    types
    versionAtLeast
    ;

  cfg = config.custom.auth;
  hw = cfg.hardwareFactor;

  # One registration (pamu2fcfg -o/-i) is valid on every host only if the
  # origin and appid are the same everywhere.
  hwOrigin = "pam://neurosis";

  # Mapping lines of the u2f key file; `#` comments and blank lines dropped.
  u2fMappings = filter (l: l != "" && !(hasPrefix "#" l)) (
    map trim (splitString "\n" (builtins.readFile hw.u2fKeysFile))
  );
  # `admin:<KeyHandle>,<UserKey>,<CoseType>,<Options>[:<more keys>]`.
  u2fMappingValid = l: builtins.match "admin(:[^,:]+,[^,:]+,[^,:]+,[^:]*)+" l != null;
  u2fCredentials = l: length (splitString ":" l) - 1;

  # Root-owned, immutable files in the store (never a user-writable file:
  # admin could otherwise add its own keys).
  u2fAuthFile = pkgs.writeText "auth-u2f-keys" (concatLines u2fMappings);
  rsshKeyFile = pkgs.writeText "auth-rssh-keys" (concatLines hw.rsshKeys);

  # `cue` (a "touch the device" prompt) exists from pam_rssh 1.2.0 on; an
  # unknown option makes pam_rssh fail outright. The desktop pin carries
  # 1.2.0-rc2, which lacks it.
  rsshHasCue =
    versionAtLeast pkgs.pam_rssh.version "1.2.0" && !(hasInfix "-rc" pkgs.pam_rssh.version);

  rsshRule = order: {
    inherit order;
    control = "sufficient";
    modulePath = "${pkgs.pam_rssh}/lib/libpam_rssh.so";
    settings = {
      auth_key_file = "${rsshKeyFile}";
      cue = rsshHasCue;
    };
  };

  # Never `nouserok` or `alwaysok`: they turn a failed touch into
  # PAM_IGNORE or success.
  u2fRule = control: order: {
    inherit control order;
    modulePath = "${pkgs.pam_u2f}/lib/security/pam_u2f.so";
    settings = {
      authfile = "${u2fAuthFile}";
      origin = hwOrigin;
      appid = hwOrigin;
      cue = true;
      userpresence = 1;
    };
  };

  # Controls that can neither end the auth stack with success nor jump.
  harmlessControls = [
    "required"
    "requisite"
    "optional"
  ];

  # Built-in NixOS rules that would add another way in. Forced off on the
  # hardwareFactor services; the assertions catch any others.
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
  forceOff =
    names:
    genAttrs names (_: {
      enable = mkForce false;
    });

  # The enabled auth rules of a service, in file order.
  authRules =
    svc:
    sort (a: b: a.order < b.order) (
      filter (r: r.enable) (attrValues config.security.pam.services.${svc}.rules.auth)
    );
  showRules = rules: concatStringsSep ", " (map (r: "${r.name} (${r.control})") rules);

  # `expected`: the rules that must close the auth stack, in this order,
  # with these controls. Every rule before them must be harmless.
  checkStack =
    svc: expected:
    let
      rules = authRules svc;
      n = length rules;
      m = length expected;
      tail = drop (n - m) rules;
      tailOk =
        n >= m
        && all (x: x) (
          imap0 (
            i: e:
            let
              r = builtins.elemAt tail i;
            in
            r.name == e.name && r.control == e.control
          ) expected
        );
      bad = filter (r: !(elem r.control harmlessControls)) (take (n - m) rules);
    in
    [
      {
        assertion = tailOk;
        message = ''
          custom.auth: the auth stack of /etc/pam.d/${svc} must end with
          ${concatStringsSep ", " (map (e: "${e.name} (${e.control})") expected)}. Got:
          ${showRules rules}'';
      }
      {
        assertion = bad == [ ];
        message = ''
          custom.auth: /etc/pam.d/${svc} has auth rules that could let
          someone in another way: ${showRules bad}'';
      }
      {
        assertion = hasInfix "# hw-u2f" config.security.pam.services.${svc}.text;
        message = "custom.auth: security.pam.services.${svc}.text is overridden; the rules would not apply.";
      }
    ];

  checkSudoService =
    svc:
    checkStack svc [
      {
        name = "hw-rssh";
        control = "sufficient";
      }
      {
        name = "hw-u2f";
        control = "sufficient";
      }
      {
        name = "deny";
        control = "required";
      }
    ]
    ++ [
      {
        # No password path: pam_unix must not be in the auth stack at all.
        assertion = !(any (r: hasInfix "pam_unix" r.modulePath) (authRules svc));
        message = "custom.auth: pam_unix is in the auth stack of /etc/pam.d/${svc}; it must not accept the password.";
      }
    ];

  checkLoginService =
    svc:
    checkStack svc [
      {
        name = "hw-u2f";
        control = "required";
      }
      {
        name = "unix";
        control = "sufficient";
      }
      {
        name = "deny";
        control = "required";
      }
    ];

  sudoRulesNoPasswd = any (
    rule:
    rule.users != [ "root" ] && any (c: builtins.isAttrs c && (elem "NOPASSWD" c.options)) rule.commands
  ) config.security.sudo.extraRules;

  wheelUsers = map (u: u.name) (
    filter (u: elem "wheel" u.extraGroups) (attrValues config.users.users)
  );
in
{
  options.custom.auth = {
    sshd.keysOnly = mkOption {
      type = types.bool;
      default = true;
      description = ''
        sshd accepts keys only (no PasswordAuthentication, no
        KbdInteractiveAuthentication), wherever sshd runs. A leaked admin
        password must not give a shell over plain SSH. Tailscale SSH does
        not use sshd.
      '';
    };

    hardwareFactor = {
      enable = mkEnableOption ''
        hardware-key sudo and console login: sudo (and polkit) needs no
        password but the `ssh:admin` FIDO2 key through a forwarded
        ssh-agent (pam_rssh) or a touch on a YubiKey plugged into the host
        (pam_u2f); console login needs the password and that touch.
        Register a second FIDO2 key first and read docs/auth.md: a lost
        key locks sudo and the console out'';

      sudoServices = mkOption {
        type = types.listOf types.str;
        default = [ "sudo" ] ++ optional config.security.polkit.enable "polkit-1";
        defaultText = lib.literalExpression ''[ "sudo" ] ++ optional config.security.polkit.enable "polkit-1"'';
        description = ''
          PAM services that authenticate with one hardware factor and no
          password. polkit-1 is included where polkit runs (m2mini, Famine):
          polkit lets wheel become root (pkexec, run0) too.
        '';
      };

      loginServices = mkOption {
        type = types.listOf types.str;
        default = [ "login" ];
        description = ''
          PAM services that need admin's password AND a touch on a YubiKey
          plugged into the host: the local console (`login`).
        '';
      };

      rsshKeys = mkOption {
        type = types.listOf types.str;
        # admin's FIDO2 (sk-) SSH login keys, set in modules/system/admin.nix:
        # one place to replace a key. Plain keys are left out: a key that
        # needs no touch on the YubiKey would not be a hardware factor.
        default = filter (hasPrefix "sk-") config.users.users.admin.openssh.authorizedKeys.keys;
        defaultText = lib.literalExpression ''filter (hasPrefix "sk-") config.users.users.admin.openssh.authorizedKeys.keys'';
        description = ''
          Public keys (authorized_keys format) whose signature through the
          forwarded ssh-agent authenticates sudo. By default admin's FIDO2
          (`sk-`) SSH login keys (modules/system/admin.nix). Kept in a
          root-owned store file, never in a user-writable authorized_keys.
        '';
      };

      u2fKeysFile = mkOption {
        type = types.path;
        default = ./u2f-keys;
        description = ''
          pam_u2f mapping for admin (`pamu2fcfg -u admin -o pam://neurosis
          -i pam://neurosis` output plus the second key's `-n` output on the
          same line; public data). `#` lines are ignored. Enabling fails
          unless it holds one admin line with at least two credentials.
        '';
      };
    };

    desktopU2f.enable = mkEnableOption ''
      pam_u2f as an alternative to the password in every PAM service
      (NixOS's security.pam.u2f, origin pam://sortofasian, per-user
      mappings in ~/.config/Yubico/u2f_keys). Set by custom.yubikey.enable
      (modules/system/yubikey.nix), which also places the mapping'';
  };

  config = mkMerge [
    # ---- Always ----------------------------------------------------------
    {
      services.openssh.settings = mkIf cfg.sshd.keysOnly {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };

      # sudo for wheel (= admin) always authenticates through PAM: with
      # the hardware factor off that is admin's password, with it on the
      # key. NOPASSWD would skip PAM entirely.
      security.sudo.wheelNeedsPassword = true;
      assertions = [
        {
          assertion = config.security.sudo.wheelNeedsPassword;
          message = "custom.auth: sudo must authenticate wheel (admin) through PAM (wheelNeedsPassword).";
        }
        {
          assertion = !(hw.enable && cfg.desktopU2f.enable);
          message = "custom.auth: hardwareFactor and desktopU2f are exclusive (servers vs. desktop).";
        }
      ];
    }

    # ---- Desktop YubiKey (was modules/system/pam.nix) --------------------
    (mkIf cfg.desktopU2f.enable {
      security.pam = {
        u2f = {
          enable = true;
          settings.cue = true;
          settings.origin = "pam://sortofasian";
        };
        services.login.u2fAuth = true;
        services.sudo.u2fAuth = true;
      };
    })

    # ---- Hardware factor (servers) ---------------------------------------
    (mkIf hw.enable {
      security.pam.services = mkMerge [
        (genAttrs hw.sudoServices (svc: {
          rules.auth =
            let
              denyOrder = config.security.pam.services.${svc}.rules.auth.deny.order;
            in
            {
              hw-rssh = rsshRule (denyOrder - 2);
              hw-u2f = u2fRule "sufficient" (denyOrder - 1);
            }
            # No password: pam_unix out of the auth stack.
            // forceOff (
              builtinBypassRules
              ++ [
                "unix"
                "unix-early"
              ]
            );
        }))
        (genAttrs hw.loginServices (svc: {
          rules.auth = {
            hw-u2f = u2fRule "required" (config.security.pam.services.${svc}.rules.auth.unix.order - 1);
          }
          // forceOff builtinBypassRules;
        }))
      ];

      # pam_rssh finds the agent through SSH_AUTH_SOCK; its README requires
      # keeping it for sudo.
      security.sudo.extraConfig = mkIf (elem "sudo" hw.sudoServices) ''
        # custom.auth.hardwareFactor: pam_rssh needs the forwarded agent's socket.
        Defaults env_keep+=SSH_AUTH_SOCK
      '';

      warnings =
        optional (length hw.rsshKeys < 2)
          "custom.auth.hardwareFactor: only ${toString (length hw.rsshKeys)} sk- key for pam_rssh; add the second FIDO2 key's ssh resident key to admin's authorized keys (modules/system/admin.nix) so sudo over SSH survives losing one key.";

      assertions = [
        {
          assertion =
            length u2fMappings == 1
            && all u2fMappingValid u2fMappings
            && u2fCredentials (lib.head u2fMappings) >= 2;
          message = ''
            custom.auth.hardwareFactor: u2fKeysFile (by default
            modules/system/auth/u2f-keys) must hold one
            `admin:<KeyHandle>,<UserKey>,<CoseType>,<Options>:<second key>`
            line with at least TWO credentials. Register both keys first
            (docs/auth.md, "Registering the keys"):
              pamu2fcfg -u admin -o ${hwOrigin} -i ${hwOrigin}
              pamu2fcfg -n -o ${hwOrigin} -i ${hwOrigin}'';
        }
        {
          assertion = hw.rsshKeys != [ ];
          message = "custom.auth.hardwareFactor: rsshKeys is empty (by default admin's sk- keys in users.users.admin.openssh.authorizedKeys.keys, modules/system/admin.nix).";
        }
        {
          # The u2f mapping and the agent keys are admin's; another wheel
          # account (charlie in stage 1 of his removal) could not sudo.
          assertion = wheelUsers == [ "admin" ];
          message = "custom.auth.hardwareFactor: admin must be the only wheel account (got: ${concatStringsSep ", " wheelUsers}).";
        }
        {
          assertion = !(any (s: elem s hw.loginServices) hw.sudoServices);
          message = "custom.auth.hardwareFactor: a PAM service cannot be in both sudoServices and loginServices.";
        }
        {
          assertion =
            !(elem "sudo" hw.sudoServices) || (config.security.sudo.enable && !config.security.sudo-rs.enable);
          message = "custom.auth.hardwareFactor: written for sudo (security.sudo), not sudo-rs.";
        }
        {
          # sudo still authenticates through PAM (it just asks no password);
          # NOPASSWD or !authenticate would skip PAM and with it the key.
          assertion =
            !sudoRulesNoPasswd
            && !(hasInfix "NOPASSWD" config.security.sudo.extraConfig)
            && !(hasInfix "!authenticate" config.security.sudo.extraConfig);
          message = "custom.auth.hardwareFactor: a sudo rule skips authentication (NOPASSWD or !authenticate).";
        }
      ]
      ++ concatMap checkSudoService hw.sudoServices
      ++ concatMap checkLoginService hw.loginServices;
    })
  ];
}
