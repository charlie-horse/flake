rec {
  namespace = "cluster-pki";

  # CA name -> Issuer and its CA Secret (k8s/secrets/cluster-pki/<name>.sops.yaml).
  issuers = {
    k8s = "k8s-ca";
    etcd = "etcd-ca";
    front-proxy = "front-proxy-ca";
  };

  # Must match cluster-pki.sh: KEY_SIZE, LEAF_HOURS, RENEW_BEFORE_DAYS.
  keySize = 2048;
  duration = "8760h";
  renewBefore = "720h";

  labelNode = "pki.neurosis/node";
  labelCA = "pki.neurosis/ca";
}
