{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkIf
    types
    mkOption
    ;
  inherit (config.custom)
    gpu
    ;

in
{
  options.custom.cuda.enable = mkOption {
    type = types.bool;
    default = false;
  };
  config = mkIf (gpu == "nvidia") {
    # nixpkgs' CUDA cache (modules/system/nix-cache.nix).
    custom.nixCache.cuda.enable = true;
    environment.systemPackages = with pkgs.cudaPackages; [
      cudatoolkit
    ];
  };
}
