{ lib, config, ... }: let
    inherit (lib)
        mkForce;
    user = config.users.users.charlie;
in {
    environment.variables.NIXPKGS_ALLOW_UNFREE = "1";

    nixpkgs.hostPlatform = "aarch64-linux";
    nixpkgs.config.allowUnfree = true;

    nix = {
        gc.automatic = true;
        settings = let users = [ "root" user.name ]; in {
            experimental-features = [ "flakes" "nix-command" ];
            auto-optimise-store = true;
            trusted-users = users;
            allowed-users = users;
        };
    };
}
