#!/bin/bash
# Shared sandbox for every sshid suite.
#
# ⚠ WE FAKE $HOME, AND WE MUST. claude-account's sandbox only redirects four env vars
# because its state lives in one directory it owns. Ours lives in ~/.gitconfig,
# ~/.ssh/config, ~/.config/git/identities and ~/.skm — files the real machine owns and
# a dozen live agent sessions depend on. A suite that leaked would rewrite real routing.
# GIT_CONFIG_NOSYSTEM stops /opt/homebrew/etc/gitconfig leaking in; XDG_CONFIG_HOME
# stops git finding the real ~/.config/git/config.
#
# Source this, then call sshid_sandbox. Sets $T (sandbox root) and $S (the CLI).

fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }
section(){ echo; echo "=== $1 ==="; }

sshid_sandbox(){
  REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
  S="$REPO/bin/sshid"
  T=$(mktemp -d); T=$(cd "$T" && pwd -P)
  export HOME="$T" XDG_CONFIG_HOME="$T/.config" GIT_CONFIG_NOSYSTEM=1 NO_COLOR=1
  export SSHID_LIB="$REPO/libexec"
  mkdir -p "$T/.config/sshid" "$T/.ssh" "$T/.skm" "$T/.config/git/identities" "$T/bin" "$T/projects"
  chmod 0700 "$T/.ssh"

  # A ~/.gitconfig with pre-existing content the tool must never touch. This is the
  # single most important fixture: proving the block is surgical.
  cat > "$T/.gitconfig" <<'GC'
[user]
	name = Alexy
	email = alexy@example.com
[init]
	defaultBranch = main
[filter "lfs"]
	required = true
	clean = git-lfs clean -- %f
[alias]
	st = status
GC
  UNMANAGED_BEFORE=$(unmanaged_snapshot)
  export UNMANAGED_BEFORE

  # Stubs. `ssh` answers as whatever $SSH_AS says, or fails, so verify/probe paths are
  # testable without a network or a real account.
  # The ssh stub. For `git-upload-pack` it execs a REAL local upload-pack against a bare
  # repo in the sandbox, so `verify`'s authorization step runs the genuine git code path
  # instead of a mock that could pass for the wrong reason.
  cat > "$T/bin/ssh" <<'STUB'
#!/bin/bash
# Real ssh READS STDIN. The stub must too, or it cannot reproduce the bug where ssh called
# inside a `while read` loop swallows the rest of the loop's input.
[ -t 0 ] || cat >/dev/null 2>&1 &
case "${SSH_MODE:-ok}" in
  err)    echo "ssh: connect failed" >&2; exit 255 ;;
  denied) echo "git@host: Permission denied (publickey)." >&2; exit 255 ;;
esac
last="${!#}"
case "$last" in
  *git-upload-pack*)
    if [ "${SSH_REPO_OK:-0}" = 1 ] && [ -d "${SSH_BARE:-}" ]; then exec git upload-pack "$SSH_BARE"; fi
    echo "ERROR: Repository not found." >&2; exit 128 ;;
esac
for a in "$@"; do case "$a" in git@gitlab*) echo "Welcome to GitLab, @${SSH_GL:-tester}!"; exit 1 ;; esac; done
echo "Hi ${SSH_AS:-tester}! You've successfully authenticated, but GitHub does not provide shell access."
exit 1
STUB
  cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "auth status") [ -n "${GH_ACCOUNTS:-}" ] || exit 1
                 for a in $GH_ACCOUNTS; do echo "  - Active account: false"; echo "  - Logged in to github.com account $a"; done; exit 0 ;;
  "auth token")  shift 2; u=""; while [ $# -gt 0 ]; do [ "$1" = "-u" ] && u="$2"; shift; done
                 case " ${GH_ACCOUNTS:-} " in *" $u "*) echo "gho_stubtoken_$u"; exit 0 ;; esac; exit 1 ;;
  "api user")    echo "${GH_ACTIVE:-nobody}"; exit 0 ;;
esac
echo "gh-stub: $*"; exit 0
STUB
  chmod +x "$T/bin/ssh" "$T/bin/gh"
  # a real bare repo with one commit, for the authorization probe to actually reach
  export SSH_BARE="$T/remote.git"
  git init -q --bare "$SSH_BARE"
  ( w="$T/.seed"; mkdir -p "$w"; cd "$w" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed \
    && git push -q "$SSH_BARE" main ) >/dev/null 2>&1
  export PATH="$T/bin:$PATH"
}

# Everything in ~/.gitconfig OUTSIDE the sshid markers, as a hash. The invariant every
# mutation must preserve.
unmanaged_snapshot(){
  [ -f "$HOME/.gitconfig" ] || { echo "NOFILE"; return; }
  awk '/^# >>> sshid managed block/{i=1;next} /^# <<< sshid managed block/{i=0;next} !i' \
    "$HOME/.gitconfig" | shasum -a 256 | cut -d' ' -f1
}
unmanaged_unchanged(){ [ "$(unmanaged_snapshot)" = "$UNMANAGED_BEFORE" ]; }

# A real throwaway key — ed25519, no passphrase, generated in the sandbox.
mkkey(){ local n="$1" t="${2:-ed25519}"; mkdir -p "$HOME/.skm/$n"
  ssh-keygen -q -t "$t" -N '' -C "$n" -f "$HOME/.skm/$n/id_$t" </dev/null >/dev/null 2>&1; }

# A git repo with zero or more remotes: mkrepo <path> [name=url ...]
mkrepo(){ local p="$1"; shift; mkdir -p "$p"; git -C "$p" init -q -b main 2>/dev/null
  local kv; for kv in "$@"; do git -C "$p" remote add "${kv%%=*}" "${kv#*=}" 2>/dev/null; done; }

# Which identity does git itself resolve for this repo? Empty = no rule matched.
resolved(){ git -C "$1" config core.sshCommand 2>/dev/null | sed -n 's|.*\.skm/\([^/]*\)/.*|\1|p'; }
# Which FILE decided it — the baseline or a fragment. This is the real diagnostic.
resolved_by(){ git -C "$1" config --show-origin core.sshCommand 2>/dev/null | awk '{print $1}'; }

S(){ /bin/bash "$S" "$@"; }
finish(){ cd /; rm -rf "$T"; echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILURES"; exit $fail; }
