# Per-system packages and the dev shell (`nix develop`, or direnv via
# .envrc). The k8s render is the system-independent output `k8s`
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

      # Tools the procedures in docs/ use. The YubiKey root-CA tools stay in
      # `ca-ceremony-tools` (docs/pki.md).
      devShells.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          # secrets and the YubiKey
          sops
          age
          age-plugin-yubikey
          ssh-to-age
          yubikey-manager
          pam_u2f
          # cluster
          kubectl
          kubelogin-oidc
          fluxcd
          cloudflared
          # checks and inspection
          nixfmt
          actionlint
          shellcheck
          nix-diff
          jq
          yq-go
          openssl
        ];
      };

      packages = {
        # YubiKey root-CA ceremony tools, entered ad hoc wherever the card is
        # plugged in (`nix shell .#ca-ceremony-tools`; docs/pki.md).
        ca-ceremony-tools = pkgs.callPackage ../pkgs/ca-ceremony-tools { };
        pki-export = pkiTools;
        pki-export-image = pkiTools.image;
      }
      # <name>-image: the ATProto service images (pkgs/atproto-images).
      // pkgs.lib.mapAttrs' (n: v: pkgs.lib.nameValuePair "${n}-image" v) (
        import ../pkgs/atproto-images {
          inherit pkgs;
          pkgsUnstable = inputs.nixpkgs-unstable.legacyPackages.${system};
        }
      )
      # Installer ISO for the desktop host (lib/system/mkHost.nix).
      // (config.flake.lib.system.${system}.mkHostIso "Famine").${system};
    };
}
