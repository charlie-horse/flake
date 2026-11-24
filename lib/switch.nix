{ lib, ... }:
let
  inherit (lib)
    filter
    findSingle
    mapAttrsToList
    ;
in
{
  # Never use the string "null" as a case's value: it marks non-matching
  # cases.
  switch = (
    value: pred: cases:
    findSingle (_: true) (abort "No matching case") (abort "Multiple matching cases") (
      filter (v: v != "null") (
        mapAttrsToList (case: return: if (pred value case) then return else "null") cases
      )
    )
  );
}
