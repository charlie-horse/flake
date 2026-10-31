{ lib, ... }:
{
    # Ported from m2mini:/etc/nixos/m2mini.nix. The apple-silicon module is
    # imported by the flake (inputs.apple-silicon-m2mini), the peripheral
    # firmware is handled in ./firmware.nix.
    hardware.asahi = {
        enable = true;
        avd.enable = false;
    };

    networking.hostName = "m2mini";
    networking.networkmanager.enable = false;

    time.timeZone = lib.mkDefault "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";

    # With mutableUsers = true, NixOS only applies a declared password when it
    # CREATES the user; the existing account keeps its /etc/shadow entry
    # (update-users-groups.pl), so this has no effect on the running box.
    #
    # The previous config had a plaintext `password = "...";` here. It is
    # gone on purpose: never put it back, in any form.
    # TODO(user): for a fresh install, create the hash file first (outside
    # git and outside the Nix store), e.g. on m2mini:
    #   mkpasswd -m yescrypt | sudo install -D -m 0600 /dev/stdin \
    #       /var/lib/secrets/charlie.passwd
    # (mkpasswd is in nixpkgs#mkpasswd and prompts for the password.)
    # If the file is missing, activation only prints a warning.
    users.mutableUsers = true;
    users.users.charlie = {
        uid = 1000;
        name = "charlie";
        group = "users";
        isNormalUser = true;
        extraGroups = ["wheel" "dialout" ];
        hashedPasswordFile = "/var/lib/secrets/charlie.passwd";
    };

    services.openssh.enable = true;
    networking.firewall.allowedTCPPorts = [
        22
    ];

    services.tailscale.enable = true;
    # net.ipv4.ip_forward = 1 comes from the kubelet module (modules/cluster).
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    systemd.services.tailscaled.serviceConfig.Environment = [
        "TS_DEBUG_FIREWALL_MODE=nftables"
    ];

    system.stateVersion = "26.05";
}
