# cluster-pki / cluster-pki-deploy: operator-side PKI for the c4130/r440/m2mini
# cluster. See docs/pki.md.
#
#   pkgs.callPackage ./pkgs/cluster-pki {
#     definition = import ./cluster/definition.nix;
#   }
#
# `definition` is the pure-data cluster definition. Only the fields below are
# baked into the store (as JSON); nothing secret is ever in it.
{
  lib,
  writeShellApplication,
  writeText,
  symlinkJoin,
  cfssl,
  jq,
  openssl,
  openssh,
  gnutar,
  gnugrep,
  gnused,
  coreutils,
  git,
  definition,
}:
let
  d = definition;
  first = attrs: names: default:
    let hit = lib.findFirst (n: attrs ? ${n}) null names;
    in if hit == null then default else attrs.${hit};

  projected = {
    name = first d [ "name" "clusterName" ] "cluster";
    domain = first d [ "domain" "tailnetDomain" ] null;
    vip = first d [ "vip" "apiserverVIP" ] null;
    kubernetesServiceIP = first d [ "kubernetesServiceIP" ] "10.96.0.1";
    clusterDomain = first d [ "clusterDomain" ] "cluster.local";
    secretsDir = first d [ "secretsDir" ] "/var/lib/kubernetes/secrets";
    apiserverExtraSANs = first d [ "apiserverExtraSANs" ] [ ];
    nodes = lib.mapAttrs (name: n: {
      lanIP = first n [ "lanIP" "lanAddress" ] null;
      tailnetIP = first n [ "tailnetIP" "tailscaleIP" ] null;
      roles = n.roles or [ ];
      extraSANs = n.extraSANs or [ ];
      sshHost = n.sshHost or name;
    }) d.nodes;
  };

  definitionJSON = writeText "cluster-pki-definition.json"
    (builtins.toJSON projected);

  cluster-pki = writeShellApplication {
    name = "cluster-pki";
    runtimeInputs = [
      cfssl jq openssl openssh gnutar gnugrep gnused coreutils git
    ];
    text = ''
      : "''${CLUSTER_PKI_DEFINITION:=${definitionJSON}}"
      export CLUSTER_PKI_DEFINITION
    '' + builtins.readFile ./cluster-pki.sh;
  };

  cluster-pki-deploy = writeShellApplication {
    name = "cluster-pki-deploy";
    text = ''exec ${lib.getExe cluster-pki} deploy "$@"'';
  };
in
symlinkJoin {
  name = "cluster-pki";
  paths = [ cluster-pki cluster-pki-deploy ];
  passthru = {
    inherit cluster-pki cluster-pki-deploy definitionJSON;
  };
  meta.mainProgram = "cluster-pki";
}
