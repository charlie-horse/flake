import json
import os

CA_OF_COMPONENT = {
    "etcd-peer": "etcd",
    "etcd-server": "etcd",
    "etcd-client-apiserver": "etcd",
    "front-proxy-client": "front-proxy",
}


def load(path: str | None = None) -> list[dict]:
    path = path or os.environ.get("PKI_LEAVES_JSON")
    if not path:
        return []
    with open(path) as f:
        return json.load(f)


def expected(names: str | None = None, table: list[dict] | None = None) -> dict[str, dict]:
    """name -> {name, node, ca}; PKI_EXPORT_SECRETS (if set) picks the names."""
    table = load() if table is None else table
    known = {l["name"]: l for l in table}
    names = os.environ.get("PKI_EXPORT_SECRETS", "") if names is None else names
    picked = names.split() or list(known)
    out = {}
    for n in picked:
        if n in known:
            out[n] = {"name": n, "node": known[n]["node"], "ca": known[n]["ca"]}
        else:
            node = n.rsplit("-", 1)[-1]
            comp = n[: -len(node) - 1]
            out[n] = {"name": n, "node": node, "ca": CA_OF_COMPONENT.get(comp, "k8s")}
    return out


def nodes(exp: dict[str, dict]) -> list[str]:
    return sorted({l["node"] for l in exp.values()})
