# step-ca's ca.json: SSH user CA only, one OIDC provisioner (authentik).
# A token's `groups` claim is checked against settings.sshGroups and those
# groups become the certificate's principals; the token's own principal
# requests are ignored. KeyID is the account name (sshd logs it).
# `paths` lets the flake check run the same config outside the cluster.
{
  lib,
  settings,
  issuer,
  paths ? {
    internalCA = "/internal-ca";
    userKey = "/ssh-user-ca/key";
  },
  address ? "127.0.0.1:${toString settings.caPort}",
}:
let
  quoted = lib.concatMapStringsSep " " builtins.toJSON settings.sshGroups;
  template = lib.concatStrings [
    "{"
    ''"type": {{ toJson .Type }}, ''
    ''"keyId": {{ toJson .Token.preferred_username }}, ''
    ''"principals": {{ $p := list }}{{ range .Token.groups }}{{ if has . (list ${quoted}) }}{{ $p = append $p . }}{{ end }}{{ end }}{{ toJson $p }}, ''
    ''"extensions": {"permit-pty": ""}, ''
    ''"criticalOptions": {}''
    "}"
  ];
in
{
  # X.509 is internal only: a self-signed cert-manager CA, root = intermediate.
  root = "${paths.internalCA}/ca.crt";
  crt = "${paths.internalCA}/tls.crt";
  key = "${paths.internalCA}/tls.key";
  inherit address;
  dnsNames = [
    "localhost"
    "127.0.0.1"
  ];
  # No database: one-time-token replay protection is in memory (one replica).
  db = null;
  logger.format = "json";
  ssh.userKey = paths.userKey;
  authority = {
    claims.enableSSHCA = false;
    provisioners = [
      {
        type = "OIDC";
        name = "authentik";
        clientID = settings.clientID;
        clientSecret = "";
        configurationEndpoint = "${issuer}.well-known/openid-configuration";
        groups = settings.sshGroups;
        claims = {
          enableSSHCA = true;
          disableRenewal = true;
          minUserSSHCertDuration = settings.durations.min;
          defaultUserSSHCertDuration = settings.durations.default;
          maxUserSSHCertDuration = settings.durations.max;
        };
        options.ssh.template = template;
      }
    ];
  };
}
