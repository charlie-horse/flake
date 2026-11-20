# custom.auth.sshCA: sshd accepts OpenSSH user certificates from step-ca
# (k8s/components/apps/step-ca) for the accounts listed in `principals`.
# A certificate's principals are authentik group names; an account accepts
# a certificate that carries one of the principals listed for it. Accounts
# with no entry accept no certificate. Keys in authorized_keys are
# unaffected. Docs: docs/k8s/apps.md#step-ca
{ config, lib, ... }:
let
  inherit (lib)
    all
    attrNames
    concatLines
    filterAttrs
    hasPrefix
    mapAttrs'
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    types
    ;
  cfg = config.custom.auth.sshCA;
  principalsDir = "ssh/authorized_principals";
  validPrincipal = p: builtins.match "[A-Za-z0-9._-]+" p != null;
in
{
  options.custom.auth.sshCA = {
    enable = mkEnableOption "OpenSSH user certificates signed by step-ca's SSH user CA";

    userCAKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Public keys of the SSH user CA (authorized_keys format, as step-ca's
        /ssh/roots serves them). More than one while the CA key rotates.
      '';
    };

    principals = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = {
        admin = [ "ssh-admins" ];
      };
      description = ''
        Account -> certificate principals (authentik groups) it accepts.
        Written to /etc/ssh/authorized_principals/<account>, root-owned.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.openssh.settings = {
      TrustedUserCAKeys = "/etc/ssh/trusted_user_ca_keys";
      AuthorizedPrincipalsFile = "/etc/${principalsDir}/%u";
    };

    environment.etc = {
      "ssh/trusted_user_ca_keys" = {
        text = concatLines cfg.userCAKeys;
        mode = "0444";
      };
    }
    // mapAttrs' (
      user: ps:
      nameValuePair "${principalsDir}/${user}" {
        text = concatLines ps;
        mode = "0444";
      }
    ) cfg.principals;

    assertions = [
      {
        assertion =
          cfg.userCAKeys != [ ] && all (k: hasPrefix "ssh-" k || hasPrefix "ecdsa-" k) cfg.userCAKeys;
        message = "custom.auth.sshCA: userCAKeys needs the CA's public key(s) in authorized_keys format.";
      }
      {
        assertion = !(cfg.principals ? root);
        message = "custom.auth.sshCA: root never accepts certificates (root is locked).";
      }
      {
        assertion = all (ps: ps != [ ] && all validPrincipal ps) (builtins.attrValues cfg.principals);
        message = "custom.auth.sshCA: each account needs at least one principal of [A-Za-z0-9._-].";
      }
      {
        assertion = attrNames (filterAttrs (u: _: !(config.users.users ? ${u})) cfg.principals) == [ ];
        message = "custom.auth.sshCA: principals names an account that does not exist.";
      }
    ];
  };
}
