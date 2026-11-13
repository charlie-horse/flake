# The render mechanics behind k8s/default.nix: evaluates every registered
# component with catenix, lays the result out as a tree of YAML files and
# builds the image check. k8s/default.nix holds the registry (what is
# rendered) and passes it here; nothing in this file names a component.
#
# Arguments:
#   inputs, pkgs, lib   as given to k8s/default.nix
#   cluster             cluster/definition.nix, evaluated
#   kubeVersion         `helm template --kube-version` for the charts
#   components          component name -> module
#   deferred            { dir, modules, secrets }: deferred components,
#                       rendered under <dir>/, and the sops-encrypted
#                       Secrets ({ name, src }), copied verbatim to
#                       <dir>/<secrets.name>/ (k8s/default.nix,
#                       k8s/README.md)
#
# Returns { manifests, checkImages, components } (k8s/default.nix
# describes them).
{
  inputs,
  pkgs,
  lib,
  cluster,
  kubeVersion,
  components,
  deferred,
}:
let
  catenix = inputs.catenix;

  # Names of the deferred components, as the components see them (the
  # `deferred` module argument; components/flux/stages.nix).
  deferredComponents = lib.attrNames deferred.modules;

  # sops-encrypted Secrets: <src>/<namespace>/<name>.sops.yaml, nothing
  # else. Never evaluated or re-serialised (the sops MAC covers the values
  # as written): `manifests` copies each file as is, after checking that it
  # is one encrypted Secret named after its path.
  secretsDir = "${deferred.dir}/${deferred.secrets.name}";
  dnsLabel = "[a-z0-9]([-a-z0-9]*[a-z0-9])?";
  secretFiles =
    let
      src = deferred.secrets.src;
      prefix = toString src + "/";
    in
    lib.optionals (builtins.pathExists src) (
      map (
        source:
        let
          rel = lib.removePrefix prefix (toString source);
          parts = builtins.match "(${dnsLabel})/(${dnsLabel}(\\.${dnsLabel})*)\\.sops\\.yaml" rel;
        in
        assert lib.assertMsg (
          parts != null
        ) "k8s render: ${rel} in the secrets directory is not <namespace>/<name>.sops.yaml";
        rec {
          # (match groups: dnsLabel has one of its own, so the name is 2)
          namespace = lib.elemAt parts 0;
          name = lib.elemAt parts 2;
          path = "${secretsDir}/${rel}";
          # This file alone, not the whole flake source it sits in.
          file = builtins.path {
            path = source;
            name = "${namespace}-${name}.sops.yaml";
          };
        }
      ) (lib.filesystem.listFilesRecursive src)
    );

  # Every component is a catenix configuration of its own. Module arguments:
  # cluster, kubeVersion, deferred ({ dir, components }), catenix (its lib),
  # k8sLib (./lib.nix), charts (./charts.nix), pkgs.
  evalComponent =
    module:
    lib.evalModules {
      modules = [
        catenix.nixosModules.default
        module
      ];
      specialArgs = {
        inherit pkgs cluster kubeVersion;
        deferred = {
          inherit (deferred) dir;
          components = deferredComponents;
          # components/flux/secrets.nix: the Kustomization exists only
          # while there is at least one Secret to apply.
          secrets = {
            inherit (deferred.secrets) name;
            path = secretsDir;
            enable = secretFiles != [ ];
          };
        };
        catenix = catenix.lib;
        k8sLib = import ./lib.nix { inherit lib cluster; };
        charts = import ./charts.nix { inherit pkgs catenix; };
      };
    };

  evaluated =
    assert lib.assertMsg (
      lib.intersectAttrs components deferred.modules == { }
    ) "k8s render: a component is both in `components` and in `deferred`";
    assert lib.assertMsg (
      !lib.any (n: n == deferred.dir || lib.hasPrefix "${deferred.dir}/" n) (lib.attrNames components)
    ) "k8s render: no component may be named ${deferred.dir}[/...]";
    assert lib.assertMsg (lib.allUnique (
      map baseNameOf deferredComponents
    )) "k8s render: deferred components need distinct last path elements (their Kustomization names)";
    assert lib.assertMsg
      (
        !lib.any (
          n:
          n == deferred.secrets.name
          || lib.hasPrefix "${deferred.secrets.name}/" n
          || baseNameOf n == deferred.secrets.name
        ) deferredComponents
      )
      "k8s render: no deferred component may be named ${deferred.secrets.name}[/...] or end in /${deferred.secrets.name} (the secrets Kustomization)";
    lib.mapAttrs (_: evalComponent) (components // deferred.modules);

  # A component's directory in the render.
  renderPath = name: if deferred.modules ? ${name} then "${deferred.dir}/${name}" else name;

  # <dir>/kustomization.yaml: an empty kustomize base. Flux's generated
  # kustomization for `flux-system` takes <dir> as one (empty) resource and
  # does not descend into it. (Its text names k8s/default.nix, the render's
  # entry point; changing it would change the render's store path.)
  deferredFence = pkgs.writeText "kustomization.yaml" ''
    # Generated by k8s/default.nix; do not edit. Keeps the Kustomization
    # flux-system (path ./) out of this directory: each component below is
    # applied by its own Kustomization (k8s/components/flux/stages.nix).
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: []
  '';

  header = name: kind: ''
    # Generated from k8s/components (catenix); do not edit, change the Nix
    # source. Component: ${name}, kind: ${kind}
  '';

  # Lower-case plural of a kind, as kubectl names resources: Deployment ->
  # deployments, NetworkPolicy -> networkpolicies, Ingress -> ingresses.
  plural =
    kind:
    let
      k = lib.toLower kind;
    in
    if lib.hasSuffix "y" k then
      lib.removeSuffix "y" k + "ies"
    else if lib.hasSuffix "s" k then
      k + "es"
    else
      k + "s";

  # One file per kind and component, named by the plural: e.g.
  # apps/authentik/deployments.yaml (namespaces and CRDs get a 00-/01-
  # prefix, see below). (Never the singular: Flux's Kustomization
  # kind would become kustomization.yaml, the file name kustomize reserves
  # for its own config, which would break Flux's build of the artifact.)
  # Each is rendered like a whole component (catenix's toYaml: namespaces,
  # then CRDs, then the rest).
  componentFiles =
    name: config:
    lib.mapAttrsToList (
      kind: objects:
      let
        # Namespaces and CRDs sort first, so `kubectl apply -R` (which walks
        # files alphabetically) creates them before what needs them.
        prefix =
          {
            Namespace = "00-";
            CustomResourceDefinition = "01-";
          }
          .${kind} or "";
        file = "${prefix}${plural kind}.yaml";
      in
      assert lib.assertMsg (
        !lib.elem file [
          "kustomization.yaml"
          "kustomization.yml"
        ]
      ) "k8s render: ${name}/${file} is a name kustomize reserves";
      {
        path = "${renderPath name}/${file}";
        header = header name kind;
        yaml = catenix.lib.render.toYaml pkgs objects;
      }
    ) (lib.groupBy (m: m.kind) config.config.build.manifests);

  # Checks one sops-encrypted Secret (read only; the file is copied as is):
  # a single v1 Secret whose namespace and name match its path, only the
  # usual Secret fields, every data/stringData value encrypted, sops
  # metadata with an age recipient and a MAC, encrypted_regex
  # ^(data|stringData)$ (so metadata stays readable for kustomize and Flux),
  # keys sorted.
  checkSecret = pkgs.writeShellScript "check-sops-secret" ''
    set -euo pipefail
    file=$1 namespace=$2 name=$3
    yq=${lib.getExe pkgs.yq-go}
    fail() {
      echo "k8s render: secrets/$namespace/$name.sops.yaml: $*" >&2
      exit 1
    }
    [ "$($yq ea '[.] | length' "$file")" = 1 ] || fail "not exactly one YAML document"
    check() { $yq -e "$1" "$file" >/dev/null 2>&1 || fail "$2"; }
    check '.apiVersion == "v1" and .kind == "Secret"' "not a v1 Secret"
    check ".metadata.namespace == \"$namespace\" and .metadata.name == \"$name\"" \
      "metadata.namespace/name must be $namespace/$name (its path)"
    check '(keys - ["apiVersion", "kind", "metadata", "type", "immutable", "data", "stringData", "sops"]) | length == 0' \
      "unexpected top-level field (allowed: apiVersion kind metadata type immutable data stringData sops)"
    check '[(.data // {})[], (.stringData // {})[]] | length > 0' "no data or stringData"
    check '[(.data // {})[], (.stringData // {})[]] | all_c(tag == "!!str" and test("^ENC\\[AES256_GCM,"))' \
      "a data/stringData value is not sops-encrypted"
    check '.sops.mac | test("^ENC\\[AES256_GCM,")' "no sops MAC (not encrypted with sops?)"
    check '(.sops.age // []) | length > 0' "no age recipient"
    check '.sops.encrypted_regex == "^(data|stringData)$"' \
      "sops.encrypted_regex must be ^(data|stringData)$ (.sops.yaml creation rule)"
    # The MAC covers every value (encrypted or not) in document order, and
    # kustomize re-serialises with keys sorted (kustomize-controller
    # decrypts after its build): a file whose keys were not sorted when it
    # was encrypted fails with "MAC mismatch". Encrypt only key-sorted files
    # (yq -i 'sort_keys(..)'; k8s/README.md, "Secrets").
    [ "$($yq 'del(.sops)' "$file")" = "$($yq 'del(.sops) | sort_keys(..)' "$file")" ] \
      || fail "keys not sorted (sort with yq 'sort_keys(..)' BEFORE encrypting, then re-encrypt)"
  '';

  # The tree: every component's files, the deferred fence and the
  # encrypted Secrets (checked, then copied byte for byte).
  manifests = pkgs.runCommand "k8s-manifests" { } (
    lib.concatMapStrings (f: ''
      mkdir -p "$(dirname "$out/${f.path}")"
      {
        cat ${pkgs.writeText "header" f.header}
        cat ${f.yaml}
      } > "$out/${f.path}"
    '') (lib.concatLists (lib.mapAttrsToList componentFiles evaluated))
    + ''
      mkdir -p "$out/${deferred.dir}"
      cp ${deferredFence} "$out/${deferred.dir}/kustomization.yaml"
    ''
    + lib.concatMapStrings (s: ''
      ${checkSecret} ${s.file} ${s.namespace} ${s.name}
      install -D -m 0444 ${s.file} "$out/${s.path}"
    '') secretFiles
  );

  # Every image in the tree must be a manifest list with linux/amd64 and
  # linux/arm64 (network; not sandboxed).
  checkImages = pkgs.writeShellApplication {
    name = "k8s-check-images";
    runtimeInputs = [
      pkgs.crane
      pkgs.jq
      pkgs.yq-go
      pkgs.gnugrep
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      # Images pinned to the gpu node (x86_64 only) are exempt.
      single_arch='^nvcr\.io/nvidia/k8s-device-plugin:'
      status=0
      images=$(find ${manifests} -name '*.yaml' -exec yq -N '.. | select(has("image")) | .image' {} + \
        | sort -u)
      for image in $images; do
        platforms=$(crane manifest "$image" \
          | jq -r '[.manifests[]?.platform | select(.os != "unknown")
                   | "\(.os)/\(.architecture)"]
                   | join(" ")')
        if echo "$platforms" | grep -q 'linux/amd64' \
          && echo "$platforms" | grep -q 'linux/arm64'; then
          echo "ok      $image ($platforms)"
        elif echo "$image" | grep -qE "$single_arch"; then
          echo "pinned  $image ($platforms)"
        else
          echo "MISSING $image ($platforms)" >&2
          status=1
        fi
      done
      exit "$status"
    '';
  };
in
{
  inherit manifests checkImages;
  components = evaluated;
}
