# authentik blueprints (YAML with authentik's custom tags such as !Find and
# !KeyOf), one file per OIDC client under ./blueprints. They become one
# ConfigMap, one key per file; the chart mounts it into the worker
# (blueprints.configMaps in chart.nix), which applies each file on change and
# hourly.
#
# @NAME@ placeholders are filled in from cluster/definition.nix. Evaluation
# fails if one is left over, so a typo can't reach authentik.
{ lib, cluster, ... }:
let
  inherit (import ./settings.nix) namespace blueprintsConfigMap;

  placeholders = {
    "@HEADLAMP_HOST@" = cluster.headlamp.host;
    "@OPEN_WEBUI_HOST@" = cluster.openWebui.host;
  };

  fill =
    file:
    let
      text = lib.replaceStrings (lib.attrNames placeholders) (lib.attrValues placeholders) (
        builtins.readFile (./blueprints + "/${file}")
      );
      leftover = builtins.match ".*(@[A-Z_]+@).*" (lib.replaceStrings [ "\n" ] [ " " ] text);
    in
    if leftover != null then
      throw "authentik blueprint ${file}: unknown placeholder ${lib.head leftover}"
    else
      text;

  files = lib.attrNames (
    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".yaml" n) (builtins.readDir ./blueprints)
  );
in
{
  resources.core.v1.ConfigMap.${blueprintsConfigMap} = {
    metadata = { inherit namespace; };
    data = lib.genAttrs files fill;
  };
}
