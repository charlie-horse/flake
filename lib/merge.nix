{ lib, ... }: let
    inherit (lib)
        foldr;
    inherit (lib.attrsets)
        recursiveUpdate;
in {
    merge = sets: foldr (x: y: recursiveUpdate x y) {} sets;
}
