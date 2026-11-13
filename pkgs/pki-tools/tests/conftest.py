import ipaddress
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

NODES = ["c4130", "m2mini", "r440"]
DOMAIN = "example.ts.net"
EKUS = {"server": ExtendedKeyUsageOID.SERVER_AUTH, "client": ExtendedKeyUsageOID.CLIENT_AUTH}
PROFILES = {"server": ("server",), "client": ("client",), "peer": ("server", "client")}
SPECS = [
    ("etcd-peer", "etcd", "peer", "@NODE@", (), "node"),
    ("etcd-server", "etcd", "peer", "@NODE@", (), "node"),
    ("etcd-client-apiserver", "etcd", "client", "kube-apiserver-etcd-client", (), ""),
    ("apiserver", "k8s", "server", "kube-apiserver", (), "apiserver"),
    ("apiserver-kubelet-client", "k8s", "client", "system:kube-apiserver", (), ""),
    ("front-proxy-client", "front-proxy", "client", "front-proxy-client", (), ""),
    ("controller-manager", "k8s", "client", "system:kube-controller-manager", (), ""),
    ("scheduler", "k8s", "client", "system:kube-scheduler", (), ""),
    ("admin", "k8s", "client", "cluster-admin", ("system:masters",), ""),
    ("addon-manager", "k8s", "client", "system:kube-addon-manager", (), ""),
    ("kubelet", "k8s", "peer", "system:node:@NODE@", ("system:nodes",), "node"),
    ("kube-proxy", "k8s", "client", "system:kube-proxy", ("system:node-proxier",), ""),
    ("flannel", "k8s", "client", "flannel-client", (), ""),
]


@dataclass
class CA:
    cert: x509.Certificate
    key: ec.EllipticCurvePrivateKey


@dataclass(frozen=True)
class LeafSpec:
    stem: str
    ca: str
    profile: str
    cn: str
    orgs: tuple[str, ...]
    dns: tuple[str, ...]
    ips: tuple[str, ...]


def pem(*certs: x509.Certificate) -> bytes:
    return b"".join(c.public_bytes(serialization.Encoding.PEM) for c in certs)


def key_pem(key) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def name(cn: str, orgs=()) -> x509.Name:
    return x509.Name(
        [x509.NameAttribute(NameOID.ORGANIZATION_NAME, o) for o in orgs] + [x509.NameAttribute(NameOID.COMMON_NAME, cn)]
    )


def leaf_specs(node: str) -> list[LeafSpec]:
    """The leaves cluster-pki issues for `node` (every node has every role here)."""
    node_dns = (node, f"{node}.{DOMAIN}", "localhost")
    node_ips = ("100.64.0.%d" % (NODES.index(node) + 1), "127.0.0.1")
    api_dns = node_dns + ("kubernetes", "kubernetes.default", "kubernetes.default.svc", "kubernetes.default.svc.cluster.local")
    sans = {"": ((), ()), "node": (node_dns, node_ips), "apiserver": (api_dns, node_ips + ("10.96.0.1",))}
    return [
        LeafSpec(f"{comp}-{node}", ca, prof, cn.replace("@NODE@", node), orgs, *sans[kind])
        for comp, ca, prof, cn, orgs, kind in SPECS
    ]


class Factory:
    def __init__(self):
        self.now = datetime.now(UTC).replace(microsecond=0)
        self.root = self.ca("test root")
        self.cas = {n: self.ca(f"neurosis {n} CA", self.root) for n in ("k8s", "etcd", "front-proxy", "workload")}

    def ca(self, cn: str, issuer: CA | None = None, key=None, subject: x509.Name | None = None) -> CA:
        key = key or ec.generate_private_key(ec.SECP384R1())
        signer = issuer or CA(None, key)
        subject = subject or name(cn, ("neurosis",))
        b = (
            self._base(subject, signer.cert.subject if issuer else subject, key, signer.key, 3650)
            .add_extension(x509.BasicConstraints(ca=True, path_length=0 if issuer else None), True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), True)
        )
        return CA(b.sign(signer.key, hashes.SHA384()), key)

    def _base(self, subject, issuer_name, key, issuer_key, days, serial=None):
        return (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer_name)
            .public_key(key.public_key())
            .serial_number(serial or x509.random_serial_number())
            .not_valid_before(self.now - timedelta(hours=1))
            .not_valid_after(self.now - timedelta(hours=1) + timedelta(days=days))
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), False)
        )

    def leaf(self, ca: CA, spec: LeafSpec, key=None, days: int = 365, eku=None, orgs=None, dns=None):
        """Issue `spec` from `ca`; key/days/eku/orgs/dns override the spec. Returns (cert, key)."""
        key = key or rsa.generate_private_key(65537, 2048)
        dns = spec.dns if dns is None else dns
        b = (
            self._base(name(spec.cn, spec.orgs if orgs is None else orgs), ca.cert.subject, key, ca.key, days)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
            .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), True)
            .add_extension(x509.ExtendedKeyUsage([EKUS[e] for e in (eku or PROFILES[spec.profile])]), False)
        )
        if dns or spec.ips:
            alt = [x509.DNSName(d) for d in dns] + [x509.IPAddress(ipaddress.ip_address(i)) for i in spec.ips]
            b = b.add_extension(x509.SubjectAlternativeName(alt), False)
        return b.sign(ca.key, hashes.SHA256()), key

    def write_set(self, dest: Path, node: str, style: str) -> dict[str, LeafSpec]:
        """Write a node's leaves: style "cluster-pki" chains server/peer leaves only, "cert-manager" all."""
        dest.mkdir(parents=True, exist_ok=True)
        specs = {s.stem: s for s in leaf_specs(node)}
        for s in specs.values():
            ca = self.cas[s.ca]
            cert, key = self.leaf(ca, s)
            chained = style == "cert-manager" or s.profile != "client"
            (dest / f"{s.stem}.pem").write_bytes(pem(cert, ca.cert) if chained else pem(cert))
            (dest / f"{s.stem}-key.pem").write_bytes(key_pem(key))
        return specs


@pytest.fixture(scope="session")
def pki() -> Factory:
    return Factory()
