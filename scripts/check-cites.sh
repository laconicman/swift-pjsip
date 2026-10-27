#!/bin/bash
#
# check-cites.sh — prove that the file:line citations in a config_site.h still
# point at the code they describe, against the pjproject tree about to be
# compiled.
#
# A citation is `<file>:<line>[-<line>] \`<token>\``, e.g.
#   pjsua_aud.c:944 `ports[PJSUA_MAX_CONF_PORTS]`
# The token is what a reader would grep for; it must occur within the cited
# range (±TOLERANCE lines). <file> is resolved by path suffix inside the tree,
# so `pjmedia/config.h` and `pjmedia-audiodev/config.h` stay distinct; a suffix
# that matches more than one file is an error — qualify it. A citation with a
# line number but no token is an error too: a number alone cannot be checked.
#
# Line numbers rot with every upstream bump (cutting 0.4.0 moved 17 of 23), and
# nothing else reads them, so a reader following one can land on unrelated
# code. build.sh runs this on the freshly extracted tree, before the patches,
# so the header's "line references are pjproject master @ <sha>" line is a
# claim the build checks rather than one the last manual refresh made: with
# --commit, the sha named on that line must be a prefix of the commit the tree
# was fetched from (an extracted GitHub archive carries no .git, so the caller
# supplies the commit it recorded). A header with no citations at all fails
# too — there is nothing to hold, and silence is not a pass.
#
# Usage:
#   check-cites.sh [--tolerance N] [--commit SHA] <config_site.h> <pjproject tree>
#
# Exit 0 when every citation holds; 1 with one line per stale citation, naming
# where the token actually is now, so the fix is a number edit. Needs only bash
# 3.2, grep and find. Standalone on purpose: no build state.

set -euo pipefail

TOLERANCE=2
COMMIT=""
HEADER=""
TREE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tolerance)   TOLERANCE="${2:?--tolerance needs a value}"; shift 2 ;;
        --tolerance=*) TOLERANCE="${1#*=}"; shift ;;
        --commit)      COMMIT="${2:?--commit needs a value}"; shift 2 ;;
        --commit=*)    COMMIT="${1#*=}"; shift ;;
        -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)            echo "Unknown option: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$HEADER" ]]; then HEADER="$1"
            elif [[ -z "$TREE" ]]; then TREE="$1"
            else echo "Unexpected argument: $1" >&2; exit 2
            fi
            shift ;;
    esac
done

[[ -n "$HEADER" && -n "$TREE" ]] || { echo "Usage: $0 [--tolerance N] [--commit SHA] <config_site.h> <pjproject tree>" >&2; exit 2; }
[[ -f "$HEADER" ]] || { echo "Not a file: $HEADER" >&2; exit 2; }
[[ -d "$TREE" ]]   || { echo "Not a directory: $TREE" >&2; exit 2; }

failures=0
checked=0

# The header names the commit its numbers are for: "… pjproject master @ <sha>".
# With --commit, that sha must be a prefix of the fetched commit, so a bump that
# refreshes the numbers but not the line — or the reverse — is caught.
if [[ -n "$COMMIT" ]]; then
    claimed="$( { grep -o -i -E '@ [0-9a-f]{7,40}' "$HEADER" || true; } | head -1 | cut -d' ' -f2 | tr 'A-F' 'a-f')"
    if [[ -z "$claimed" ]]; then
        echo "STALE  $(basename "$HEADER"): names no '@ <sha>' for its line references, cannot match ${COMMIT}" >&2
        failures=$((failures + 1))
    elif [[ "$(echo "$COMMIT" | tr 'A-F' 'a-f')" != "$claimed"* ]]; then
        echo "STALE  $(basename "$HEADER"): line references claim @ ${claimed}, tree is ${COMMIT}" >&2
        failures=$((failures + 1))
    else
        checked=$((checked + 1))
    fi
fi

# One citation per output line: "<lineno in header>|<file>|<start>|<end>|<token>".
# A token is the backtick span right after the range; absent, the field is empty.
# The pattern is deliberately narrow — a path ending in a source extension,
# a colon, digits — so prose like "conference.c)" or "docs/Versioning.md" passes.
extract_citations() {
    # shellcheck disable=SC2016  # the backticks are literal citation syntax
    grep -n -o -E '[A-Za-z0-9_./-]+\.(c|h|m|mm|cpp|hpp|in):[0-9]+(-[0-9]+)?( `[^`]+`)?' "$HEADER" \
    | sed -E 's/^([0-9]+):([A-Za-z0-9_./-]+):([0-9]+)(-([0-9]+))?( `([^`]+)`)?$/\1|\2|\3|\5|\7/'
}

# Every path in the tree ending in "/<suffix>", third_party excluded (bundled
# libraries are not what a config_site.h cites, and they duplicate names).
resolve() {
    find "$TREE" -type f -path "*/$1" -not -path "*/third_party/*" | sort
}

cited=0

while IFS='|' read -r at file start end token; do
    cited=$((cited + 1))
    [[ -n "${end}" ]] || end="$start"
    where="$(basename "$HEADER"):${at}"
    cite="${file}:${start}"; [[ "$end" != "$start" ]] && cite="${cite}-${end}"

    if [[ -z "$token" ]]; then
        echo "STALE  ${where}: ${cite} has no \`token\` to check" >&2
        failures=$((failures + 1)); continue
    fi

    matches="$(resolve "$file")"
    count=0; [[ -n "$matches" ]] && count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
        echo "STALE  ${where}: ${cite} — no file ends in /${file} under ${TREE}" >&2
        failures=$((failures + 1)); continue
    elif [[ "$count" -gt 1 ]]; then
        echo "STALE  ${where}: ${cite} — ambiguous, qualify the path:" >&2
        printf '%s\n' "$matches" | sed "s|^${TREE}/||; s|^|         |" >&2
        failures=$((failures + 1)); continue
    fi
    path="$matches"

    lo=$((start - TOLERANCE)); [[ $lo -lt 1 ]] && lo=1
    hi=$((end + TOLERANCE))
    if sed -n "${lo},${hi}p" "$path" | grep -qF -- "$token"; then
        checked=$((checked + 1)); continue
    fi

    actual="$( { grep -nF -- "$token" "$path" || true; } | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$actual" ]]; then
        echo "STALE  ${where}: ${cite} \`${token}\` is now at line(s) ${actual} of ${path#"$TREE"/}" >&2
    else
        echo "STALE  ${where}: ${cite} \`${token}\` is nowhere in ${path#"$TREE"/}" >&2
    fi
    failures=$((failures + 1))
done < <(extract_citations)

if [[ $cited -eq 0 ]]; then
    echo "STALE  $(basename "$HEADER"): no file:line citations found — nothing to hold, and silence is not a pass" >&2
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    echo "${failures} stale citation(s), ${checked} hold — $(basename "$HEADER") vs ${TREE}" >&2
    exit 1
fi
echo "${checked} citation(s) hold — $(basename "$HEADER") vs ${TREE}"
