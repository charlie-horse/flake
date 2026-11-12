{ pkgs, ... }: {
  copyDir = dir: pkgs.runCommand (baseNameOf dir) { inherit dir; } "mkdir $out; cp -r $dir/* $out";
}
