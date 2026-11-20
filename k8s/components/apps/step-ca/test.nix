# Flake check `step-ca`: unit tests (evaluation only) of ./ca-json.nix and
# custom.auth.sshCA (modules/system/auth/ssh-ca.nix). Fails listing every
# test whose result differs from its expectation.
{ pkgs, lib }:
let
  settings = import ./settings.nix;
  issuer = "https://auth.example${settings.issuerPath}";
  ca = import ./ca-json.nix { inherit lib settings issuer; };
  prov = lib.head ca.authority.provisioners;
  template = prov.options.ssh.template;

  # custom.auth.sshCA on its own, with the NixOS options it sets stubbed.
  sshCA =
    cfg:
    (lib.evalModules {
      modules = [
        ../../../../modules/system/auth/ssh-ca.nix
        {
          options = {
            services.openssh.settings = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; };
            users.users = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default.admin = { };
            };
          };
          config.custom.auth.sshCA = cfg;
        }
      ];
    }).config;
  failed = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);
  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDvKA6tlSWbJD7dhZHpNhm4CEjFhgvzsfEP6zA9V3DrI";
  ok = sshCA {
    enable = true;
    userCAKeys = [ key ];
    principals.admin = [ "ssh-admins" ];
  };

  results = lib.runTests {
    testProvisioner = {
      expr = {
        inherit (prov)
          type
          clientID
          clientSecret
          groups
          ;
        inherit (prov.claims) enableSSHCA disableRenewal;
        endpoint = prov.configurationEndpoint;
      };
      expected = {
        type = "OIDC";
        inherit (settings) clientID;
        clientSecret = "";
        groups = settings.sshGroups;
        enableSSHCA = true;
        disableRenewal = true;
        endpoint = "${issuer}.well-known/openid-configuration";
      };
    };
    testOnlyThisProvisionerSigns = {
      expr = [
        ca.authority.claims.enableSSHCA
        (lib.length ca.authority.provisioners)
        ca.db
      ];
      expected = [
        false
        1
        null
      ];
    };
    testDurations = {
      expr = [
        prov.claims.minUserSSHCertDuration
        prov.claims.defaultUserSSHCertDuration
        prov.claims.maxUserSSHCertDuration
      ];
      expected = [
        settings.durations.min
        settings.durations.default
        settings.durations.max
      ];
    };
    # Principals: token groups filtered by exactly sshGroups; requested
    # principals (.Principals) never used; only permit-pty.
    testTemplatePrincipals = {
      expr = {
        allowList = lib.hasInfix "(list ${lib.concatMapStringsSep " " builtins.toJSON settings.sshGroups})" template;
        fromGroups = lib.hasInfix "range .Token.groups" template;
        ignoresRequested = !(lib.hasInfix ".Principals" template);
        keyId = lib.hasInfix ''"keyId": {{ toJson .Token.preferred_username }}'' template;
        extensions = lib.hasInfix ''"extensions": {"permit-pty": ""}'' template;
      };
      expected = {
        allowList = true;
        fromGroups = true;
        ignoresRequested = true;
        keyId = true;
        extensions = true;
      };
    };
    testHostFiles = {
      expr = {
        settings = ok.services.openssh.settings;
        principals = ok.environment.etc."ssh/authorized_principals/admin".text;
        keys = ok.environment.etc."ssh/trusted_user_ca_keys".text;
        failed = failed ok;
      };
      expected = {
        settings = {
          TrustedUserCAKeys = "/etc/ssh/trusted_user_ca_keys";
          AuthorizedPrincipalsFile = "/etc/ssh/authorized_principals/%u";
        };
        principals = "ssh-admins\n";
        keys = "${key}\n";
        failed = [ ];
      };
    };
    testRefused = {
      expr = map (c: lib.length (failed (sshCA ({ enable = true; } // c)))) [
        { principals.admin = [ "ssh-admins" ]; } # no CA key
        {
          userCAKeys = [ key ];
          principals.root = [ "ssh-admins" ];
        }
        {
          userCAKeys = [ key ];
          principals.admin = [ ];
        }
        {
          userCAKeys = [ key ];
          principals.admin = [ "ssh admins" ];
        }
        {
          userCAKeys = [ key ];
          principals.nobody = [ "ssh-admins" ];
        }
      ];
      expected = [
        1
        2 # root also does not exist in the stub
        1
        1
        1
      ];
    };
  };
in
pkgs.runCommand "step-ca-unit" { } (
  if results == [ ] then
    "touch $out"
  else
    "echo ${lib.escapeShellArg (builtins.toJSON results)} >&2; exit 1"
)
