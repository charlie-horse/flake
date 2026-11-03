{ lib, config, ... }: let
    inherit (lib)
        mkIf
        types
        mkOption;
    inherit (lib.custom)
        switch;
    inherit (config.custom)
        cpu
        user
        virtualisation;
in {
    options.custom.virtualisation.enable = mkOption {
        type = types.bool;
        default = false;
    };

    config = mkIf virtualisation.enable {
        boot.kernelModules = [(switch
            cpu
            (v: c: v == c)
            { amd = "kvm-amd"; intel = "kvm-intel"; }
        )];
        virtualisation.virtualbox.host.enable = true;
        users.extraGroups.vboxusers.members = [ user.name ];
    };
}
