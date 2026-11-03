{ pkgs, lib, config, ... }: let
    inherit (lib)
        mkIf
        types
        mkMerge
        mkOption;
    inherit (config.custom)
        cpu;
in {
    options.custom.cpu = mkOption {
        type = types.nullOr (types.enum [ "amd" "intel" ]);
        default = null;
    };

    config = mkMerge [(mkIf (cpu != null) { hardware.cpu.${cpu}.updateMicrocode = true; })];
}
