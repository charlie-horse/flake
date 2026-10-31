# NOT imported by ./default.nix. The cluster-port half of r440's old
# firewall.nix (~/flint-nix/builder/etc-nixos/firewall.nix), kept only so
# the parity proof (hosts/r440 + old k8s.nix + this file == the live
# toplevel) can be re-run. The cluster module replaces it: delete this file
# once the cluster switch has happened.
{ lib, ... }:
let
  # Hosts allowed to reach etcd (2379 client, 2380 peer) and the apiserver
  # (6443) over the LAN. Tailscale is trusted as a whole.
  clusterPeers = [
    "10.0.0.95" # c4130 (eno1)
    "10.0.0.200" # c4130's keepalived apiserver VIP
    "10.0.0.147" # m2mini (eno, per the router's DNS/ARP)
  ];
  clusterPorts = [ 2379 2380 6443 ];
in
{
  networking.firewall = {
    # k8s.nix listed 2379/2380/6443 for everyone; narrow them to the peers.
    allowedTCPPorts = lib.mkForce [ 22 ];
    extraCommands = lib.concatMapStrings (
      src:
      lib.concatMapStrings (port: ''
        iptables -A nixos-fw -p tcp -s ${src} --dport ${toString port} -j nixos-fw-accept
      '') clusterPorts
    ) clusterPeers;
  };
}
