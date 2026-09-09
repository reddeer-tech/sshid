#!/bin/bash
# The gh shim. Everything here is about NOT breaking someone's gh:
# it must never mutate global state, never hijack a command it should pass through,
# never hang, and never require a re-login.
. "$(dirname "$0")/lib.sh"
sshid_sandbox

# A fake "real gh" that reports exactly what it was handed. It must NOT carry the shim's
# header line, or the shim would skip it while looking for the real binary.
mkdir -p "$T/realbin" "$T/shimbin"
cat > "$T/realbin/gh" <<'STUB'
#!/bin/bash
# `auth token` prints ONLY the token: the shim captures this stdout, so any banner here
# would be swallowed into the value and exported as GH_TOKEN.
case "$1 $2" in
  "auth token") shift 2; u=""; while [ $# -gt 0 ]; do [ "$1" = "-u" ] && u="$2"; shift; done
                case " ${GH_ACCOUNTS:-} " in *" $u "*) echo "tok_$u"; exit 0 ;; esac; exit 1 ;;
esac
echo "REAL_GH argv=$*"
echo "REAL_GH token=${GH_TOKEN:-<none>}"
exit 0
STUB
chmod +x "$T/realbin/gh"
install -m 0755 "$REPO/libexec/gh-shim" "$T/shimbin/gh"
export SSHID_LIB="$REPO/libexec"
export GH_ACCOUNTS="acct-tl acct-personal"
export SSHID_GH_BIN="$T/realbin/gh"
SH="$T/shimbin/gh"
run(){ PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" "$SH" "$@" 2>&1; }

section "it finds the real gh and hands off"
run --version | grep -q 'REAL_GH argv=--version' && ok "passes --version through" || no "did not reach the real gh"

section "it never mutates global state"
# The whole design rests on this: no hosts.yml write, no active-account move.
mkdir -p "$T/.config/gh"; printf 'github.com:\n    user: someone\n' > "$T/.config/gh/hosts.yml"
before=$(shasum -a 256 "$T/.config/gh/hosts.yml" | cut -d' ' -f1)
run auth status >/dev/null; run pr list >/dev/null; run --version >/dev/null
[ "$(shasum -a 256 "$T/.config/gh/hosts.yml" | cut -d' ' -f1)" = "$before" ] && ok "hosts.yml byte-identical after routed calls" || no "HOSTS.YML WAS MODIFIED"

section "auth / config / version pass through untouched"
for c in "auth status" "auth login" "config get x" "version"; do
  run $c | grep -q "REAL_GH argv=$c" && ok "'$c' passed through" || no "'$c' was intercepted"
done
# `auth token` reaches the real gh unmodified — asserted on its VALUE, because the stub
# prints only the token for that subcommand (anything else would be captured as the token).
[ "$(run auth token -u acct-tl)" = "tok_acct-tl" ] && ok "'auth token' passed through" || no "'auth token' was intercepted"
run auth status | grep -q 'token=<none>' && ok "auth status gets NO injected token (must show real state)" || no "auth status got a token"

section "gh auth switch is refused — it flips one global account for every project"
out=$(run auth switch --user acct-personal); rc=$?
[ "$rc" = 2 ] && ok "exit 2" || no "exit $rc"
printf '%s' "$out" | grep -q 'refusing' && ok "says why" || no "no refusal message"
printf '%s' "$out" | grep -q 'REAL_GH' && no "reached the real gh anyway" || ok "never reached the real gh"
GH_ALLOW_AUTH_SWITCH=1 PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" "$SH" auth switch 2>&1 | grep -q REAL_GH \
  && ok "GH_ALLOW_AUTH_SWITCH=1 is a real escape hatch" || no "escape hatch does not work"

section "the ALIAS bypass is closed"
# gh expands aliases INSIDE the real binary, after we exec — so `gh <alias>` where the
# alias expands to `auth switch` walks straight past a $1/$2 test. Both doors are shut.
printf 'aliases:\n    sw: auth switch\n    co: pr checkout\n' > "$T/.config/gh/config.yml"
out=$(GH_CONFIG_DIR="$T/.config/gh" PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" "$SH" sw --user x 2>&1)
printf '%s' "$out" | grep -q 'refusing' && ok "invoking an alias that expands to auth switch is refused" || no "ALIAS BYPASS OPEN: $out"
out=$(GH_CONFIG_DIR="$T/.config/gh" PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" "$SH" alias set sw 'auth switch' 2>&1)
printf '%s' "$out" | grep -q 'refusing' && ok "creating such an alias is refused" || no "alias creation not guarded"
out=$(GH_CONFIG_DIR="$T/.config/gh" PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" "$SH" co 2>&1)
printf '%s' "$out" | grep -q REAL_GH && ok "a harmless alias still works" || no "harmless alias broken"

section "-R routes by org — including the attached form the old shim silently missed"
printf '[identity]\nacme\tacct-tl\n\n[org]\nacme-corp\tacct-tl\n' > "$T/.config/git/identities/gh-accounts.map"
export SSHID_GHMAP="$T/.config/git/identities/gh-accounts.map"
for form in "-R acme-corp/app" "--repo acme-corp/app" "--repo=acme-corp/app" "-Racme-corp/app"; do
  out=$(PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" SSHID_GHMAP="$SSHID_GHMAP" "$SH" pr list $form 2>&1)
  printf '%s' "$out" | grep -q 'token=tok_acct-tl' && ok "routed: gh pr list $form" || no "NOT routed: $form"
done
out=$(PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" SSHID_GHMAP="$SSHID_GHMAP" "$SH" pr list -R unmapped-org/app 2>&1)
printf '%s' "$out" | grep -q 'token=<none>' && ok "an unmapped org injects no token" || no "unmapped org got a token"

section "an explicit GH_TOKEN always wins — never fight a deliberate choice"
out=$(GH_TOKEN=mine PATH="$T/shimbin:$T/realbin:/usr/bin:/bin" "$SH" pr list -R acme-corp/app 2>&1)
printf '%s' "$out" | grep -q 'token=mine' && ok "GH_TOKEN passes through unchanged" || no "GH_TOKEN was overwritten"

section "no gh installed: a clear message, not a hang and not a fake gh"
out=$(SSHID_GH_BIN=/nonexistent/gh PATH="$T/shimbin:/usr/bin:/bin" "$SH" pr list 2>&1); rc=$?
[ "$rc" = 127 ] && ok "exit 127, like any missing command" || no "exit $rc"
printf '%s' "$out" | grep -q 'does not bundle it' && ok "says we route gh but do not ship it" || no "unclear message"

section "a symlink pointing back at the shim does not fork-bomb"
# The mitigation the old docs proposed. String comparison selected the symlink as the
# "real" gh and the shim exec'd itself forever; -ef resolves the link and skips it.
mkdir -p "$T/linkbin"; ln -sf "$T/shimbin/gh" "$T/linkbin/gh"
unset SSHID_GH_BIN   # this section is about the SEARCH, so let it run
TIMEOUT=$(command -v timeout || command -v gtimeout || echo "")
if [ -n "$TIMEOUT" ]; then
  out=$(PATH="$T/shimbin:$T/linkbin:$T/realbin:/usr/bin:/bin" "$TIMEOUT" 10 "$SH" --version 2>&1); rc=$?
else out=$(PATH="$T/shimbin:$T/linkbin:$T/realbin:/usr/bin:/bin" "$SH" --version 2>&1); rc=$?; fi
[ "$rc" != 124 ] && ok "did not loop (exit $rc)" || no "FORK BOMB — timed out"
# NOT asserted against the stub: with the pin removed the search correctly prefers a real
# compiled gh over a script, so on a machine that has gh it reaches the genuine binary —
# which is the behaviour we want. The invariant is that it got PAST the symlink to a
# working gh and produced version output, rather than looping or dying.
{ printf '%s' "$out" | grep -qE 'REAL_GH|gh version'; } && [ "$rc" = 0 ] \
  && ok "reached a working gh past the symlink (exit 0)" || no "did not reach a working gh: rc=$rc out=$out"

finish
