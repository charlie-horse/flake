{ lib, ... }: let
    modules = dir: lib.flatten (builtins.filter (v : v != null)
    (lib.mapAttrsToList
        (file: type: let path = "${dir}/${file}"; in
            if type == "directory"
                then if lib.pathExists "${path}/default.nix"
                    then path
                    else modules path
            else if type == "regular"
            && file != "default.nix"
            && lib.hasSuffix ".nix" file
                then path
            else null
        )
        (builtins.readDir dir)
    ));
    # modules/cluster is server-only: lib/system/mkServer.nix imports it for
    # c4130/r440/m2mini. The mkHost hosts (which import this file) must not
    # get it.
    serverOnly = [ "${./.}/cluster" ];
in { imports = builtins.filter (p: !(builtins.elem p serverOnly)) (modules ./.); }
