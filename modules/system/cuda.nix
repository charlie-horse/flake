{ lib, pkgs, config, ... }: let
    inherit (lib)
        mkIf
        types
        mkOption;
    inherit (config.custom)
        gpu;

in {
    options.custom.cuda.enable = mkOption {
        type = types.bool;
        default = false;
    };
    config = mkIf (gpu == "nvidia") {
        nix.settings = {
            substituters = [ "https://cuda-maintainers.cachix.org" ];
            trusted-public-keys = [(
                "cuda-maintainers.cachix.org-1:"
                + "0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
            )];
        };
        environment.systemPackages = with pkgs.cudaPackages; [
            cudatoolkit
        ];
    };
}
