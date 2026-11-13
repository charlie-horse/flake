# charlie on every server (c4130, r440, m2mini). Formerly identical
# users.users.charlie blocks in each hosts/<host>/configuration.nix;
# host-specific bits (m2mini: uid, dialout, fish) stay in the host.
#
# charlie is an unprivileged login: not in wheel, no password (no password
# login possible; SSH key logins, including Tailscale SSH, still work).
# Administration goes through `admin` (modules/system/admin.nix).
{ pkgs, ... }:
{
  users.users.charlie = {
    isNormalUser = true;
    # "*": no password can match, but the account is not "locked" ("!"),
    # so sshd key logins work whatever its UsePAM setting; Tailscale SSH
    # does not look at the password at all.
    hashedPassword = "*";
    packages = with pkgs; [
    ];
  };
}
