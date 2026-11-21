# Tangled knot: the Rust `knot-server` (knot2/) of tangled.org/@tangled.org/core.
# It speaks git (gix) and SSH itself; the image needs no git or sshd.
# Configured by KNOT_* env vars only (no config file).
{ pkgs, pkgsUnstable, ... }:
let
  inherit (pkgsUnstable) lib;

  # Cargo.toml's rust-version (1.99) is newer than the flake's nixpkgs rustc.
  knot-server = pkgsUnstable.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "knot-server";
    version = "1.20.1";

    src = pkgsUnstable.fetchgit {
      url = "https://tangled.org/@tangled.org/core";
      tag = "v${finalAttrs.version}";
      hash = "sha256-G9GqopFb5msKSPs54IYLY6i6UotO1nm1T4jP9NI21K8=";
    };

    cargoHash = "sha256-/+ya7i1G6Zv/irZ7y50lcB871Xii/0VVVF1Rk8c7bks=";

    cargoBuildFlags = [
      "--package"
      "knot-server"
    ];

    nativeBuildInputs = with pkgsUnstable; [
      pkg-config
      protobuf
    ];
    # rustPlatform's cargo hook makes these -sys crates link system libraries.
    buildInputs = with pkgsUnstable; [
      aws-lc
      rust-jemalloc-sys
      sqlite
      zstd
    ];

    doCheck = false;

    meta = {
      description = "Tangled knot git server";
      homepage = "https://tangled.org/@tangled.org/core";
      license = lib.licenses.mit;
      mainProgram = "knot-server";
    };
  });
in
{
  tangled-knot = pkgs.dockerTools.streamLayeredImage {
    name = "tangled-knot";
    tag = knot-server.version;
    contents = [ pkgs.dockerTools.caCertificates ];
    extraCommands = ''
      mkdir -p -m 1777 tmp
    '';
    config = {
      Entrypoint = [ (lib.getExe knot-server) ];
      User = "1000:1000";
      WorkingDir = "/tmp";
      ExposedPorts = {
        "5555/tcp" = { };
        "2222/tcp" = { };
      };
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
}
