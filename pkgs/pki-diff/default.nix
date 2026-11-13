# pki-diff: compare one node's cluster-pki leaves with the cert-manager set
# (secrets/pki/<node>.yaml or a directory) for the same node. Phase 2 of
# docs/pki-migration-plan.md, node P5; the dry run (P7) runs it:
#
#   nix run .#pki-diff -- ~/.local/share/cluster-pki/neurosis secrets/pki/r440.yaml
#
# Reads only the plaintext certs; never decrypts anything.
{
  lib,
  writeShellApplication,
  openssl,
  yq-go,
  coreutils,
  gnugrep,
  gnused,
  gawk,
}:
writeShellApplication {
  name = "pki-diff";
  runtimeInputs = [
    openssl
    yq-go
    coreutils
    gnugrep
    gnused
    gawk
  ];
  # writeShellApplication adds its own shebang and `set -euo pipefail`.
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./pki-diff.sh);
  meta.description = "Compare cluster-pki leaves with cert-manager-issued certs for one node";
}
