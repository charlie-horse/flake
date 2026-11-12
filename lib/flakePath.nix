{ lib, ... }:
let
  inherit (builtins)
    path
    ;
in
{
  # https://nix.dev/anti-patterns
  flakePath = path {
    path = ../.;
    name = "flake";
  };
}
