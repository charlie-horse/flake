# ATCR AppView and hold (tangled.org/evan.jarrett.net/at-container-registry),
# built as upstream's Dockerfile.{appview,hold} do: cgo (go-libsql), tag
# sqlite_omit_load_extension, assets from `npm run build` embedded.
{ pkgs }:
let
  inherit (pkgs) lib dockerTools;
  version = "0.1.4";

  upstream = pkgs.fetchgit {
    url = "https://tangled.org/evan.jarrett.net/at-container-registry";
    tag = "v${version}";
    hash = "sha256-rNgJLVORS3OtvK7LwFMApDK+UDGgNmbCX+xg607/aY0=";
  };

  # What upstream's `go generate` makes and git ignores: Tailwind CSS, icon
  # sprites and JS bundles (npm), and the SPDX list (curl upstream).
  assets = pkgs.buildNpmPackage {
    pname = "atcr-assets";
    inherit version;
    src = upstream;
    npmDepsHash = "sha256-5Lham0QXBA8TqQ0j1+AJje+YcZtdM2/awzq6XKFEwbo=";
    npmBuildScript = "build";
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r --parents pkg/appview/public pkg/hold/admin/public $out/
      install -Dm444 ${pkgs.spdx-license-list-data.json}/json/licenses.json \
        $out/pkg/appview/licenses/spdx-licenses.json
      runHook postInstall
    '';
  };

  atcr = pkgs.buildGoModule {
    pname = "atcr";
    inherit version;
    src = upstream;
    vendorHash = "sha256-JWrLC4SPbzbIUe6Vr0ssYsrsF9eJDdvO3SK5Nzd2FmA=";
    # go mod vendor would drop go-libsql's headers and static libraries.
    proxyVendor = true;
    env.GOWORK = "off";
    overrideModAttrs = _: { preBuild = ""; };
    preBuild = ''
      cp -r --no-preserve=mode ${assets}/pkg .
    '';
    subPackages = [
      "cmd/appview"
      "cmd/hold"
    ];
    tags = [ "sqlite_omit_load_extension" ];
    ldflags = [
      "-s"
      "-w"
    ];
    # Upstream's tests reach the network and spawn services.
    doCheck = false;
    meta.license = lib.licenses.mit;
  };

  image =
    name: bin: port:
    dockerTools.streamLayeredImage {
      inherit name;
      tag = "latest";
      contents = [ dockerTools.caCertificates ];
      config = {
        Entrypoint = [ (lib.getExe' atcr bin) ];
        Cmd = [ "serve" ];
        User = "65532:65532";
        ExposedPorts."${toString port}/tcp" = { };
        Env = [
          "HOME=/tmp"
          "TMPDIR=/tmp"
          "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          "ZONEINFO=${pkgs.tzdata}/share/zoneinfo"
        ];
      };
    };
in
{
  atcr-appview = image "atcr-appview" "appview" 5000;
  atcr-hold = image "atcr-hold" "hold" 8080;
}
