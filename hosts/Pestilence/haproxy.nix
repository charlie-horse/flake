{ config, ... }:
let
  inherit (config.custom)
    ports
    ;
in
{
  services.haproxy.enable = true;
  services.haproxy.config = ''
    global
        ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        ssl-default-bind-options prefer-client-ciphers no-sslv3 no-tlsv10 no-tlsv11 no-tlsv12 no-tls-tickets

        ssl-default-server-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        ssl-default-server-options no-sslv3 no-tlsv10 no-tlsv11 no-tlsv12 no-tls-tickets

        ca-base /mutable/ssl/certificates
        crt-base /mutable/ssl/certificates

    frontend http
        mode http
        bind :80
        bind :443 ssl crt sortofasian.io.pem alpn h2,http/1.1
        redirect scheme https if !{ ssl_fc }

        use_backend vw    if { hdr_beg(host) -i      vw }
        use_backend tr    if { hdr_beg(host) -i      tr }
        use_backend flood if { hdr_beg(host) -i   flood }
        use_backend fin   if { hdr_beg(host) -i     fin }
        use_backend idx   if { hdr_beg(host) -i idx.arr }
        use_backend tv    if { hdr_beg(host) -i  tv.arr }
        use_backend mv    if { hdr_beg(host) -i  mv.arr }
        use_backend sub   if { hdr_beg(host) -i sub.arr }
        use_backend see   if { hdr_beg(host) -i see.arr }

        default_backend node

    backend nginx
        mode http
        server main 127.0.0.1:${builtins.toString ports.nginx}
    backend node
        mode http
        server main 127.0.0.1:3000 check
    backend vw
        mode http
        server main 127.0.0.1:${builtins.toString ports.vaultwarden} check

    backend fin
        mode http
        server main 127.0.0.1:${builtins.toString ports.fin}
    backend flood
        mode http
        server main 127.0.0.1:${builtins.toString ports.flood}
    backend tr
        mode http
        server main 127.0.0.1:${builtins.toString ports.tr}

    backend idx
        mode http
        server main 127.0.0.1:${builtins.toString ports.arr.idx}
    backend tv
        mode http
        server main 127.0.0.1:${builtins.toString ports.arr.tv}
    backend mv
        mode http
        server main 127.0.0.1:${builtins.toString ports.arr.mv}
    backend sub
        mode http
        server main 127.0.0.1:${builtins.toString ports.arr.sub}
    backend see
        mode http
        server main 127.0.0.1:${builtins.toString ports.arr.see}
  '';
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
