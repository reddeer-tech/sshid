#!/bin/bash
# Resolve which SSH identity and which gh account apply to a directory.
# Usage: resolve.sh [dir]
# Prints ONE tab-separated line:
#   <identity>\t<keyfile>\t<decided-by>\t<why>\t<gh-account>\t<gh-why>
# Empty fields where unknown. Exit 0 always — "nothing applies" is an answer.
#
# SINGLE SOURCE OF ROUTING TRUTH. `sshid whoami`, `sshid doctor` and the gh shim all call
# this, so they cannot drift. That drift is not hypothetical here: this project's previous
# gh-whoami re-implemented the shim's logic and spent a week reporting an account gh would
# not actually use.
#
# ⚠ WE DO NOT RE-IMPLEMENT SSH ROUTING. git already resolves it, and asking git is the
# only answer that cannot disagree with what git will really do. Anything that parses
# ~/.gitconfig itself is a second implementation and will drift.

_rs="${BASH_SOURCE[0]:-$0}"
while [ -L "$_rs" ]; do _t="$(readlink "$_rs")"; case "$_t" in /*) _rs="$_t" ;; *) _rs="$(dirname "$_rs")/$_t" ;; esac; done
_rd="$(cd "$(dirname "$_rs")" 2>/dev/null && pwd)"
for _c in "${SSHID_LIB:-}/lib.sh" "$_rd/lib.sh" "$_rd/../libexec/lib.sh" "$HOME/.config/sshid/lib.sh"; do
  [ -n "$_c" ] && [ -f "$_c" ] && { . "$_c"; break; }
done
# Standalone fallback if lib.sh could not be found: mirror its key-store detection rather
# than hardcoding one layout.
if [ -z "${GHMAP:-}" ]; then
  GHMAP="$HOME/.config/git/identities/gh-accounts.map"
  if   [ -n "${SSHID_KEYDIR:-}" ]; then KEYDIR="$SSHID_KEYDIR"
  elif [ -d "$HOME/.skm" ];        then KEYDIR="$HOME/.skm"
  else                                  KEYDIR="$HOME/.ssh/sshid"; fi
  ident_from_cmd(){ local k; k=$(printf '%s' "$1" | sed -n 's|.*-i \([^ ]*\).*|\1|p')
    [ -n "$k" ] || return 0; k=${k%/*}; printf '%s' "${k##*/}"; }
fi

dir=${1:-$PWD}
case "$dir" in /*) ;; *) dir=$(cd "$dir" 2>/dev/null && pwd) || exit 0 ;; esac

ident=""; keyfile=""; decided=""; why=""; gh_acct=""; gh_why=""

# ── ssh identity: ASK GIT ────────────────────────────────────────────────────────────
if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  line=$(git -C "$dir" config --show-origin core.sshCommand 2>/dev/null)
  if [ -n "$line" ]; then
    decided=${line%%$'\t'*}; decided=${decided#file:}
    cmd=${line#*$'\t'}
    keyfile=$(printf '%s' "$cmd" | sed -n 's|.*-i \([^ ]*\).*|\1|p')
    ident=$(ident_from_cmd "$cmd")
    case "$decided" in
      */identities/*.gitconfig) why="rule" ;;
      */.git/config)            why="repo-local override" ;;
      *)                        why="baseline" ;;
    esac
  fi
  # A repo-local core.sshCommand beats every central rule and is invisible from the
  # central config, so name it loudly rather than reporting a routing that is not real.
  if [ -n "$(git -C "$dir" config --local --get core.sshCommand 2>/dev/null)" ]; then
    why="repo-local override"
  fi
fi

# ── gh account: org first, identity second ───────────────────────────────────────────
# Org before identity is load-bearing: an HTTPS remote has no ssh identity at all (git
# does not route HTTPS), so identity-first would send every HTTPS repo to the personal
# account. Org wins, exactly as layer 2 beats layer 1 on the ssh side.
map_lookup(){ # <section> <key>
  [ -f "$GHMAP" ] || return 0
  awk -v want="$1" -v key="$2" '
    /^[[:space:]]*#/ {next}
    /^\[.*\]$/ { sec=$0; gsub(/^\[|\]$/,"",sec); next }
    { if (sec==want && $1==key) { print $2; exit } }' "$GHMAP"
}
ghurl=""
if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  ghurl=$(git -C "$dir" config --get remote.origin.url 2>/dev/null)
  case "$ghurl" in *github.com[:/]*) ;; *)
    ghurl=$(git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>/dev/null \
            | awk '{print $2}' | grep -m1 'github\.com[:/]' || true) ;;
  esac
fi
if [ -n "$ghurl" ]; then
  org=${ghurl#*github.com}; org=${org#:}; org=${org#/}; org=${org%%/*}
  if [ -n "$org" ]; then
    gh_acct=$(map_lookup org "$org")
    [ -n "$gh_acct" ] && gh_why="org '$org'"
  fi
  if [ -z "$gh_acct" ] && [ -n "$ident" ]; then
    gh_acct=$(map_lookup identity "$ident")
    [ -n "$gh_acct" ] && gh_why="ssh identity '$ident'"
  fi
fi

printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ident" "$keyfile" "$decided" "$why" "$gh_acct" "$gh_why"
