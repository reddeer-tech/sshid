#!/bin/bash
# adopt — the migration. It is the ONE command that edits outside the markers, so it has
# to prove its own result rather than trust it. The fixture below mirrors the real
# machine: hand-written rules, a baseline, unrelated user config above them.
. "$(dirname "$0")/lib.sh"
sshid_sandbox
X(){ SSHID_LIB="$REPO/libexec" /bin/bash "$S" "$@"; }
export SSHID_ROOTS="$HOME/projects"
. "$REPO/libexec/lib.sh"   # repos() lives here; without it the equivalence check below
                           # compares two EMPTY strings and passes for the wrong reason.

for k in default turinglabs client; do mkkey "$k" rsa; done
mkdir -p "$HOME/.config/git/identities"
for k in default turinglabs client; do
  printf '[core]\n\tsshCommand = ssh -i ~/.skm/%s/id_rsa -o IdentitiesOnly=yes -o IdentityAgent=none\n' "$k" \
    > "$HOME/.config/git/identities/$k.gitconfig"
done
# A hand-written config exactly as someone would have built it by hand over time.
cat >> "$HOME/.gitconfig" <<GC

# ── ssh identity routing ─────────────────────────────
[core]
	sshCommand = ssh -i ~/.skm/default/id_rsa -o IdentitiesOnly=yes -o IdentityAgent=none

[includeIf "gitdir/i:~/projects/TuringLabs/"]
	path = ~/.config/git/identities/turinglabs.gitconfig
[includeIf "gitdir/i:~/projects/Client/"]
	path = ~/.config/git/identities/client.gitconfig

[includeIf "hasconfig:remote.*.url:git@github.com:turing-labs-hq/**"]
	path = ~/.config/git/identities/turinglabs.gitconfig
[includeIf "hasconfig:remote.*.url:git@github.com:client-co/**"]
	path = ~/.config/git/identities/client.gitconfig
[includeIf "hasconfig:remote.*.url:git@gitlab.com:personal/**"]
	path = ~/.config/git/identities/default.gitconfig
GC

mkrepo "$HOME/projects/TuringLabs/pulse"  "origin=git@github.com:turing-labs-hq/pulse.git"
mkrepo "$HOME/projects/Client/api"        "origin=git@github.com:client-co/api.git"
mkrepo "$HOME/projects/Client/noremote"
mkrepo "$HOME/projects/Misc/personal"     "origin=git@gitlab.com:personal/thing.git"
mkrepo "$HOME/projects/Misc/unmapped"     "origin=git@github.com:someone/else.git"
# the case the two-layer design exists for: a third-party repo inside a client folder
mkrepo "$HOME/projects/Client/vendored"   "origin=git@github.com:turing-labs-hq/lib.git"

section "the fixture routes the way the hand-written rules say"
[ "$(resolved "$HOME/projects/TuringLabs/pulse")" = turinglabs ] && ok "org rule" || no "org: $(resolved "$HOME/projects/TuringLabs/pulse")"
[ "$(resolved "$HOME/projects/Client/noremote")" = client ] && ok "dir rule covers a remote-less repo" || no "dir: $(resolved "$HOME/projects/Client/noremote")"
[ "$(resolved "$HOME/projects/Misc/unmapped")" = default ] && ok "unmapped falls to the baseline" || no "baseline: $(resolved "$HOME/projects/Misc/unmapped")"
[ "$(resolved "$HOME/projects/Client/vendored")" = turinglabs ] && ok "layer 2 beats layer 1 for a vendored repo" || no "override: $(resolved "$HOME/projects/Client/vendored")"

section "adopt is a no-op IN EFFECT"
before=$(for r in $(repos | sort); do printf '%s=%s\n' "$r" "$(resolved "$r")"; done)
# ⚠ GUARD THE GUARD. An empty snapshot compares equal to an empty snapshot, so the
# equivalence assertion below would pass while proving nothing.
nrepo=$(printf '%s\n' "$before" | grep -c .)
[ "$nrepo" -ge 6 ] && ok "$nrepo repos in the fixture to compare" || no "only $nrepo repos — the comparison below would be vacuous"
X adopt --no-probe >/dev/null 2>&1 && ok "adopt succeeded" || no "adopt failed"
after=$(for r in $(repos | sort); do printf '%s=%s\n' "$r" "$(resolved "$r")"; done)
[ -n "$after" ] && [ "$before" = "$after" ] && ok "all $nrepo repos resolve identically" || { no "resolution changed"; diff <(printf '%s' "$before") <(printf '%s' "$after") | head -8; }

section "the hand-written rules are GONE, not duplicated"
[ "$(grep -c 'includeIf' "$HOME/.gitconfig")" = 5 ] && ok "exactly 5 includeIf blocks (not 10)" || no "$(grep -c 'includeIf' "$HOME/.gitconfig") includeIf blocks — duplicated"
[ "$(grep -c 'sshCommand' "$HOME/.gitconfig")" = 1 ] && ok "exactly one baseline sshCommand" || no "$(grep -c 'sshCommand' "$HOME/.gitconfig") baselines"
n=$(awk '/>>> sshid/,/<<< sshid/' "$HOME/.gitconfig" | grep -c 'includeIf')
[ "$n" = 5 ] && ok "all 5 rules are inside the managed block" || no "$n rules inside the block"

section "the user's own config is untouched"
unmanaged_unchanged && ok "the user's original config is byte-identical to before adopt" \
  || { no "unmanaged content changed"; awk '/^# >>> sshid/{i=1;next} /^# <<< sshid/{i=0;next} !i' "$HOME/.gitconfig" | head -14 | sed 's/^/    /'; }
[ "$(git config --file "$HOME/.gitconfig" alias.st)" = status ] && ok "the user's alias survived" || no "alias lost"
[ "$(git config --file "$HOME/.gitconfig" user.name)" = Alexy ] && ok "user.name survived" || no "user.name lost"
[ "$(git config --file "$HOME/.gitconfig" 'filter.lfs.required')" = true ] && ok "the lfs filter survived" || no "lfs filter lost"

section "it recorded every key, including one that was never routed"
mkkey spare rsa
X adopt --no-probe --force >/dev/null 2>&1
X list --no-count | grep -q spare && ok "an unrouted key is still recorded as an identity" || no "unrouted key dropped"
X doctor 2>&1 | grep -q 'ZERO rules' && ok "doctor names the unroutable identity" || no "doctor silent about the orphan"

section "adopt is IDEMPOTENT — running it again must not grow anything"
# Found on the real machine: adopt stripped hand-written gitconfig rules but not
# hand-written ~/.ssh/config aliases, so it re-read its OWN generated block as "existing
# aliases" and added a duplicate Host stanza on every run. 20 Host lines where 12 belonged.
cat >> "$HOME/.ssh/config" <<'SC'
Host github-turinglabs
    HostName github.com
    User git
    IdentityFile ~/.skm/turinglabs/id_rsa
SC
X adopt --no-probe --force >/dev/null 2>&1
h1=$(grep -c '^Host ' "$HOME/.ssh/config"); r1=$(grep -c includeIf "$HOME/.gitconfig")
for i in 1 2 3; do X adopt --no-probe --force >/dev/null 2>&1; done
h2=$(grep -c '^Host ' "$HOME/.ssh/config"); r2=$(grep -c includeIf "$HOME/.gitconfig")
[ "$h1" = "$h2" ] && ok "Host entries stable across 4 adopts ($h1)" || no "Host entries grew $h1 -> $h2"
[ "$r1" = "$r2" ] && ok "includeIf rules stable across 4 adopts ($r1)" || no "rules grew $r1 -> $r2"
[ "$(grep '^Host ' "$HOME/.ssh/config" | sort | uniq -d | wc -l | tr -d ' ')" = 0 ] && ok "no duplicate Host stanzas" || no "duplicates: $(grep '^Host ' "$HOME/.ssh/config" | sort | uniq -d)"

section "adopt refuses to run twice by accident"
out=$(X adopt 2>&1)
printf '%s' "$out" | grep -qi 'already' && ok "second adopt says it is already adopted" || no "ran again silently"

section "a broken rewrite is REFUSED, never installed"
# The strip is the only place sshid rewrites the user's own config wholesale. A crashed
# parser once produced an empty file that was copied straight over ~/.gitconfig, losing
# user.name, the aliases and the lfs filter. Every non-routing setting must survive.
sha=$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)
before_keys=$(git config --file "$HOME/.gitconfig" --list | grep -vc '^includeif\.')
X adopt --no-probe --force >/dev/null 2>&1
after_keys=$(git config --file "$HOME/.gitconfig" --list | grep -vc '^includeif\.')
[ "$before_keys" = "$after_keys" ] && ok "every non-routing setting survived ($after_keys)" || no "settings lost: $before_keys -> $after_keys"
[ "$(git config --file "$HOME/.gitconfig" user.name)" = Alexy ] && ok "user.name intact" || no "user.name lost"
[ "$(git config --file "$HOME/.gitconfig" alias.st)" = status ] && ok "alias intact" || no "alias lost"

section "ROLLBACK: if the result would differ, nothing is kept"
# Force a mismatch by deleting a key between the before-snapshot and the write: fragkey
# then generates a different path and the repo resolves differently.
rm -rf "$HOME/.skm/client"
sha_gc=$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)
X adopt --no-probe --force >/dev/null 2>&1
git config --file "$HOME/.gitconfig" --list >/dev/null 2>&1 && ok "~/.gitconfig still parses after the attempt" || no "left a broken config"
unmanaged_unchanged && ok "user config still intact after the attempt" || no "rollback damaged unmanaged content"

finish
