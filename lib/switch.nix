{ lib, ... }:
let
  inherit (lib)
    filter
    findSingle
    mapAttrsToList
    ;
in
{
  # WARNING Don't use "null" as a return value as it is
  # used to filter out non-matching cases
  switch = (
    value: pred: cases:
    findSingle (_: true) (abort "No matching case") (abort "Multiple matching cases") (
      filter (v: v != "null") (
        mapAttrsToList (case: return: if (pred value case) then return else "null") cases
      )
    )
  );
}
