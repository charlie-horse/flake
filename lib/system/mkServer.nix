{ lib, system, inputs, ... }: let
    inherit (builtins)
        baseNameOf
        isFunction;
    inherit (lib)
        mkDefault
        removeSuffix;
in {
    # Server host builder (c4130, r440, m2mini, ...).
    #
    # Unlike mkHost it does NOT import ../../modules wholesale (desktop,
    # home-manager, agenix, ...): a server gets only its host dir, the shared
    # cluster module (modules/cluster), the server baseline (modules/server:
    # git, cloudflared) and whatever `modules` adds.
    #
    #   mkServer {
    #       path = ./hosts/c4130;         # host dir (or file)
    #       nixpkgs = inputs.nixpkgs;     # per-host nixpkgs input (26.05)
    #       preModules = [ ... ];         # optional, imported BEFORE path
    #       modules = [ ... ];            # optional extra modules (after)
    #       specialArgs = { ... };        # optional extra specialArgs
    #   }
    #   => { c4130 = <nixosSystem>; }
    #
    # specialArgs always holds { inputs; cluster; hostName; } where cluster is
    # ./cluster/definition.nix (pure data; if it is a function it is called
    # with { lib; }). Extra args are passed per host via `specialArgs`.
    mkServer = {
        path,
        nixpkgs,
        name ? removeSuffix ".nix" (baseNameOf path),
        preModules ? [],
        modules ? [],
        specialArgs ? {},
    }: let
        definition = import ../../cluster/definition.nix;
        cluster =
            if isFunction definition
                then definition { lib = nixpkgs.lib; }
            else definition;
    in {
        ${name} = nixpkgs.lib.nixosSystem {
            specialArgs = {
                inherit inputs cluster;
                hostName = name;
            } // specialArgs;
            # Keep the order the host flake had (list options such as firewall
            # ports merge in import order): preModules (e.g. apple-silicon),
            # the host dir, then the cluster module, then extras.
            modules = preModules ++ [
                path
                ../../modules/cluster
                ../../modules/server
                {
                    networking.hostName = mkDefault name;
                    nixpkgs.hostPlatform = mkDefault system;
                }
            ] ++ modules;
        };
    };
}
