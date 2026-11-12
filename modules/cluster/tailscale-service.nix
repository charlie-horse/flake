# Tailscale Service for the Kubernetes API: every controlPlane node hosts
# svc:<cluster.apiserverTailscaleService> (today svc:kube-api), TCP 6443 ->
# its local apiserver at 127.0.0.1:6443. Tailnet clients reach the API as
# https://kube-api.<cluster.domain>:6443 (own MagicDNS name and TailVIP,
# load-balanced over the hosts that advertise it), next to the LAN-only
# keepalived VIP (./keepalived.nix). The apiserver leaves carry the name
# as a SAN (cluster.apiserverExtraSANs; asserted below).
#
# nixpkgs 26.05 has no serve/Services options in services.tailscale, so a
# oneshot applies the declarative Services config file
# (tailscale.com/kb/1589) with `tailscale serve set-config --service=...`.
# That replaces only this service's handlers (idempotent: a second run
# writes the same config) and adds it to the AdvertiseServices pref; other
# serve config and the node's prefs are untouched.
#
# Lifecycle: the unit is bound to kube-apiserver.service. When the apiserver
# stops, ExecStop runs `tailscale serve drain`, so the node stops taking
# new connections; when it starts again (Upholds), set-config advertises
# the node again. There is no /readyz check (keepalived has one for the
# VIP): a running but unready apiserver still gets traffic.
#
# Needs, outside Nix (docs/cluster.md, "Tailscale Service for the API"):
# tagged hosts (all three are tag:node), the service defined in the admin
# console with endpoint tcp:6443, an autoApprovers.services entry and a
# grant for the clients. Until then the node advertises, unapproved.
#
# Firewall: tailscaled terminates the TailVIP connection itself and dials
# 127.0.0.1:6443 over lo, which nixos-fw always accepts; nothing has to be
# opened on tailscale0 (also not on c4130, trustTailscale = false).
{
  config,
  lib,
  pkgs,
  cluster,
  ...
}:
let
  inherit (lib) mkOption types mkIf;
  cfg = config.clusterNode;
  ts = config.services.tailscale;
  # The fallback only keeps the (unused) names below evaluable.
  name = cluster.apiserverTailscaleService or "kube-api";
  svc = "svc:${name}";
  fqdn = "${name}.${cluster.domain}";
  port = toString cluster.apiserverPort;

  serviceConfig = pkgs.writeText "tailscale-service-${name}.json" (
    builtins.toJSON {
      version = "0.0.1";
      services.${svc}.endpoints."tcp:${port}" = "tcp://127.0.0.1:${port}";
    }
  );
in
{
  options.clusterNode.tailscaleService.enable = mkOption {
    type = types.bool;
    default = cluster ? apiserverTailscaleService && lib.elem "controlPlane" cfg.activeRoles;
    defaultText = "cluster.apiserverTailscaleService is set and the node runs the controlPlane role";
    description = ''
      Host the apiserver's Tailscale Service (svc:<cluster.apiserverTailscaleService>)
      on this node, forwarding TCP ${port} to the local kube-apiserver.
    '';
  };

  config = mkIf (cfg.enable && cfg.tailscaleService.enable) {
    assertions = [
      {
        assertion = ts.enable;
        message = "clusterNode.tailscaleService needs services.tailscale.enable.";
      }
      {
        assertion = config.services.kubernetes.apiserver.enable;
        message = "clusterNode.tailscaleService needs a local kube-apiserver.";
      }
      {
        assertion = lib.elem fqdn (cluster.apiserverExtraSANs or [ ]);
        message = ''
          clusterNode.tailscaleService: add "${fqdn}" to
          cluster.apiserverExtraSANs (and re-issue the apiserver leaves),
          or kubectl cannot verify the apiserver's certificate by that name.
        '';
      }
    ];

    systemd.services."tailscale-service-${name}" = {
      description = "Tailscale Service ${svc} (TCP ${port} -> local kube-apiserver)";
      after = [
        "tailscaled.service"
        "tailscaled-autoconnect.service"
        "tailscaled-set.service"
        "kube-apiserver.service"
      ];
      wants = [ "tailscaled.service" ];
      bindsTo = [ "kube-apiserver.service" ];
      upheldBy = [ "kube-apiserver.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        ts.package
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # set-config needs a netmap; at boot tailscaled may still be
        # connecting (the script waits up to 60 s, then systemd retries).
        Restart = "on-failure";
        RestartSec = "15s";
        # Best effort: fails harmlessly when tailscaled is already down.
        ExecStop = "-${lib.getExe ts.package} serve drain ${svc}";
      };
      startLimitIntervalSec = 0;
      script = ''
        for _ in $(seq 60); do
          state=$(tailscale status --json --peers=false | jq -r .BackendState) || state=
          [ "$state" = Running ] && break
          sleep 1
        done
        if [ "$state" != Running ]; then
          echo "tailscaled is not Running (state: ''${state:-unknown})" >&2
          exit 1
        fi
        tailscale serve set-config --service=${svc} ${serviceConfig}
      '';
    };
  };
}
