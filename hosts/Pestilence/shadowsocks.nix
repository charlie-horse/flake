{ pkgs, config, ... }:
let
  inherit (builtins)
    toJSON
    ;
  inherit (pkgs)
    writeText
    ;
  inherit (config.age)
    secrets
    ;
  inherit (config.custom)
    ports
    ;
  cloak = pkgs.stdenv.mkDerivation rec {
    name = "cloak";
    version = "2.6.1";
    src = pkgs.fetchurl {
      url =
        "https://github.com/cbeuw/Cloak"
        + "/releases/download/v${version}"
        + "/ck-server-linux-amd64-v${version}";
      sha256 = "sha256-aTV6zzVbctSKgkjmP2UAa/gXQieUfzTVBWMg4ojBnoA=";
    };
    phases = [ "buildPhase" ];
    buildPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/ck-server
      chmod +x $out/bin/ck-server
    '';
  };
in
{
  systemd.services.shadowsocks =
    let
      ckconfig = {
        ProxyBook.shadowsocks = [
          "tcp"
          "127.0.0.1"
        ];
        BindAddr = [ ":${builtins.toString ports.shadowsocks}" ];
        RedirAddr = "204.79.197.200:443";
        BypassUID = [ "AAAAAAAAAAAAAAAAAAAAAA==" ];
      };
      ssconfig = {
        server = "0.0.0.0";
        server_port = ports.shadowsocks;
        method = "none";
        mode = "tcp_and_udp";
        nameserver = "1.1.1.1";
        fast_open = true;
        plugin = "${cloak}/bin/ck-server";
      };
    in
    {
      description = "Shadowsocks daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.shadowsocks-rust
        pkgs.jq
      ];
      serviceConfig.PrivateTmp = true;
      script = ''
        cat ${writeText "shadowsocks.json" (toJSON ckconfig)} \
        | jq --arg PrivateKey "$(cat "${secrets.vpn-privkey.path}")" \
            '. + {PrivateKey: $PrivateKey}' \
        > /tmp/cloak.json

        cat ${writeText "shadowsocks.json" (toJSON ssconfig)} \
        | jq --arg password "$(cat "${secrets.vpn-password.path}")" \
            '. + {password: $password} + {plugin_opts: "/tmp/cloak.json"}' \
        > /tmp/shadowsocks.json

        exec ssserver -c /tmp/shadowsocks.json
      '';
    };
}
