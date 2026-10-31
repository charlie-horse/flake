{ pkgs, lib, modulesPath, config, inputs, ... }:
 {

    imports = [inputs.apple-silicon.nixosModules.default];

    nixpkgs.hostPlatform = "aarch64-linux";
    hardware.asahi.peripheralFirmwareDirectory = ./firmware;

    custom.user.name = "charlie";
    custom.age.enable = false;
    # String path, outside git and the store (see users.users.charlie).
    custom.user.passwordFile = "/var/lib/secrets/charlie.passwd";
    custom.neovim.enable = true;

    boot.zfs.forceImportRoot = false;
    boot.supportedFilesystems = ["zfs"];
    boot.zfs.extraPools = ["mutable"];
    networking.hostId = "3b82b05e";

    services.openssh.enable = true;

    users.mutableUsers = true;
    users.users.charlie = {
        uid = 1000;
        name = "charlie";
        group = "users";
        isNormalUser = true;
        extraGroups = ["wheel" "dialout" ];
        # Mutable password (users.mutableUsers = true): NixOS applies it only
        # when it CREATES the user, so the live shadow entry is untouched.
        # The plaintext that used to be here is public (git history of this
        # public repo) and is also the m2mini/charlie password: ROTATE it
        # (docs/cluster-handoff.md, "Secrets"). For a fresh install create
        # the hash first: mkpasswd -m yescrypt | sudo install -D -m 0600
        #   /dev/stdin /var/lib/secrets/charlie.passwd
        # hashedPasswordFile comes from custom.user.passwordFile (above).
    };
}
