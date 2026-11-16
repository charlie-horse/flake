# Per-system packages. The k8s render is the system-independent output `k8s`
# (parts/k8s.nix); the desktop ISOs come from the flake lib (parts/hosts.nix).
{ inputs, config, ... }: {
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      pkiTools = pkgs.callPackage ../pkgs/pki-tools {
        leaves = import ../k8s/components/infra/cluster-pki/leaves.nix {
          inherit (pkgs) lib;
          cluster = import ../cluster/definition.nix;
        };
      };
    in
    {
      # `nix fmt`: RFC-style nixfmt (the `format` check, parts/checks.nix).
      formatter = pkgs.nixfmt;

      # pytest runs in pki-tools' checkPhase.
      checks.pki-tools = pkiTools;

      packages = {
        # YubiKey root-CA ceremony tools, entered ad hoc wherever the card is
        # plugged in (`nix shell .#ca-ceremony-tools`; docs/pki.md).
        ca-ceremony-tools = pkgs.callPackage ../pkgs/ca-ceremony-tools { };
        pki-export = pkiTools;
        pki-export-image = pkiTools.image;
      }
      # Installer ISO for the desktop host (lib/system/mkHost.nix).
      // (config.flake.lib.system.${system}.mkHostIso "Famine").${system};
    };
}
