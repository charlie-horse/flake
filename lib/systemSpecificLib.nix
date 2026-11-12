{ inputs, lib, ... }@args:
let
  inherit (builtins)
    listToAttrs
    ;
in
{
  systemSpecificLib =
    lib:
    listToAttrs (
      map
        (system: {
          name = system;
          value = lib (
            args
            // {
              inherit system;
              # Desktop-side pkgs (mkHost / mkHostIso); mkServer
              # never uses it.
              pkgs = import inputs.nixpkgs-unstable {
                inherit system;
                config.allowUnfree = true;
              };
            }
          );
        })
        [
          "aarch64-linux"
          "x86_64-linux"
        ]
    );
}
