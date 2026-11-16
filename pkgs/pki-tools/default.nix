{
  lib,
  python3Packages,
  writeText,
  dockerTools,
  kubectl,
  sops,
  age-plugin-yubikey,
  gitMinimal,
  cacert,
  yubikey-manager,
  step-kms-plugin,
  softhsm,
  openssl,
  procps,
  leaves,
}:
let
  leavesJSON = writeText "pki-leaves.json" (builtins.toJSON leaves);
  # Encrypting to an age1yubikey1... recipient runs the plugin (no card needed).
  runtimePath = [
    kubectl
    sops
    age-plugin-yubikey
    gitMinimal
  ];

  pki-tools = python3Packages.buildPythonApplication {
    pname = "pki-tools";
    version = "0.1.0";
    pyproject = true;
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./pyproject.toml
        ./pki
        ./tests
      ];
    };
    build-system = [ python3Packages.setuptools ];
    dependencies = with python3Packages; [
      cryptography
      pyyaml
    ];
    makeWrapperArgs = [
      "--prefix PATH : ${lib.makeBinPath runtimePath}"
      "--set-default PKI_LEAVES_JSON ${leavesJSON}"
    ];
    nativeCheckInputs = [ python3Packages.pytestCheckHook ] ++ runtimePath;
    preCheck = ''
      export HOME=$TMPDIR PKI_TEST_SOPS_YAML=${../../.sops.yaml} PKI_TEST_CLUSTER_PKI=${../../cluster/pki}
    '';
    # pki-ceremony needs yubikey-manager; only the `ceremony` variant ships it.
    postInstall = ''
      rm $out/bin/pki-ceremony
    '';
    pythonImportsCheck = [ "pki.cli_export" ];
    passthru = { inherit image leavesJSON ceremony; };
    meta.mainProgram = "pki-export";
  };

  # pki-ceremony (docs/pki.md): the YubiKey root ceremonies, as a separate
  # variant so pki-export's closure and image stay without yubikey-manager.
  # Its checkPhase is the superset: card fakes and the SoftHSM rehearsal too.
  ceremonyPath = [
    step-kms-plugin
    sops
    age-plugin-yubikey
    softhsm
    gitMinimal
    procps
  ];
  ceremony = pki-tools.overridePythonAttrs (old: {
    pname = "pki-ceremony";
    dependencies = old.dependencies ++ [ yubikey-manager ];
    makeWrapperArgs = [
      "--prefix PATH : ${lib.makeBinPath ceremonyPath}"
      "--set-default PKI_SOFTHSM_MODULE ${softhsm}/lib/softhsm/libsofthsm2.so"
    ];
    nativeCheckInputs = old.nativeCheckInputs ++ [
      softhsm
      step-kms-plugin
      openssl
    ];
    postInstall = ''
      rm $out/bin/pki-export
    '';
    pythonImportsCheck = [
      "pki.ceremony.cli"
      "pki.ceremony.card"
    ];
    passthru = { };
    meta.mainProgram = "pki-ceremony";
  });

  # The root fs is read-only: $HOME and $TMPDIR are the pod's memory-backed /tmp.
  image = dockerTools.streamLayeredImage {
    name = "pki-export";
    tag = "latest";
    contents = [ dockerTools.caCertificates ];
    config = {
      Entrypoint = [ (lib.getExe' pki-tools "pki-export") ];
      User = "65532:65532";
      Env = [
        "HOME=/tmp"
        "TMPDIR=/tmp"
        "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
pki-tools
