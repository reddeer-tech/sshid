#!/bin/bash
# backup / restore — moving to another machine. This bundle carries PRIVATE KEYS, which is
# the opposite of `export`, so the tests are weighted toward what must never leak.
. "$(dirname "$0")/lib.sh"
sshid_sandbox
X(){ SSHID_LIB="$REPO/libexec" /bin/bash "$S" "$@"; }
export SSHID_ROOTS="$HOME/projects"

X create work >/dev/null 2>&1
X create personal --type=rsa >/dev/null 2>&1
X bind work --dir "$HOME/projects/Work" >/dev/null 2>&1
X baseline personal >/dev/null 2>&1
fp_work=$(ssh-keygen -lf "$HOME/.skm/work/id_ed25519.pub" 2>/dev/null | awk '{print $2}')
[ -z "$fp_work" ] && fp_work=$(ssh-keygen -lf "$HOME/.ssh/sshid/work/id_ed25519.pub" 2>/dev/null | awk '{print $2}')

section "backup writes a bundle, 0600, and refuses to clobber"
X backup "$T/b.tar.gz" >/dev/null 2>&1
[ -f "$T/b.tar.gz" ] && ok "bundle written" || no "no bundle"
[ "$(stat -f %Lp "$T/b.tar.gz")" = "600" ] && ok "mode 0600" || no "mode $(stat -f %Lp "$T/b.tar.gz")"
X backup "$T/b.tar.gz" >/dev/null 2>&1 && no "overwrote an existing file" || ok "refuses to overwrite"
tar -tzf "$T/b.tar.gz" | grep -q 'MANIFEST' && ok "carries a MANIFEST" || no "no MANIFEST"
tar -xzOf "$T/b.tar.gz" 2>/dev/null | grep -qa 'PRIVATE KEY' && ok "carries the private keys (that is the point)" || no "no keys in the bundle"

section "a path is optional, and you are always told where it went"
out=$(X backup 2>&1)
f=$(printf '%s' "$out" | grep -oE "$HOME/sshid-backup-[0-9-]+\.tar\.gz" | head -1)
[ -n "$f" ] && [ -f "$f" ] && ok "no path: defaults under \$HOME and names the file" || no "no default file: $out"
[ "$(stat -f %Lp "$f" 2>/dev/null)" = "600" ] && ok "the default bundle is 0600 too" || no "mode $(stat -f %Lp "$f" 2>/dev/null)"
case "$f" in "$HOME/.config/"*) no "defaulted inside the config dir, which gets copied around" ;; *) ok "not inside the config dir" ;; esac
printf '%s' "$out" | grep -qE '[0-9]+ bytes' && ok "reports the size" || no "no size reported"
rm -f "$f"
out=$(X export "$T/exp-to-file.tsv" 2>&1)
[ -f "$T/exp-to-file.tsv" ] && ok "export takes a path too" || no "export to a file failed"
printf '%s' "$out" | grep -q "$T/exp-to-file.tsv" && ok "and names the file it wrote" || no "did not name the file"
X export "$T/exp-to-file.tsv" >/dev/null 2>&1 && no "export overwrote an existing file" || ok "export refuses to overwrite"
X export 2>/dev/null | head -1 | grep -q 'sshid export' && ok "with no path it still goes to stdout, so it stays pipeable" || no "stdout form broken"

section "export, by contrast, must NEVER carry key material"
X export > "$T/e.tsv" 2>/dev/null
grep -qaE 'PRIVATE KEY|BEGIN OPENSSH' "$T/e.tsv" && no "EXPORT LEAKED A PRIVATE KEY" || ok "export has no key material"

section "--encrypt really encrypts"
printf 'pw123\n' | X backup "$T/enc.bin" --encrypt >/dev/null 2>&1
[ -f "$T/enc.bin" ] && ok "encrypted bundle written" || no "not written"
tar -tzf "$T/enc.bin" >/dev/null 2>&1 && no "STILL A READABLE TAR — not encrypted" || ok "not readable as a tar"
grep -qa 'PRIVATE KEY' "$T/enc.bin" && no "PRIVATE KEY VISIBLE IN THE CIPHERTEXT" || ok "no plaintext key material"
[ "$(stat -f %Lp "$T/enc.bin")" = "600" ] && ok "mode 0600" || no "mode $(stat -f %Lp "$T/enc.bin")"

section "restore on a fresh machine"
# A second sandbox standing in for the other machine.
OLDHOME="$HOME"; B=$(mktemp -d); B=$(cd "$B" && pwd -P)
cp -R "$OLDHOME/bin" "$B/bin" 2>/dev/null; printf '[user]\n\tname = D\n' > "$B/.gitconfig"
export HOME="$B" XDG_CONFIG_HOME="$B/.config"
X restore "$T/b.tar.gz" --dry-run >/dev/null 2>&1 && ok "--dry-run succeeds" || no "--dry-run failed"
[ -d "$B/.skm/work" ] || [ -d "$B/.ssh/sshid/work" ] && no "--dry-run wrote something" || ok "--dry-run wrote nothing"
X restore "$T/b.tar.gz" >/dev/null 2>&1 && ok "restore succeeded" || no "restore failed"
k="$B/.skm/work/id_ed25519"; [ -f "$k" ] || k="$B/.ssh/sshid/work/id_ed25519"
[ "$(ssh-keygen -lf "$k.pub" 2>/dev/null | awk '{print $2}')" = "$fp_work" ] && ok "the restored key is byte-for-byte the same key" || no "different key"
[ "$(stat -f %Lp "$k")" = "600" ] && ok "restored key is 0600" || no "restored key mode $(stat -f %Lp "$k")"
X list --no-count 2>/dev/null | grep -q personal && ok "both identities restored" || no "identities missing"
X baseline 2>/dev/null | grep -q personal && ok "the baseline came across" || no "baseline lost"
grep -q "$B" "$B/.config/sshid/identities.map" && ok "key paths rewritten for THIS machine" || no "key paths still point at the old machine"
mkrepo "$B/projects/Work/repo"
[ "$(resolved "$B/projects/Work/repo")" = work ] && ok "folder bindings relocated to the new home and work" || no "got: $(resolved "$B/projects/Work/repo")"
grep -q "	$B/projects/Work\$" "$B/.config/sshid/identities.map" && ok "the binding path was rewritten, not left pointing at the old machine" || no "binding still points elsewhere: $(grep '^rule	dir' "$B/.config/sshid/identities.map" | cut -f4)"

section "a wrong passphrase restores nothing"
C=$(mktemp -d); C=$(cd "$C" && pwd -P); cp -R "$B/bin" "$C/bin" 2>/dev/null
printf '[user]\n\tname = D\n' > "$C/.gitconfig"; export HOME="$C" XDG_CONFIG_HOME="$C/.config"
printf 'wrong\n' | X restore "$T/enc.bin" >/dev/null 2>&1 && no "accepted a wrong passphrase" || ok "wrong passphrase refused"
{ [ -d "$C/.skm" ] || [ -d "$C/.ssh/sshid" ]; } && no "a failed restore left key material behind" || ok "nothing written on a failed restore"
printf 'pw123\n' | X restore "$T/enc.bin" >/dev/null 2>&1 && ok "the right passphrase restores" || no "correct passphrase failed"

section "restore does not silently clobber existing keys"
before=$(ssh-keygen -lf "$C/.skm/work/id_ed25519.pub" 2>/dev/null || ssh-keygen -lf "$C/.ssh/sshid/work/id_ed25519.pub" 2>/dev/null)
X restore "$T/b.tar.gz" >/dev/null 2>&1
after=$(ssh-keygen -lf "$C/.skm/work/id_ed25519.pub" 2>/dev/null || ssh-keygen -lf "$C/.ssh/sshid/work/id_ed25519.pub" 2>/dev/null)
[ "$before" = "$after" ] && ok "an existing identity is left alone without --force" || no "clobbered without --force"
export HOME="$OLDHOME"; rm -rf "$B" "$C"

finish
