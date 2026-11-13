# Editing sops secrets on c4130 itself, with a YubiKey plugged into c4130
# and charlie logged in over SSH:
#   - PIV (age-plugin-yubikey, the admin recipient in .sops.yaml): goes
#     through pcscd. pcsc-lite's polkit policy only allows *active local*
#     sessions (allow_active), so the rule below lets wheel use it from
#     non-local (SSH) sessions too.
#   - FIDO2 (`ssh-keygen -K`, ed25519-sk keys): libfido2 opens the hidraw
#     device directly; udev's uaccess tag only covers local seats, so wheel
#     gets the YubiKey's hidraw nodes as a group.
#
# One-time, as charlie: `age-plugin-yubikey --identity >
# ~/.config/sops/age/keys.txt` (the identity stub is not secret; the key
# stays on the YubiKey), then `sops secrets/c4130.yaml` (touch the key
# when it blinks).
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    sops
    age
    age-plugin-yubikey
    yubikey-manager
  ];

  services.pcscd.enable = true;
  # The pcscd module runs pcscliteWithPolkit (pcsclite built with
  # -Dpolkit=true; prebuilt on cache.nixos.org for 26.05) only when polkit
  # is on; without polkit, pcscd lets every local user at the card.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    // pcscd over SSH for wheel (hosts/c4130/yubikey.nix).
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.debian.pcsc-lite.access_pcsc" ||
           action.id == "org.debian.pcsc-lite.access_card") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';

  # Yubico's USB vendor id 1050: every YubiKey hidraw interface (FIDO and
  # OTP), wheel read/write.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", GROUP="wheel", MODE="0660"
  '';
}
