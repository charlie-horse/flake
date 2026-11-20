# Flake check `step-ca`: the certificate flow end to end, without a cluster.
# step-ca runs ../ca-json.nix (the config the cluster gets, pointed at
# mock_idp.py), the step CLI asks for certs with client_credentials tokens,
# and sshd (as the build user, through nss_wrapper) trusts the CA the way
# custom.auth.sshCA configures it. Cases: test.sh.
{ pkgs, lib }:
let
  settings = import ../settings.nix;
  idpPort = 18080;
  caPort = 19000;
  caJson = import ../ca-json.nix {
    inherit lib settings;
    issuer = "http://127.0.0.1:${toString idpPort}${settings.issuerPath}";
    paths = {
      internalCA = "@WORK@/internal-ca";
      userKey = "@WORK@/ssh-user-ca/key";
    };
    address = "127.0.0.1:${toString caPort}";
  };
in
pkgs.runCommand "step-ca-test"
  {
    nativeBuildInputs = [
      pkgs.step-ca
      pkgs.step-cli
      pkgs.openssh
      pkgs.openssl
      pkgs.curl
      pkgs.jq
      (pkgs.python3.withPackages (p: [
        p.pyjwt
        p.cryptography
      ]))
    ];
    caJson = builtins.toJSON caJson;
    passAsFile = [ "caJson" ];
    inherit idpPort caPort;
    sshGroups = lib.concatStringsSep " " settings.sshGroups;
    maxDuration = settings.durations.max;
    nssWrapper = "${pkgs.nss_wrapper}/lib/libnss_wrapper.so";
    mockIdp = ./mock_idp.py;
  }
  ''
    bash ${./test.sh}
    touch $out
  ''
