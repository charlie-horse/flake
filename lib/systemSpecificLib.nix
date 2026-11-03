{ inputs, lib, ...} @ args: let
    inherit (builtins)
        listToAttrs;
in {
    systemSpecificLib = lib: listToAttrs
        (map (system: {
                name = system;
                value = lib (args // {
                    inherit system;
                    pkgs = import inputs.nixpkgs {
                        inherit system;
                        config.allowUnfree = true;
                    };
                });
            })
        [
            "aarch64-linux"
            "x86_64-linux"
        ]);
}
