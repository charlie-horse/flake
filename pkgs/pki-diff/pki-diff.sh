#!/usr/bin/env bash
# pki-diff: compare one node's cluster-pki leaves (A) with the cert-manager
# set for the same node (B). Phase 2 of docs/pki-migration-plan.md, node P5;
# the dry run (P7) uses it.
#
#   pki-diff [--node NODE] A B
#
#   A  a directory of cluster-pki leaves (<stem>.pem): the PKI dir on r440
#      (holds every node, so give --node) or /var/lib/kubernetes/secrets on
#      a node
#   B  the cert-manager set: a secrets/pki/<node>.yaml export file (only the
#      plaintext <stem>.pem values are read, with yq; nothing is decrypted)
#      or a directory like A. For a file, --node defaults to its basename.
#
# Leaves are the *.pem files (and keys) that are neither *-key.pem nor CA
# certs, so trust bundles, sa.pub and the like are skipped. With --node,
# only stems ending in -<node> count.
#
# Per stem it compares subject (all RDNs, order-insensitive), SANs (DNS/IP
# as sets), keyUsage and extendedKeyUsage (sets), basicConstraints, key type
# and size, issuer (DN and authority key id: the same intermediate) and
# lifetime (notAfter - notBefore, within +-1 day). Criticality is ignored.
# Serials, validity dates and signatures are ignored. Whether the file
# carries the chain (leaf + intermediate) or only the leaf is INFO only:
# cluster-pki chains server leaves only, cert-manager always does.
#
# Output: one line per stem (OK, DIFF <field>: A=... B=..., MISSING-IN-A,
# MISSING-IN-B; INFO lines follow their stem), then a summary. For the set
# fields (subject, san, ku, eku) A= and B= list only the elements that one
# side has and the other lacks ("-" for none).
# Exit 0 when everything matches, 1 on any DIFF or MISSING, 2 on usage or
# input errors.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: pki-diff [--node NODE] A B
  A  cluster-pki leaves: a directory of <stem>.pem (r440's PKI dir, or
     /var/lib/kubernetes/secrets on a node)
  B  cert-manager set: secrets/pki/<node>.yaml (plaintext certs, read with
     yq; nothing is decrypted) or a directory like A
  --node  only stems ending in -NODE (default for a B file: its basename)
Prints OK / DIFF <field> / MISSING-IN-A / MISSING-IN-B per stem, INFO for a
chain difference, and a summary. Exit 1 on any DIFF or MISSING.
EOF
}
die() { echo "pki-diff: $*" >&2; exit 2; }

node=
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --node) [ $# -ge 2 ] || die "--node needs a value"; node=$2; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
[ ${#args[@]} = 2 ] || { echo "usage: pki-diff [--node NODE] A B" >&2; exit 2; }
a_src=${args[0]} b_src=${args[1]}

if [ -z "$node" ] && [ -f "$b_src" ]; then
  node=$(basename "$b_src"); node=${node%.yaml}; node=${node%.yml}
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/A" "$work/B"

is_cert() { openssl x509 -noout -in "$1" >/dev/null 2>&1; }
is_ca() {
  openssl x509 -noout -ext basicConstraints -in "$1" 2>/dev/null \
    | grep -q 'CA:TRUE'
}
# Copy candidate leaf $1 (file name $2) into set dir $3 if it is one.
take() {
  local f=$1 name=$2 dst=$3 stem
  case "$name" in
    *-key.pem) return 0 ;;
    *.pem) ;;
    *) return 0 ;;
  esac
  stem=${name%.pem}
  if [ -n "$node" ]; then
    case "$stem" in *-"$node") ;; *) return 0 ;; esac
  fi
  is_cert "$f" || return 0
  is_ca "$f" && return 0
  cp "$f" "$dst/$stem.pem"
}

load_dir() {  # $1 source dir, $2 set dir
  local f
  for f in "$1"/*.pem; do
    [ -f "$f" ] || continue
    take "$f" "$(basename "$f")" "$2"
  done
}

load_yaml() {  # $1 export file, $2 set dir
  local k v
  yq -e 'type == "!!map"' "$1" >/dev/null 2>&1 \
    || die "$1: not a YAML map (export file expected)"
  while IFS= read -r k; do
    case "$k" in *.pem) ;; *) continue ;; esac
    case "$k" in *-key.pem) continue ;; esac
    v=$(K=$k yq -r '.[strenv(K)]' "$1")
    case "$v" in ENC\[*) die "$1: '$k' is encrypted; certs must be plaintext" ;; esac
    printf '%s\n' "$v" >"$work/val"
    take "$work/val" "$k" "$2"
  done < <(yq -r 'keys | .[]' "$1")
}

load() {  # $1 source, $2 set dir
  if [ -d "$1" ]; then load_dir "$1" "$2"
  elif [ -f "$1" ]; then load_yaml "$1" "$2"
  else die "not a directory or file: '$1'"; fi
}
load "$a_src" "$work/A"
load "$b_src" "$work/B"

# ------------------------------------------------------------ field values
# Each prints one normalized line for the first cert of $1.
join_sorted() { sort -u | paste -sd, -; }
ext_values() {  # $1 cert, $2 extension name; values only, no header
  openssl x509 -noout -ext "$2" -in "$1" 2>/dev/null | sed 1d \
    | sed 's/^ *//' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true
}
f_subject() {
  openssl x509 -noout -subject -nameopt multiline,utf8 -in "$1" | sed 1d \
    | sed 's/^ *//;s/ *= */=/' | join_sorted
}
f_san() {
  ext_values "$1" subjectAltName | sed 's/^IP Address:/IP:/' | join_sorted
}
f_ku() { ext_values "$1" keyUsage | join_sorted; }
f_eku() { ext_values "$1" extendedKeyUsage | join_sorted; }
f_bc() {
  local v; v=$(ext_values "$1" basicConstraints | join_sorted)
  echo "${v:-absent}"
}
f_key() {
  openssl x509 -noout -text -in "$1" | sed -n \
    -e 's/^ *Public Key Algorithm: *//p' \
    -e 's/^ *Public-Key: *(\([0-9]*\) bit)/\1/p' \
    -e 's/^ *ASN1 OID: *//p' | paste -sd' ' -
}
f_issuer() {
  local dn akid
  dn=$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$1" | sed 's/^issuer=//')
  akid=$(ext_values "$1" authorityKeyIdentifier | sed 's/^keyid://' | paste -sd, -)
  echo "$dn keyid=${akid:-none}"
}
f_lifetime() {  # seconds
  local nb na
  nb=$(openssl x509 -noout -startdate -in "$1" | sed 's/^notBefore=//')
  na=$(openssl x509 -noout -enddate -in "$1" | sed 's/^notAfter=//')
  echo $(($(date -u -d "$na" +%s) - $(date -u -d "$nb" +%s)))
}
f_chain() {
  local n; n=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$1" || true)
  case "$n" in
    1) echo leaf ;;
    2) echo leaf+intermediate ;;
    *) echo "leaf+$((n - 1))-certs" ;;
  esac
}
# Elements of comma list $1 that are not in comma list $2.
set_only() {
  comm -23 <(tr ',' '\n' <<<"$1" | sort -u) <(tr ',' '\n' <<<"$2" | sort -u) \
    | paste -sd, -
}
days() { awk -v s="$1" 'BEGIN { printf "%.2fd", s / 86400 }'; }

# ------------------------------------------------------------ compare
ok=0 diff=0 miss_a=0 miss_b=0 info=0
stems=$( { ls "$work/A"; ls "$work/B"; } | sed 's/\.pem$//' | sort -u)
[ -n "$stems" ] || die "no leaves found in either set${node:+ for node $node}"

for s in $stems; do
  a=$work/A/$s.pem b=$work/B/$s.pem
  if [ ! -f "$a" ]; then echo "MISSING-IN-A $s"; miss_a=$((miss_a + 1)); continue; fi
  if [ ! -f "$b" ]; then echo "MISSING-IN-B $s"; miss_b=$((miss_b + 1)); continue; fi
  lines=()
  for f in subject san ku eku bc key issuer; do
    va=$("f_$f" "$a") vb=$("f_$f" "$b")
    [ "$va" = "$vb" ] && continue
    case "$f" in
      subject|san|ku|eku)  # sets: show only the elements on one side
        set_only "$va" "$vb" >"$work/oa"; set_only "$vb" "$va" >"$work/ob"
        va=$(cat "$work/oa") vb=$(cat "$work/ob")
        va=${va:--} vb=${vb:--} ;;
    esac
    lines+=("DIFF $s $f: A=$va B=$vb")
  done
  la=$(f_lifetime "$a") lb=$(f_lifetime "$b") delta=$((la - lb))
  if [ "${delta#-}" -gt 86400 ]; then
    lines+=("DIFF $s lifetime: A=$(days "$la") B=$(days "$lb")")
  fi
  if [ ${#lines[@]} -eq 0 ]; then
    echo "OK $s"; ok=$((ok + 1))
  else
    printf '%s\n' "${lines[@]}"; diff=$((diff + 1))
  fi
  ca=$(f_chain "$a") cb=$(f_chain "$b")
  if [ "$ca" != "$cb" ]; then
    echo "INFO $s chain: A=$ca B=$cb"; info=$((info + 1))
  fi
done

total=$(wc -w <<<"$stems")
echo "summary${node:+ ($node)}: $total stems, $ok OK, $diff DIFF," \
  "$miss_a MISSING-IN-A, $miss_b MISSING-IN-B, $info chain INFO"
[ $((diff + miss_a + miss_b)) -eq 0 ]
