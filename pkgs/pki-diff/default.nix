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
