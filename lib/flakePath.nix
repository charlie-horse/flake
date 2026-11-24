{ lib, ... }:
let
  inherit (builtins)
    path
    ;
in
{
  # The flake source as a named store path (https://nix.dev/anti-patterns).
  flakePath = path {
    path = ../.;
    name = "flake";
  };
}
