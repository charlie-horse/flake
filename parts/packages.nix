# Per-system packages and apps.
#
# cluster-pki uses inputs.nixpkgs (nixos-26.05, what the nodes run). The
# k8s render is not here: it is the system-independent output `k8s`
# (parts/k8s.nix). The desktop ISOs come from the flake lib
# (nixpkgs-unstable, see parts/hosts.nix).
{ inputs, config, ... }: {
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      # Operator-side PKI tool (docs/pki.md).
      pki = pkgs.callPackage ../pkgs/cluster-pki {
        definition = import ../cluster/definition.nix;
      };
    in
    {
      # `nix fmt`: RFC-style nixfmt over the tracked .nix files (checks.yml
      # runs it with --check, excluding only hosts/Pestilence/servarr.nix).
      formatter = pkgs.nixfmt;

      packages = {
        cluster-pki = pki;
      }
      # Installer ISOs for the desktop hosts (lib/system/mkHost.nix).
      // (config.flake.lib.system.${system}.mkHostIso "Famine").${system}
      // (config.flake.lib.system.${system}.mkHostIso "Pestilence").${system};

      # nix run .#cluster-pki             -> ./pki-out (CAs + leaves)
      # nix run .#cluster-pki-deploy -- <node>  (stage + print sudo cmds)
      apps = {
        cluster-pki = {
          type = "app";
          program = "${pki}/bin/cluster-pki";
        };
        cluster-pki-deploy = {
          type = "app";
          program = "${pki}/bin/cluster-pki-deploy";
        };
      };
    };
}
