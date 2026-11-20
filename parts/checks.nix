# `nix flake check` is the gate for every commit (CLAUDE.md). Every check
# goes here, not in CI steps (docs/ci.md).
{ inputs, ... }:
{
  perSystem =
    { system, self', ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      fs = lib.fileset;
      root = ../.;
    in
    {
      checks = {
        # Every sops file is fully encrypted, to its .sops.yaml recipients.
        sops =
          pkgs.runCommand "check-sops"
            {
              nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyyaml ])) ];
              src = fs.toSource {
                inherit root;
                fileset = fs.unions [
                  ../.sops.yaml
                  ../secrets
                  ../k8s/secrets
                ];
              };
            }
            ''
              python3 -I ${../scripts/check-sops.py} "$src"
              touch $out
            '';

        # Every .nix file is nixfmt-formatted (`nix fmt` fixes it).
        format =
          pkgs.runCommand "check-format"
            {
              nativeBuildInputs = [ pkgs.nixfmt ];
              src = fs.toSource {
                inherit root;
                fileset = fs.difference (fs.fileFilter (f: f.hasExt "nix") root) ../hosts/Pestilence/servarr.nix;
              };
            }
            ''
              cd "$src"
              find . -name '*.nix' -print0 | xargs -0 nixfmt --check
              touch $out
            '';

        # pki-tools (pytest runs in its checkPhase) and the image
        # pki-export-image.yml pushes from main.
        pki-tools = self'.packages.pki-export;
        pki-export-image = self'.packages.pki-export-image;

        # The k8s render with this system's nixpkgs: on x86_64-linux the same
        # derivation as `.#k8s.manifests` (parts/k8s.nix).
        k8s-render = (import ../k8s { inherit inputs pkgs lib; }).manifests;

        # The SSH certificate flow of apps/step-ca, end to end.
        step-ca = import ../k8s/components/apps/step-ca/test { inherit pkgs lib; };
      };
    };
}
