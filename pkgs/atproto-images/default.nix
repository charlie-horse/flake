# OCI images of the ATProto services (k8s/components/apps/atproto/), built
# from upstream sources and pushed to GHCR by
# .github/workflows/atproto-images.yml. Name -> streamLayeredImage script.
# pkgsUnstable: nixpkgs-unstable, for the Rust toolchain these need.
{ pkgs, pkgsUnstable }:
import ./tranquil-pds.nix { inherit pkgs pkgsUnstable; }
// import ./tangled-knot.nix { inherit pkgs pkgsUnstable; }
// import ./atcr.nix { inherit pkgs; }
