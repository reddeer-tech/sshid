#!/bin/bash
# The write path — the only part of sshid that can damage a machine.
# Weighted toward BEHAVIOUR: what ends up on disk, what is refused, what survives a
# refusal. Every section names the failure it guards against.
. "$(dirname "$0")/lib.sh"
sshid_sandbox
. "$REPO/libexec/lib.sh"
man_init

section "splice: appends when the markers are absent"
printf 'BLOCK\n' | splice "$GC_BEGIN" "$GC_END" "$HOME/.gitconfig" "$T/out1" && \
  grep -qxF 'BLOCK' "$T/out1" && grep -qxF "$GC_BEGIN" "$T/out1" && grep -qxF "$GC_END" "$T/out1" \
  && ok "block appended with both markers" || no "append"
grep -qxF '	st = status' "$T/out1" && ok "pre-existing content kept" || no "pre-existing content lost"

section "splice: replaces in place on a second run"
cp "$T/out1" "$T/g2"
printf 'SECOND\n' | splice "$GC_BEGIN" "$GC_END" "$T/g2" "$T/out2"
[ "$(grep -c "$GC_BEGIN" "$T/out2")" = 1 ] && ok "still exactly one begin marker" || no "marker duplicated"
grep -qxF 'SECOND' "$T/out2" && ! grep -qxF 'BLOCK' "$T/out2" && ok "old body replaced" || no "replace"
grep -qxF '	st = status' "$T/out2" && ok "content outside the block untouched" || no "outside clobbered"

section "splice: refuses a malformed file rather than guessing"
{ echo "$GC_BEGIN"; echo body; echo "$GC_BEGIN"; echo "$GC_END"; } > "$T/bad1"
printf 'X\n' | splice "$GC_BEGIN" "$GC_END" "$T/bad1" "$T/o" 2>/dev/null && no "duplicate begin accepted" || ok "duplicate begin refused"
{ echo "$GC_BEGIN"; echo body; } > "$T/bad2"
printf 'X\n' | splice "$GC_BEGIN" "$GC_END" "$T/bad2" "$T/o" 2>/dev/null && no "unterminated block accepted" || ok "unterminated block refused"

section "gc_commit: writes, and leaves unmanaged content byte-identical"
printf '[core]\n\tsshCommand = ssh -i ~/.skm/a/id_ed25519\n' | gc_commit 0 && ok "commit succeeded" || no "commit failed"
unmanaged_unchanged && ok "everything outside the markers is unchanged" || no "unmanaged content changed"
git config --file "$HOME/.gitconfig" --list >/dev/null 2>&1 && ok "result parses as git config" || no "result does not parse"
[ "$(git config --file "$HOME/.gitconfig" user.name)" = "Alexy" ] && ok "pre-existing user.name still readable" || no "user.name lost"

section "gc_commit: REFUSES output git cannot parse"
before=$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)
printf '[core\n\tthis is not valid ini\n' | gc_commit 0 2>/dev/null && no "malformed block accepted" || ok "malformed block refused"
[ "$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)" = "$before" ] && ok "~/.gitconfig byte-identical after refusal" || no "file changed on a refused write"

section "gc_commit: REFUSES to shrink below the floor"
printf '[includeIf "gitdir/i:~/a/"]\n\tpath = ~/x.gitconfig\n[includeIf "gitdir/i:~/b/"]\n\tpath = ~/y.gitconfig\n' | gc_commit 2 \
  && ok "two rules accepted with floor 2" || no "floor 2 rejected a valid write"
before=$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)
printf '[core]\n\tsshCommand = ssh\n' | gc_commit 2 2>/dev/null && no "shrink to 0 accepted with floor 2" || ok "shrink below floor refused"
[ "$(shasum -a 256 "$HOME/.gitconfig" | cut -d' ' -f1)" = "$before" ] && ok "file unchanged after a refused shrink" || no "file changed"

section "gc_commit: preserves the file mode"
chmod 0600 "$HOME/.gitconfig"
printf '[core]\n\tsshCommand = ssh\n' | gc_commit 0 >/dev/null
[ "$(stat -f %Lp "$HOME/.gitconfig")" = "600" ] && ok "mode 0600 preserved across a write" || no "mode changed to $(stat -f %Lp "$HOME/.gitconfig")"
chmod 0644 "$HOME/.gitconfig"

section "gc_lock: mutual exclusion, and a stale lock is broken"
: > "$HOME/.gitconfig.lock"
lock_take "$HOME/.gitconfig" 2>/dev/null && { no "took a lock that was already held"; lock_release "$HOME/.gitconfig"; } || ok "refused while the lock was held"
rm -f "$HOME/.gitconfig.lock"
lock_take "$HOME/.gitconfig" && ok "took a free lock" || no "could not take a free lock"
[ -f "$HOME/.gitconfig.lock" ] && ok "lockfile created at git's own path" || no "no lockfile"
lock_release "$HOME/.gitconfig"
[ ! -f "$HOME/.gitconfig.lock" ] && ok "lock released" || no "lock leaked"
: > "$HOME/.gitconfig.lock"; touch -t 202001010000 "$HOME/.gitconfig.lock"
lock_take "$HOME/.gitconfig" && ok "stale lock (>60s) broken rather than wedging" || no "stale lock wedged the tool"
lock_release "$HOME/.gitconfig"

section "concurrent writers: no corruption AND no lost update"
for i in 1 2 3 4 5 6; do
  ( printf '[core]\n\tsshCommand = ssh-%s\n' "$i" | gc_commit 0 >/dev/null 2>&1 ) &
done
wait
git config --file "$HOME/.gitconfig" --list >/dev/null 2>&1 && ok "file still parses after 6 racing writers" || no "concurrent writes corrupted the file"
[ "$(grep -c "$GC_BEGIN" "$HOME/.gitconfig")" = 1 ] && ok "exactly one managed block after the race" || no "block duplicated by the race"
unmanaged_unchanged && ok "unmanaged content survived the race" || no "race clobbered unmanaged content"

# ⚠ THE ONE THAT NEEDS THE LOCK — and it took two wrong tests to find it.
# Atomic mv already prevents corruption, and appends are atomic under PIPE_BUF, so a race
# built from appends passes with every lock deleted. The real hazard is a manifest REWRITE
# (what `remove` must do: read all, filter, swap) racing an append: the append lands
# between the read and the swap and is silently lost.
mkkey racer
printf 'identity\tracer\t\t\t\n' >> "$MANIFEST"
for i in 1 2 3 4 5 6 7 8; do printf 'rule\torg\tracer\tgithub.com\tvictim-%s\n' "$i" >> "$MANIFEST"; done
adder(){   man_lock || return 1; man_add "$(printf 'rule\torg\tracer\tgithub.com\tadded-%s' "$1")"; man_unlock; }
remover(){ man_lock || return 1; man_del "$(printf 'rule\torg\tracer\tgithub.com\tvictim-%s' "$1")"; man_unlock; }
for i in 1 2 3 4 5 6; do adder "$i" & remover "$i" & done
wait
lost=""
for i in 1 2 3 4 5 6; do man_rules org | grep -q "added-$i\$" || lost="$lost added-$i"; done
for i in 7 8;           do man_rules org | grep -q "victim-$i\$" || lost="$lost victim-$i"; done
[ -z "$lost" ] && ok "12 concurrent add/remove cycles, nothing lost" || no "lost update:$lost"
for i in 1 2 3 4 5 6; do man_rules org | grep -q "victim-$i\$" && lost="$lost victim-$i-survived"; done
[ -z "$lost" ] && ok "every removal actually took effect" || no "removal lost:$lost"
apply_all >/dev/null 2>&1
inman=$(man_rules org | grep -c .); ingc=$(grep -c 'hasconfig:remote' "$HOME/.gitconfig")
[ "$inman" = "$ingc" ] && ok "manifest and ~/.gitconfig agree ($inman org rules)" || no "manifest $inman vs gitconfig $ingc"
# reset for the ordering section
man_del "$(printf 'rule\torg\tracer')" ; man_del "$(printf 'identity\tracer')"

section "generated ordering is what git's precedence needs"
mkkey base; mkkey acme
{ printf 'baseline\tbase\n'
  printf 'identity\tbase\t\t\t\n'
  printf 'identity\tacme\t\t\t\n'
  printf 'rule\tdir\tacme\t%s/projects/Acme\n' "$HOME"
  printf 'rule\torg\tacme\tgithub.com\tacme-corp\n'; } >> "$MANIFEST"
gen_gitconfig_block > "$T/blk"
bl=$(grep -n 'sshCommand' "$T/blk" | head -1 | cut -d: -f1)
l1=$(grep -n 'gitdir/i:' "$T/blk" | head -1 | cut -d: -f1)
l2=$(grep -n 'hasconfig:' "$T/blk" | head -1 | cut -d: -f1)
[ -n "$bl" ] && [ -n "$l1" ] && [ -n "$l2" ] && [ "$bl" -lt "$l1" ] && [ "$l1" -lt "$l2" ] \
  && ok "baseline < layer 1 < layer 2 (line $bl < $l1 < $l2)" || no "ordering wrong: baseline=$bl layer1=$l1 layer2=$l2"

section "git itself agrees: the generated rules actually route"
apply_all >/dev/null 2>&1 || no "apply_all failed"
mkrepo "$T/projects/Acme/app" "origin=git@github.com:acme-corp/app.git"
mkrepo "$T/projects/Other/app" "origin=git@github.com:someone-else/app.git"
mkrepo "$T/projects/Acme/norem"
[ "$(resolved "$T/projects/Acme/app")" = "acme" ] && ok "org rule routes to acme" || no "org rule: got '$(resolved "$T/projects/Acme/app")'"
[ "$(resolved "$T/projects/Acme/norem")" = "acme" ] && ok "dir rule covers a repo with no remote" || no "dir rule: got '$(resolved "$T/projects/Acme/norem")'"
[ "$(resolved "$T/projects/Other/app")" = "base" ] && ok "unmatched repo falls to the baseline" || no "baseline: got '$(resolved "$T/projects/Other/app")'"
# Discriminate on `identities/`, NOT on `.gitconfig` — the baseline file is itself
# called .gitconfig, so a *.gitconfig* glob matches it and the assertion is vacuous.
case "$(resolved_by "$T/projects/Other/app")" in
  *identities/*.gitconfig*) no "baseline repo wrongly matched a fragment" ;;
  *) ok "--show-origin names ~/.gitconfig itself for the baseline repo" ;;
esac
case "$(resolved_by "$T/projects/Acme/app")" in *identities/acme.gitconfig*) ok "--show-origin names the acme fragment" ;; *) no "show-origin: $(resolved_by "$T/projects/Acme/app")" ;; esac

section "layer 2 beats layer 1 (org wins over folder)"
mkkey other
printf 'identity\tother\t\t\t\n' >> "$MANIFEST"
printf 'rule\torg\tother\tgithub.com\tvendor-inc\n' >> "$MANIFEST"
apply_all >/dev/null 2>&1
mkrepo "$T/projects/Acme/vendored" "origin=git@github.com:vendor-inc/lib.git"
[ "$(resolved "$T/projects/Acme/vendored")" = "other" ] \
  && ok "a vendor-inc repo inside Acme/ takes the vendor key, not Acme's" \
  || no "layer 2 did not override layer 1: got '$(resolved "$T/projects/Acme/vendored")'"

section "unmanaged content survived every mutation in this suite"
unmanaged_unchanged && ok "still byte-identical to the fixture" || no "unmanaged content drifted"

finish
