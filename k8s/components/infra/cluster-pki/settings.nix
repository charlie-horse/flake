# Names shared by the cluster-pki components (default.nix: the namespace;
# issuers.nix: the Issuers, Certificates and policies).
rec {
  namespace = "cluster-pki";

  # cluster-pki's CA name -> the Issuer (and its CA Secret, of the same
  # name, from k8s/secrets/cluster-pki/<name>.sops.yaml).
  issuers = {
    k8s = "k8s-ca";
    etcd = "etcd-ca";
    front-proxy = "front-proxy-ca";
  };

  # Every leaf: RSA 2048 and one year, as cluster-pki (KEY_SIZE,
  # LEAF_HOURS); renewed 30 days before expiry (RENEW_BEFORE_DAYS).
  keySize = 2048;
  duration = "8760h";
  renewBefore = "720h";

  # Labels on every Certificate and its Secret.
  labelNode = "pki.neurosis/node";
  labelCA = "pki.neurosis/ca";
}
