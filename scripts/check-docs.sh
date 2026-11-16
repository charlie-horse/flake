#!/usr/bin/env bash
# check-docs.sh: lint documentation hygiene across the repo.
#
# Rules (each violation prints file:line and a fix hint; exit 1 if any):
#   comment-block  contiguous comment lines longer than MAX_COMMENT_LINES
#   md-link        relative markdown link whose target does not exist
#   md-anchor      #anchor in a markdown link missing from the target .md
#   docs-ref       a docs/....md reference (any file) to a missing file
#   orphan-doc     a docs/**/*.md not linked from docs/README.md
#
# Usage: scripts/check-docs.sh [--list-comment-blocks] [-h|--help]
# Env:   MAX_COMMENT_LINES (default 15)
# Exceptions go in .docs-allowlist (format described in that file).
# Deps: bash, git, grep, awk (mawk or gawk), sed, coreutils.
set -euo pipefail

MAX="${MAX_COMMENT_LINES:-15}"
LIST_ONLY=0

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --list-comment-blocks) LIST_ONLY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "check-docs: unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$MAX" in
  '' | *[!0-9]*)
    echo "check-docs: MAX_COMMENT_LINES must be a number (got '$MAX')" >&2
    exit 2
    ;;
esac

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

SELF="scripts/check-docs.sh"
ALLOWLIST_FILE=".docs-allowlist"

# Tracked files plus new, not-ignored ones (so docs being written count),
# minus anything deleted in the working tree.
FILES=()
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] && FILES+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard | sort -zu)

# Allowlist: one glob (whole file, all rules) or path:line (that line, or
# the comment block containing it) per line; '#' starts a comment.
ALLOW_GLOBS=()
ALLOW_LINES=()
if [[ -f "$ALLOWLIST_FILE" ]]; then
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$entry" ]] && continue
    if [[ "$entry" =~ ^(.+):([0-9]+)$ ]]; then
      ALLOW_LINES+=("$entry")
    else
      ALLOW_GLOBS+=("$entry")
    fi
  done <"$ALLOWLIST_FILE"
fi

# allowed FILE [FIRST_LINE [LAST_LINE]]
allowed() {
  local file="$1" first="${2:-0}" last="${3:-${2:-0}}" g e p l
  for g in "${ALLOW_GLOBS[@]+"${ALLOW_GLOBS[@]}"}"; do
    # shellcheck disable=SC2053 # glob match is intended
    [[ "$file" == $g ]] && return 0
  done
  for e in "${ALLOW_LINES[@]+"${ALLOW_LINES[@]}"}"; do
    p="${e%:*}"
    l="${e##*:}"
    [[ "$p" == "$file" && "$l" -ge "$first" && "$l" -le "$last" ]] && return 0
  done
  return 1
}

# Files never checked by the reference rules (generated or encrypted).
generated() {
  case "$1" in
    k8s/rendered/* | secrets/* | *.sops.yaml | *.lock | "$SELF" | "$ALLOWLIST_FILE") return 0 ;;
  esac
  return 1
}

declare -A COUNT=([comment-block]=0 [md-link]=0 [md-anchor]=0 [docs-ref]=0 [orphan-doc]=0)
report() { # rule file line message hint
  printf '%s:%s: [%s] %s\n    fix: %s\n' "$2" "$3" "$1" "$4" "$5"
  COUNT[$1]=$((COUNT[$1] + 1))
}

# ---------------------------------------------------------------- rule 1
COMMENT_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    k8s/rendered/* | secrets/* | k8s/*.sops.yaml | *.lock) continue ;;
    hardware-configuration.nix | */hardware-configuration.nix) continue ;;
    *.nix | *.sh | *.yml | *.yaml | *.py | *.toml | *.js | *.ts) COMMENT_FILES+=("$f") ;;
  esac
done

# Prints: file<TAB>first line<TAB>length for each block longer than max.
comment_blocks() {
  [[ $# -eq 0 ]] && return 0
  awk -v max="$MAX" '
    function flush() {
      if (n > max) printf "%s\t%d\t%d\n", file, start, n
      n = 0
    }
    FNR == 1 {
      flush(); file = FILENAME
      js = (FILENAME ~ /\.(js|ts)$/)
    }
    {
      s = $0; sub(/^[ \t]+/, "", s)
      c = js ? (substr(s, 1, 2) == "//") : (substr(s, 1, 1) == "#")
      if (FNR == 1 && substr($0, 1, 2) == "#!") c = 0
      if (c) { if (!n) start = FNR; n++ } else flush()
    }
    END { flush() }
  ' "$@"
}

if [[ $LIST_ONLY -eq 1 ]]; then
  echo "Comment blocks longer than $MAX lines (length, location; * = allowlisted):"
  comment_blocks "${COMMENT_FILES[@]+"${COMMENT_FILES[@]}"}" |
    while IFS=$'\t' read -r file start len; do
      mark=" "
      allowed "$file" "$start" $((start + len - 1)) && mark="*"
      printf '%5d %s %s:%d-%d\n' "$len" "$mark" "$file" "$start" $((start + len - 1))
    done | sort -rn
  exit 0
fi

while IFS=$'\t' read -r file start len; do
  end=$((start + len - 1))
  allowed "$file" "$start" "$end" && continue
  report comment-block "$file" "$start" \
    "comment block of $len lines (lines $start-$end, max $MAX)" \
    "move the prose to a doc under docs/ and leave a one-line pointer (e.g. '# Details: docs/<topic>.md#<section>'), or allowlist '$file:$start' in $ALLOWLIST_FILE"
done < <(comment_blocks "${COMMENT_FILES[@]+"${COMMENT_FILES[@]}"}")

# ---------------------------------------------------------------- rule 2
MD_FILES=()
for f in "${FILES[@]}"; do
  [[ "$f" == *.md ]] && ! generated "$f" && MD_FILES+=("$f")
done

# Prints: file<TAB>line<TAB>raw link target, skipping fenced code and
# inline code spans. Handles [t](x), ![t](x) and reference defs [t]: x.
md_links() {
  [[ $# -eq 0 ]] && return 0
  awk '
    FNR == 1 { fence = "" }
    {
      s = $0; sub(/^[ \t]+/, "", s)
      if (fence == "" && (substr(s, 1, 3) == "```" || substr(s, 1, 3) == "~~~")) {
        fence = substr(s, 1, 3); next
      }
      if (fence != "") { if (substr(s, 1, 3) == fence) fence = ""; next }
      line = $0
      gsub(/`[^`]*`/, "", line)
      if (match(line, /^[ \t]*\[[^]]+\]:[ \t]+[^ \t]+/)) {
        t = substr(line, RSTART, RLENGTH); sub(/^[ \t]*\[[^]]+\]:[ \t]+/, "", t)
        printf "%s\t%d\t%s\n", FILENAME, FNR, t
      }
      while (match(line, /\]\([^)]*\)/)) {
        printf "%s\t%d\t%s\n", FILENAME, FNR, substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$@"
}

# Sets LINK_PATH to a raw link target's local path (empty if not local).
# Helpers set variables instead of printing: avoids a fork per link.
link_path() {
  LINK_PATH=""
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t#<}"
  t="${t%%>*}"
  t="${t%% *}"
  [[ -z "$t" || "$t" == \#* ]] && return 0
  [[ "$t" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && return 0
  t="${t%%#*}"
  t="${t%%\?*}"
  LINK_PATH="${t//%20/ }"
}

# Prints: file<TAB>anchor for every heading (GitHub slug rules, with
# -1, -2... for duplicates) and every <a id=...>/<a name=...> anchor.
md_anchors() {
  [[ $# -eq 0 ]] && return 0
  LC_ALL=C awk '
    function slug(t,   out, i, c) {
      sub(/[ \t]+#+[ \t]*$/, "", t); sub(/[ \t]+$/, "", t)
      while (match(t, /!?\[[^]]*\]\([^)]*\)/)) {
        c = substr(t, RSTART, RLENGTH); sub(/^!?\[/, "", c); sub(/\]\(.*$/, "", c)
        t = substr(t, 1, RSTART - 1) c substr(t, RSTART + RLENGTH)
      }
      gsub(/<[^>]*>/, "", t)
      t = tolower(t); out = ""
      for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        # Latin-1 capitals (UTF-8 C3 80-9E, not x D7) to lower case.
        if (c == "\303" && (substr(t, i + 1, 1) in lc)) {
          out = out c lc[substr(t, i + 1, 1)]; i++; continue
        }
        if (c == " ") out = out "-"
        else if (c ~ /[a-z0-9_-]/ || c > "~") out = out c
      }
      return out
    }
    function emit(t,   s) {
      s = slug(t)
      if (s in seen) { seen[s]++; s = s "-" seen[s] } else seen[s] = 0
      printf "%s\t%s\n", FILENAME, s
    }
    BEGIN { for (i = 128; i <= 158; i++) if (i != 151) lc[sprintf("%c", i)] = sprintf("%c", i + 32) }
    FNR == 1 { fence = ""; prev = ""; split("", seen) }
    {
      s = $0; sub(/^[ \t]+/, "", s)
      if (fence == "" && (substr(s, 1, 3) == "```" || substr(s, 1, 3) == "~~~")) {
        fence = substr(s, 1, 3); prev = ""; next
      }
      if (fence != "") { if (substr(s, 1, 3) == fence) fence = ""; next }
      line = $0
      while (match(line, /<a[ \t][^>]*(id|name)="[^"]*"/)) {
        a = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        sub(/^.*(id|name)="/, "", a); sub(/"$/, "", a)
        printf "%s\t%s\n", FILENAME, a
      }
      if (match($0, /^ ? ? ?#+([ \t]|$)/)) {
        h = $0; sub(/^ */, "", h); k = h; sub(/^#+/, "", k)
        if (length(h) - length(k) <= 6) { sub(/^[ \t]+/, "", k); emit(k) }
        prev = ""; next
      }
      if (prev != "" && ($0 ~ /^ ? ? ?=+[ \t]*$/ || $0 ~ /^ ? ? ?-+[ \t]*$/)) {
        emit(prev); prev = ""; next
      }
      prev = ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*([-*+>|]|[0-9]+\.)/) ? "" : s
    }
  ' "$@"
}

declare -A ANCHOR=() ANCHOR_LIST=()
while IFS=$'\t' read -r file a; do
  ANCHOR["$file#$a"]=1
  ANCHOR["$file#${a,,}"]=1 # bash lowercases non-ASCII too (UTF-8 locale)
  ANCHOR_LIST[$file]+="$a "
done < <(md_anchors "${MD_FILES[@]+"${MD_FILES[@]}"}")
declare -A IS_MD=()
for f in "${MD_FILES[@]+"${MD_FILES[@]}"}"; do IS_MD[$f]=1; done

# nearest_anchors FILE ANCHOR: up to 6 anchors sharing a word with ANCHOR.
nearest_anchors() {
  local out="" a w n=0
  for a in ${ANCHOR_LIST[$1]:-}; do
    for w in ${2//-/ }; do
      if [[ ${#w} -ge 3 && "$a" == *"$w"* ]]; then
        out+="#$a "
        n=$((n + 1))
        break
      fi
    done
    [[ $n -ge 6 ]] && break
  done
  if [[ -z "$out" ]]; then
    for a in ${ANCHOR_LIST[$1]:-}; do
      out+="#$a "
      n=$((n + 1))
      [[ $n -ge 6 ]] && break
    done
  fi
  printf '%s' "${out:-(no headings) }"
}

# normpath PATH: set NORM to PATH with "." and ".." segments collapsed.
normpath() {
  local -a parts=() out=()
  local seg
  IFS=/ read -r -a parts <<<"$1"
  for seg in "${parts[@]}"; do
    case "$seg" in
      '' | .) ;;
      ..) if [[ ${#out[@]} -gt 0 && "${out[-1]}" != .. ]]; then unset 'out[-1]'; else out+=(..); fi ;;
      *) out+=("$seg") ;;
    esac
  done
  local IFS=/
  NORM="${out[*]}"
}

README_TARGETS=()
while IFS=$'\t' read -r file line raw; do
  link_path "$raw"
  path="$LINK_PATH"
  anchor=""
  t="${raw%% *}"
  t="${t#<}"
  t="${t%>}"
  [[ "$t" == *#* && ! "$t" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && anchor="${t#*#}"
  if [[ -z "$path" ]]; then
    target="$file"
    [[ -z "$anchor" || "$t" != \#* ]] && continue
  else
    if [[ "$path" == /* ]]; then
      resolved="${path#/}"
    else
      dir="${file%/*}"
      resolved="$dir/$path"
      [[ "$file" != */* ]] && resolved="$path"
    fi
    if [[ "$file" == "docs/README.md" ]]; then
      normpath "$resolved"
      README_TARGETS+=("$NORM")
    fi
    if [[ ! -e "$resolved" ]]; then
      allowed "$file" "$line" ||
        report md-link "$file" "$line" "link target '$raw' does not exist" \
          "point it at an existing path (relative to $(dirname "$file")/), or allowlist '$file:$line'"
      continue
    fi
    [[ -z "$anchor" || "$resolved" != *.md ]] && continue
    normpath "$resolved"
    target="$NORM"
  fi
  [[ -n "${IS_MD[$target]+x}" ]] || continue
  [[ -n "${ANCHOR["$target#$anchor"]+x}" || -n "${ANCHOR["$target#${anchor,,}"]+x}" ]] && continue
  allowed "$file" "$line" && continue
  report md-anchor "$file" "$line" "anchor '#$anchor' not found in $target" \
    "use one of: $(nearest_anchors "$target" "${anchor,,}")or allowlist '$file:$line'"
done < <(md_links "${MD_FILES[@]+"${MD_FILES[@]}"}")

# ---------------------------------------------------------------- rule 3
REF_FILES=()
for f in "${FILES[@]}"; do
  generated "$f" || REF_FILES+=("$f")
done

# Prints: file<TAB>line<TAB>reference for every docs/....md mention. In
# markdown, link targets "](...)" are left to rule 2.
docs_refs() {
  [[ $# -eq 0 ]] && return 0
  awk '
    {
      line = $0
      if (FILENAME ~ /\.md$/) gsub(/\]\([^)]*\)/, "]", line)
      pre = ""
      while (match(line, /(\.\/|(\.\.\/)+)?docs\/[A-Za-z0-9._\/-]*\.md/)) {
        before = (RSTART > 1) ? substr(line, RSTART - 1, 1) : ""
        ref = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (before ~ /[A-Za-z0-9._\/-]/) continue
        printf "%s\t%d\t%s\n", FILENAME, FNR, ref
      }
    }
  ' "$@"
}

DOCREF_CANDIDATES=()
if [[ ${#REF_FILES[@]} -gt 0 ]]; then
  while IFS= read -r f; do DOCREF_CANDIDATES+=("$f"); done \
    < <(grep -IlE 'docs/[A-Za-z0-9._/-]*\.md' -- "${REF_FILES[@]}" || true)
fi

while IFS=$'\t' read -r file line ref; do
  if [[ "$ref" == ./* || "$ref" == ../* ]]; then
    resolved="$(dirname "$file")/$ref"
  else
    resolved="$ref"
  fi
  [[ -e "$resolved" ]] && continue
  allowed "$file" "$line" && continue
  report docs-ref "$file" "$line" "reference to missing file '$ref'" \
    "update it to the doc's current path (docs/README.md lists them), or allowlist '$file:$line'"
done < <(docs_refs "${DOCREF_CANDIDATES[@]+"${DOCREF_CANDIDATES[@]}"}")

# ---------------------------------------------------------------- rule 4
if [[ ! -f docs/README.md ]]; then
  echo "check-docs: warning: docs/README.md does not exist; skipping orphan-doc check" >&2
else
  declare -A LINKED=()
  for t in "${README_TARGETS[@]+"${README_TARGETS[@]}"}"; do LINKED[$t]=1; done
  for f in "${FILES[@]}"; do
    [[ "$f" == docs/*.md && "$f" != docs/README.md ]] || continue
    [[ -n "${LINKED[$f]+x}" ]] && continue
    allowed "$f" && continue
    report orphan-doc "$f" 1 "not linked from docs/README.md" \
      "add a link to it in docs/README.md (e.g. [title](${f#docs/})), or allowlist '$f'"
  done
fi

# ---------------------------------------------------------------- summary
total=0
for r in comment-block md-link md-anchor docs-ref orphan-doc; do total=$((total + COUNT[$r])); done
printf '\ncheck-docs: %d violation(s): comment-block=%d md-link=%d md-anchor=%d docs-ref=%d orphan-doc=%d (max comment lines %s)\n' \
  "$total" "${COUNT[comment-block]}" "${COUNT[md-link]}" "${COUNT[md-anchor]}" "${COUNT[docs-ref]}" "${COUNT[orphan-doc]}" "$MAX"
[[ $total -eq 0 ]]
