# ca-ceremony-tools: everything the YubiKey root CA needs (ykman, ykcs11,
# step + step-kms-plugin, ca-pcscd, ca-ceremony = ./ceremony.sh, sops,
# age-plugin-yubikey, yq, softhsm for MODE=rehearsal, ca-openssl), as one
# package entered ad hoc with `nix shell <flake>#ca-ceremony-tools`. No host
# installs it or runs pcscd permanently.
# Usage and gotchas: docs/pki.md, "Tools: ca-ceremony-tools".
# Nothing here writes to the card by itself (slot 82 and FIDO2 untouched).
{
  lib,
  symlinkJoin,
  writeShellApplication,
  fetchFromGitHub,
  yubikey-manager,
  yubico-piv-tool,
  step-cli,
  step-kms-plugin,
  openssl,
  pkcs11-provider,
  pcsclite,
  ccid,
  procps,
  sops,
  age-plugin-yubikey,
  yq-go,
  softhsm,
  coreutils,
  diffutils,
  findutils,
  gnugrep,
  gnused,
  git,
}:
let
  # step-cli must be >= 0.31.0: older versions load the issuer certificate
  # of `step certificate sign --kms ...` through the KMS plugin, so a
  # root.pem file fails ("scheme is missing"). Builds 0.31.0 when nixpkgs
  # has an older one.
  step-cli' =
    if lib.versionAtLeast step-cli.version "0.31.0" then
      step-cli
    else
      step-cli.overrideAttrs (_: rec {
        version = "0.31.0";
        src = fetchFromGitHub {
          owner = "smallstep";
          repo = "cli";
          tag = "v${version}";
          hash = "sha256-v8insc/+vnc4JVNeHeF3UU+rYdNtMeQkdWxVc+vq7ms=";
          postFetch = ''
            rm -f $out/.VERSION
          '';
        };
        vendorHash = "sha256-UNrUy0aWl7w5SmlsxLpmx6WxI2AElHE6llAMLRLi0r0=";
        ldflags = [
          "-w"
          "-s"
          "-X=main.Version=${version}"
        ];
      });

  ca-pcscd = writeShellApplication {
    name = "ca-pcscd";
    runtimeInputs = [ procps ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "ca-pcscd: run as root (sudo -i first); the ykman/step/ca-openssl" >&2
        echo "  commands that use it must run as root too." >&2
        exit 1
      fi
      if pgrep -x pcscd >/dev/null; then
        echo "ca-pcscd: a pcscd is already running; use that one." >&2
        exit 1
      fi
      export PCSCLITE_HP_DROPDIR=${ccid}/pcsc/drivers
      exec ${lib.getExe pcsclite} --foreground --auto-exit "$@"
    '';
  };

  ca-openssl = writeShellApplication {
    name = "ca-openssl";
    text = ''
      export OPENSSL_MODULES=${pkcs11-provider}/lib/ossl-modules
      export PKCS11_PROVIDER_MODULE=${yubico-piv-tool}/lib/libykcs11.so
      exec ${lib.getExe openssl} "$@"
    '';
  };

  tools = [
    yubikey-manager
    yubico-piv-tool
    step-cli'
    step-kms-plugin
    openssl
    pkcs11-provider
    pcsclite
    sops
    age-plugin-yubikey
    yq-go
    softhsm
    ca-pcscd
    ca-openssl
  ];

  ca-ceremony = writeShellApplication {
    name = "ca-ceremony";
    runtimeInputs = tools ++ [
      coreutils
      diffutils
      findutils
      gnugrep
      gnused
      procps
      git
    ];
    # writeShellApplication adds its own shebang and `set -euo pipefail`.
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./ceremony.sh);
  };
in
symlinkJoin {
  name = "ca-ceremony-tools";
  paths = tools ++ [ ca-ceremony ];
  meta = {
    description = "YubiKey PIV root-CA ceremony tools (ykman, step + step-kms-plugin, openssl + pkcs11-provider, ad-hoc pcscd)";
    platforms = lib.platforms.linux;
  };
}
