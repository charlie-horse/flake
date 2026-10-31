# Published Helm charts, pinned by version and NAR hash (catenix fetchChart:
# a fixed-output `helm pull --untar`). To bump one: change `version`, set
# `hash = lib.fakeHash`, build, and copy the hash Nix reports.
{ pkgs, catenix }:
let
  fetch = catenix.lib.fetchChart pkgs;
in
{
  # fluxcd-community chart; appVersion = Flux v2.9.5.
  flux2 = fetch {
    repo = "https://fluxcd-community.github.io/helm-charts";
    name = "flux2";
    version = "2.19.1";
    hash = "sha256-UH6MJ0/F2WhmLgTjuLNFa76/QFaTHbk6fkLnN1EIznM=";
  };

  # CoreDNS 1.14.7.
  coredns = fetch {
    repo = "https://coredns.github.io/helm";
    name = "coredns";
    version = "1.48.2";
    hash = "sha256-YOwfhBPSDwVCELGaCeS1Gpc/8ATzlcCD7iLc9IYXMFs=";
  };

  flannel = fetch {
    repo = "https://flannel-io.github.io/flannel";
    name = "flannel";
    version = "v0.28.10";
    hash = "sha256-HUhDWqsW02/HyMbBbbKIIAtKw7M7LmrAiWVHeCb5I+w=";
  };

  nvidia-device-plugin = fetch {
    repo = "https://nvidia.github.io/k8s-device-plugin";
    name = "nvidia-device-plugin";
    version = "0.20.1";
    hash = "sha256-zahn8zSCHlPguERweETGkcrZ43q39zPGZEiJzYtHyVw=";
  };
}
