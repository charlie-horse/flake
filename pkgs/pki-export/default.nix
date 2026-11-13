{
  lib,
  writeShellApplication,
  dockerTools,
  kubectl,
  sops,
  age-plugin-yubikey,
  yq-go,
  jq,
  gitMinimal,
  curl,
  cacert,
  openssl,
  coreutils,
  diffutils,
  gnused,
  gnugrep,
}:
let
  pki-export = writeShellApplication {
    name = "pki-export";
    runtimeInputs = [
      kubectl
      sops
      # Encrypting to an age1yubikey1... recipient runs the plugin (no card needed).
      age-plugin-yubikey
      yq-go
      jq
      gitMinimal
      curl
      openssl
      coreutils
      diffutils # cmp
      gnused
      gnugrep
    ];
    text = builtins.readFile ./pki-export.sh;
  };

  # The root fs is read-only: $HOME and $TMPDIR are the pod's memory-backed /tmp.
  image = dockerTools.streamLayeredImage {
    name = "pki-export";
    tag = "latest";
    contents = [ dockerTools.caCertificates ];
    config = {
      Entrypoint = [ (lib.getExe pki-export) ];
      User = "65532:65532";
      Env = [
        "HOME=/tmp"
        "TMPDIR=/tmp"
        "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
pki-export.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit image;
  };
})
