# pki-export: the phase-2 export job (docs/pki-migration-plan.md, P2).
# Reads the host leaves cert-manager issued in namespace `cluster-pki`,
# writes secrets/pki/<node>.yaml (certs plaintext, keys sops-encrypted to
# the public recipients in .sops.yaml) and opens a PR. See ./pki-export.sh.
#
#   nix build .#pki-export          the script (runs anywhere: --from-dir,
#                                   --dry-run)
#   nix build .#pki-export-image    the OCI image the CronJob runs
#                                   (k8s/components/infra/cluster-pki/
#                                   export.nix), a `docker-archive` stream:
#                                   ./result | skopeo copy docker-archive:/dev/stdin ...
#                                   (.github/workflows/pki-export-image.yml)
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
  gnused,
  gnugrep,
}:
let
  pki-export = writeShellApplication {
    name = "pki-export";
    runtimeInputs = [
      kubectl
      sops
      # Encrypting to the admin YubiKey's age recipient
      # (age1yubikey1...) runs the plugin; it needs no card for that.
      age-plugin-yubikey
      yq-go
      jq
      gitMinimal
      curl
      openssl
      coreutils
      gnused
      gnugrep
    ];
    text = builtins.readFile ./pki-export.sh;
  };

  # Runs as 65532 with a read-only root filesystem: $HOME and $TMPDIR are
  # the pod's emptyDir at /tmp (memory-backed: the private keys pass
  # through it in plaintext). No shell entrypoint besides the script's own
  # bash; no age identity anywhere in the image.
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
