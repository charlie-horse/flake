# Tranquil PDS: nixpkgs' tranquil-pds (server) and tranquil-pds-frontend
# (static web UI, served by the server from FRONTEND_DIR).
{ pkgs, pkgsUnstable, ... }:
let
  inherit (pkgsUnstable) tranquil-pds tranquil-pds-frontend;
in
{
  tranquil-pds = pkgs.dockerTools.streamLayeredImage {
    name = "tranquil-pds";
    tag = tranquil-pds.version;
    contents = [ pkgs.dockerTools.caCertificates ];
    extraCommands = ''
      mkdir -p -m 1777 tmp
    '';
    config = {
      Entrypoint = [ (pkgs.lib.getExe tranquil-pds) ];
      User = "65532:65532";
      WorkingDir = "/tmp";
      ExposedPorts."3000/tcp" = { };
      Env = [
        "FRONTEND_DIR=${tranquil-pds-frontend}"
        "SERVER_HOST=::"
        "SERVER_PORT=3000"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
}
