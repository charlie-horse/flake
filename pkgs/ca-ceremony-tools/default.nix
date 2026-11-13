# ca-ceremony-tools: everything the YubiKey root-CA ceremony needs
# (docs/pki-migration-plan.md, nodes A and F), as one package to enter ad
# hoc. No host installs any of it and no host runs pcscd permanently
# (docs/cluster.md, "Secrets (all of them)"), so the ceremony needs no
# switch. On c4130, as admin:
#
#   sudo -i                                  # pcscd and its clients run as root
#   nix shell /etc/nixos#ca-ceremony-tools
#   ca-pcscd &                               # temporary pcscd, exits when idle
#   ykman info; ykman piv info
#   step certificate create ... --kms 'yubikey:' --key 'yubikey:slot-id=9c'
#   ca-openssl x509 -req -provider pkcs11 -provider default \
#     -key 'pkcs11:object=Private key for Digital Signature' ...
#
# Contents (bin/ is what matters):
#   ykman             yubikey-manager
#   yubico-piv-tool   plus lib/libykcs11.so (ykcs11, the PKCS#11 module)
#   step              step-cli; finds `step-kms-plugin` on PATH, which this
#   step-kms-plugin   package puts next to it
#   openssl           plus lib/ossl-modules/pkcs11.so (pkcs11-provider)
#   pcscd             pcsclite; ccid's reader driver for ca-pcscd
#   ca-pcscd          pcscd the documented ad-hoc way:
#                     PCSCLITE_HP_DROPDIR=<ccid>/pcsc/drivers
#                     pcscd --foreground --auto-exit
#   ca-openssl        openssl with OPENSSL_MODULES=<pkcs11-provider> and
#                     PKCS11_PROVIDER_MODULE=<libykcs11.so>, for that
#                     process only (no openssl.cnf anywhere is changed)
#
# The admin YubiKey's other uses (sops age identity in PIV slot 82, FIDO2
# ssh:admin and pam_u2f) are untouched: nothing here writes to the card by
# itself, and FIDO2 goes over HID, not PC/SC.
{
  lib,
  symlinkJoin,
  writeShellApplication,
  yubikey-manager,
  yubico-piv-tool,
  step-cli,
  step-kms-plugin,
  openssl,
  pkcs11-provider,
  pcsclite,
  ccid,
  procps,
}:
let
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
in
symlinkJoin {
  name = "ca-ceremony-tools";
  paths = [
    yubikey-manager
    yubico-piv-tool
    step-cli
    step-kms-plugin
    openssl
    pkcs11-provider
    pcsclite
    ca-pcscd
    ca-openssl
  ];
  meta = {
    description = "YubiKey PIV root-CA ceremony tools (ykman, step + step-kms-plugin, openssl + pkcs11-provider, ad-hoc pcscd)";
    platforms = lib.platforms.linux;
  };
}
