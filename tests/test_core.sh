#!/bin/bash
# The CLI lifecycle: add -> route -> whoami -> unroute -> unbind -> forget, plus adopt.
# Weighted toward BEHAVIOUR — exit codes, what git resolves, what ends up on disk —
# because wording moves and behaviour must not.
. "$(dirname "$0")/lib.sh"
sshid_sandbox
X(){ SSHID_LIB="$REPO/libexec" /bin/bash "$S" "$@"; }
export SSHID_ROOTS="$HOME/projects"

section "create: makes a key, a record and a fragment"
X create acme --type=ed25519 >/dev/null 2>&1
[ -f "$HOME/.skm/acme/id_ed25519" ] && ok "key created" || no "no key"
[ "$(stat -f %Lp "$HOME/.skm/acme/id_ed25519")" = "600" ] && ok "key is mode 0600" || no "key mode $(stat -f %Lp "$HOME/.skm/acme/id_ed25519")"
ssh-keygen -y -P '' -f "$HOME/.skm/acme/id_ed25519" >/dev/null 2>&1 && ok "key has no passphrase (IdentityAgent=none needs this)" || no "key has a passphrase"
[ -f "$HOME/.config/git/identities/acme.gitconfig" ] && ok "fragment written" || no "no fragment"
X list | grep -q acme && ok "listed" || no "not listed"

section "create: REFUSES to overwrite an existing key — there is no undo for that"
before=$(shasum -a 256 "$HOME/.skm/acme/id_ed25519" | cut -d' ' -f1)
X create acme >/dev/null 2>&1 && no "second add succeeded" || ok "refused a duplicate name"
rm -f "$HOME/.config/sshid/identities.map"; X list >/dev/null 2>&1   # forget the record, keep the key
X create acme >/dev/null 2>&1 && no "overwrote a key that was not in the manifest" || ok "refused even when only the KEY exists"
[ "$(shasum -a 256 "$HOME/.skm/acme/id_ed25519" | cut -d' ' -f1)" = "$before" ] && ok "the existing key is byte-identical" || no "KEY WAS OVERWRITTEN"
X create acme --existing-key >/dev/null 2>&1 && ok "--existing-key adopts it instead" || no "--existing-key failed"

section "create: name validation happens before anything is written"
for bad in BAD_NAME 'a b' 'x!' '-lead' none global ''; do
  n=$(ls "$HOME/.skm" | wc -l)
  X create "$bad" >/dev/null 2>&1 && no "accepted bad name '$bad'"
  [ "$(ls "$HOME/.skm" | wc -l)" = "$n" ] || no "'$bad' created something"
done
ok "every invalid or reserved name refused, nothing written"

section "bind: REFUSES an org with no proof (the 'repository not found' trap)"
X bind acme --org github.com:acme-corp >/dev/null 2>&1 && no "routed without proof" || ok "refused without --proof"
grep -q 'acme-corp' "$HOME/.gitconfig" 2>/dev/null && no "wrote a rule anyway" || ok "no rule written"

section "bind: a FAILING proof does not bind either"
export SSH_REPO_OK=0
X bind acme --org github.com:acme-corp --proof git@github.com:acme-corp/app.git >/dev/null 2>&1 \
  && no "routed on a failed proof" || ok "failed proof blocks routing"
grep -q 'acme-corp' "$HOME/.gitconfig" 2>/dev/null && no "wrote a rule on a failed proof" || ok "still no rule"

section "bind: a PASSING proof binds, and git agrees"
export SSH_REPO_OK=1
X bind acme --org github.com:acme-corp --proof git@github.com:acme-corp/app.git >/dev/null 2>&1 \
  && ok "routed after a real upload-pack succeeded" || no "route failed"
mkrepo "$HOME/projects/Acme/app" "origin=git@github.com:acme-corp/app.git"
[ "$(resolved "$HOME/projects/Acme/app")" = "acme" ] && ok "git resolves the repo to acme" || no "git says '$(resolved "$HOME/projects/Acme/app")'"
X whoami "$HOME/projects/Acme/app" | grep -q acme && ok "whoami agrees with git" || no "whoami disagrees"
X whoami --porcelain "$HOME/projects/Acme/app" | grep -q '^acme	rule' && ok "porcelain is machine-readable" || no "porcelain: $(X whoami --porcelain "$HOME/projects/Acme/app")"

section "bind --dir covers a repo with no remote at all"
X bind acme --dir "$HOME/projects/Acme" >/dev/null 2>&1
mkrepo "$HOME/projects/Acme/fresh"
[ "$(resolved "$HOME/projects/Acme/fresh")" = "acme" ] && ok "a remote-less repo still routes" || no "got '$(resolved "$HOME/projects/Acme/fresh")'"

section "whoami names a repo-local override rather than reporting a routing that is not real"
git -C "$HOME/projects/Acme/fresh" config core.sshCommand "ssh -i ~/.skm/other/id_rsa"
X whoami "$HOME/projects/Acme/fresh" | grep -qi 'repo-local override' && ok "override reported loudly" || no "override hidden"
X doctor >/dev/null 2>&1; [ $? = 1 ] && ok "doctor exits 1 on a repo-local override" || no "doctor did not fail"
git -C "$HOME/projects/Acme/fresh" config --unset core.sshCommand

section "doctor: exit code means something"
X doctor >/dev/null 2>&1 && ok "doctor exits 0 when healthy" || no "doctor exits non-zero when healthy"

section "unbind --org drops one binding and leaves the rest"
X unbind acme --org github.com:acme-corp >/dev/null 2>&1
[ "$(resolved "$HOME/projects/Acme/app")" = "acme" ] && ok "still covered by the dir rule" || no "lost both rules"
grep -q 'acme-corp' "$HOME/.gitconfig" && no "org rule still present" || ok "org rule gone"

section "unbind --all keeps the key and the record"
X unbind acme --all >/dev/null 2>&1
[ -f "$HOME/.skm/acme/id_ed25519" ] && ok "key kept" || no "key deleted by unbind"
X list | grep -q acme && ok "identity still recorded" || no "record removed by unbind"
[ -z "$(resolved "$HOME/projects/Acme/app")" ] && ok "no longer routed" || no "still routed"

section "forget refuses while repos still use it"
X bind acme --dir "$HOME/projects/Acme" >/dev/null 2>&1
X forget acme >/dev/null 2>&1 && no "forgot while in use" || ok "refused while 1+ repos use it"
X forget acme --force >/dev/null 2>&1 && ok "--force forgets it" || no "--force failed"
[ -f "$HOME/.skm/acme/id_ed25519" ] && ok "the private key is still on disk (forget is not rm -rf)" || no "KEY DELETED"
[ -f "$HOME/.config/git/identities/acme.gitconfig" ] && no "fragment left behind" || ok "fragment removed"

section "key deletion is possible, but never accidental"
X create doomed >/dev/null 2>&1
[ -f "$HOME/.skm/doomed/id_ed25519" ] && ok "key created (ed25519 by default)" || no "no key"
X forget doomed --force >/dev/null 2>&1
[ -f "$HOME/.skm/doomed/id_ed25519" ] && ok "plain forget keeps the key" || no "plain forget DELETED the key"
X create doomed --existing-key >/dev/null 2>&1
# non-interactive without --yes must refuse: deleting key material is irreversible and no
# backup in this tool contains any.
X forget doomed --force --delete-key >/dev/null 2>&1
[ -f "$HOME/.skm/doomed/id_ed25519" ] && ok "--delete-key alone does NOT delete without a terminal or --yes" || no "KEY DELETED WITHOUT CONFIRMATION"
X create doomed --existing-key >/dev/null 2>&1
X forget doomed --force --delete-key --yes >/dev/null 2>&1
[ -f "$HOME/.skm/doomed/id_ed25519" ] && no "--yes did not delete the key" || ok "--delete-key --yes really deletes it"
[ -d "$HOME/.skm/doomed" ] && no "key directory left behind" || ok "key directory removed"

section "key types"
X create k-rsa --type=rsa >/dev/null 2>&1
ssh-keygen -lf "$HOME/.skm/k-rsa/id_rsa.pub" 2>/dev/null | grep -q RSA && ok "--type=rsa makes an RSA key (skm's old default)" || no "rsa failed"
X create k-ec --type=ecdsa >/dev/null 2>&1
ssh-keygen -lf "$HOME/.skm/k-ec/id_ecdsa.pub" 2>/dev/null | grep -q ECDSA && ok "--type=ecdsa works" || no "ecdsa failed"
X forget k-rsa --force >/dev/null 2>&1; X forget k-ec --force >/dev/null 2>&1

section "renamed verbs are DELETED, not aliased — and say what to use"
for old in add route unroute; do
  out=$(X $old thing 2>&1); rc=$?
  [ "$rc" = 2 ] && printf '%s' "$out" | grep -qE "is now '(create|bind|unbind)'|is now 'create'" \
    && ok "'$old' refuses and names the new verb" || no "'$old' rc=$rc: $out"
done

section "pubkey prints the public key and nothing else"
X create pk >/dev/null 2>&1
out=$(X pubkey pk)
printf '%s' "$out" | grep -q '^ssh-ed25519 ' && ok "prints the public key" || no "got: $out"
[ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] && ok "one line, pipeable to pbcopy" || no "multi-line output"
printf '%s' "$out" | grep -qi 'PRIVATE' && no "LEAKED PRIVATE KEY MATERIAL" || ok "no private key material"
X pubkey nosuch >/dev/null 2>&1 && no "pubkey on unknown identity succeeded" || ok "unknown identity refused"
X forget pk --force >/dev/null 2>&1

section "rename moves EVERYTHING that names the identity"
# Six things have to move together: the key dir, the identity record, every rule, the ssh
# alias (including the Host name), the gh row, and the fragment. Missing one leaves a
# half-renamed identity that looks fine until it silently uses the wrong key.
X create test >/dev/null 2>&1
X bind test --dir "$HOME/projects/Renamed" >/dev/null 2>&1
export SSH_REPO_OK=1
X bind test --org github.com:test-org --proof git@github.com:test-org/app.git >/dev/null 2>&1
mkrepo "$HOME/projects/Renamed/app" "origin=git@github.com:test-org/app.git"
fp_before=$(ssh-keygen -lf "$HOME/.skm/test/id_ed25519.pub" 2>/dev/null | awk '{print $2}')
[ "$(resolved "$HOME/projects/Renamed/app")" = test ] && ok "routes as 'test' before the rename" || no "setup: $(resolved "$HOME/projects/Renamed/app")"

X rename test production >/dev/null 2>&1
[ -d "$HOME/.skm/production" ] && ok "key directory moved" || no "key directory not moved"
[ -d "$HOME/.skm/test" ] && no "old key directory left behind" || ok "old key directory gone"
[ "$(ssh-keygen -lf "$HOME/.skm/production/id_ed25519.pub" 2>/dev/null | awk '{print $2}')" = "$fp_before" ] && ok "same key material, not a new key" || no "KEY CHANGED"
X list --no-count | grep -q production && ok "identity record renamed" || no "record not renamed"
# Check the IDENTITY COLUMN, not the whole line: the org is called "test-org", so a bare
# \btest\b matches inside it and the assertion passes for the wrong reason.
X list --no-count | awk '{print $1}' | grep -qx test && no "old name still listed" || ok "old name gone from the list"
[ -f "$HOME/.config/git/identities/production.gitconfig" ] && ok "fragment renamed" || no "fragment missing"
[ -f "$HOME/.config/git/identities/test.gitconfig" ] && no "old fragment left behind" || ok "old fragment removed"
[ "$(resolved "$HOME/projects/Renamed/app")" = production ] && ok "the repo follows the rename automatically" || no "repo: $(resolved "$HOME/projects/Renamed/app")"
grep -q 'test-org' "$HOME/.gitconfig" && ok "the org rule survived (it names the ORG, not the identity)" || no "org rule lost"
grep -q 'rule.*production' "$HOME/.config/sshid/identities.map" && ok "rules renamed in the manifest" || no "rules not renamed"
X doctor >/dev/null 2>&1 && ok "doctor is clean after the rename" || no "doctor reports a problem"

section "rename refuses what it should"
X create other >/dev/null 2>&1
X rename production other >/dev/null 2>&1 && no "renamed onto an existing identity" || ok "refuses an existing name"
X rename production 'BAD NAME' >/dev/null 2>&1 && no "accepted an invalid name" || ok "refuses an invalid name"
X rename production none >/dev/null 2>&1 && no "accepted a reserved name" || ok "refuses a reserved name"
X rename nosuch whatever >/dev/null 2>&1 && no "renamed an unknown identity" || ok "refuses an unknown identity"
[ "$(resolved "$HOME/projects/Renamed/app")" = production ] && ok "nothing broke through all those refusals" || no "a refusal damaged the routing"
X forget production --force >/dev/null 2>&1; X forget other --force >/dev/null 2>&1

section "export/import round-trips"
X create beta >/dev/null 2>&1; X bind beta --dir "$HOME/projects/Beta" >/dev/null 2>&1
X export > "$T/exp.tsv"
grep -q '^rule	dir	beta' "$T/exp.tsv" && ok "export carries the rule" || no "export missing the rule"
grep -qiE 'BEGIN .*PRIVATE KEY|gho_|ghp_' "$T/exp.tsv" && no "EXPORT CONTAINS A SECRET" || ok "export carries no key or token"
X forget beta --force >/dev/null 2>&1
X import "$T/exp.tsv" >/dev/null 2>&1
X list | grep -q beta && ok "import restored the identity" || no "import lost it"
mkrepo "$HOME/projects/Beta/x"
[ "$(resolved "$HOME/projects/Beta/x")" = "beta" ] && ok "import restored working routing" || no "routing not restored"

section "undo restores the previous snapshot"
sha_before=$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)
X bind beta --dir "$HOME/projects/Gamma" >/dev/null 2>&1
[ "$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)" != "$sha_before" ] && ok "the change landed" || no "no change to undo"
X undo --yes >/dev/null 2>&1
[ "$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)" = "$sha_before" ] && ok "undo restored it exactly" || no "undo did not restore"

section "setup fails LOUDLY when part of the install is missing"
# Found by installing from Homebrew: the formula parks gh-shim in libexec/shims/ while
# setup looked in libexec/, so the copy failed AND setup printed "✓ gh shim installed"
# regardless. On a clean machine it would have reported success having installed nothing.
mkdir -p "$T/fakelib"; cp "$REPO/libexec/lib.sh" "$REPO/libexec/resolve.sh" "$T/fakelib/"
out=$(SSHID_LIB="$T/fakelib" BINDIR="$T/nb" /bin/bash "$S" setup 2>&1); rc=$?
printf '%s' "$out" | grep -q '✓ gh shim installed' && no "claimed success with gh-shim missing" || ok "did not claim a success that did not happen"
[ "$rc" != 0 ] && ok "setup exits non-zero when a component is missing" || no "setup exited 0 with gh-shim missing"
# and it finds the shim in the Homebrew layout
mkdir -p "$T/fakelib/shims"; cp "$REPO/libexec/gh-shim" "$T/fakelib/shims/"
out=$(SSHID_LIB="$T/fakelib" BINDIR="$T/nb2" /bin/bash "$S" setup 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '✓ gh shim installed' && ok "finds gh-shim in the Homebrew libexec/shims layout" || no "brew layout not found: $out"

section "the user's own config survived all of it"
unmanaged_unchanged && ok "everything outside the markers is byte-identical to the fixture" || no "unmanaged content drifted"
git config --file "$HOME/.gitconfig" --list >/dev/null 2>&1 && ok "~/.gitconfig still parses" || no "does not parse"
[ "$(git config --file "$HOME/.gitconfig" alias.st)" = "status" ] && ok "the user's alias still works" || no "alias lost"

finish
