#!/bin/bash
# sshid — shared library. Sourced by bin/sshid and the test suites.
#
# THE ONE DANGEROUS THING IN THIS TOOL IS WRITING ~/.gitconfig, so every write in here
# goes through gc_commit(), which validates with git itself, refuses to shrink, holds
# git's own lockfile, and swaps atomically. Nothing else may write that file.

# ── paths ────────────────────────────────────────────────────────────────────────────
# All default off $HOME so a test can fake the whole world with HOME=$(mktemp -d).
# The explicit overrides exist for surgical tests that need one file redirected.
SSHID_CONFDIR="${SSHID_CONFDIR:-$HOME/.config/sshid}"
MANIFEST="${SSHID_MANIFEST:-$SSHID_CONFDIR/identities.map}"
GITCONFIG="${SSHID_GITCONFIG:-$HOME/.gitconfig}"
SSHCONFIG="${SSHID_SSHCONFIG:-$HOME/.ssh/config}"
# Where private keys live. An explicit override wins; otherwise keep an existing store so
# a machine that already has keys somewhere is not orphaned, and fall back to a directory
# sshid owns. sshid never requires any other tool to be installed.
if [ -n "${SSHID_KEYDIR:-}" ]; then KEYDIR="$SSHID_KEYDIR"
elif [ -d "$HOME/.skm" ];      then KEYDIR="$HOME/.skm"
else                                KEYDIR="$HOME/.ssh/sshid"; fi
FRAGDIR="${SSHID_FRAGDIR:-$HOME/.config/git/identities}"
GHMAP="${SSHID_GHMAP:-$FRAGDIR/gh-accounts.map}"
BK="${SSHID_BACKUPS:-$SSHID_CONFDIR/backups}"

GC_BEGIN='# >>> sshid managed block — do not edit by hand; run `sshid` instead >>>'
GC_END='# <<< sshid managed block <<<'
SC_BEGIN='# >>> sshid managed aliases — do not edit by hand; run `sshid` instead >>>'
SC_END='# <<< sshid managed aliases <<<'

SSH_PROBE_OPTS="-o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
# What goes into a fragment. NOT the probe opts: StrictHostKeyChecking=accept-new in a
# routed sshCommand would silently trust a new host key on every git operation.
frag_sshcommand(){ printf 'ssh -i %s -o IdentitiesOnly=yes -o IdentityAgent=none' "$1"; }

# ── colour ───────────────────────────────────────────────────────────────────────────
# Decided ONCE, while stdout is still the terminal. Deciding lazily inside $( ) makes
# [ -t 1 ] false everywhere and silently kills colour (claude-account learned this twice).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then SSHID_COLOUR=1; else SSHID_COLOUR=0; fi
# These RESPECT the colour decision. claude-account has them always emit escapes even
# when piped; that is what made a credential DECISION differ between a terminal and a
# pipe there, and it is why its own test suite passed while doctor lied on a tty.
_c(){ if [ "$SSHID_COLOUR" = 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
red(){ _c 31 "$*"; }
grn(){ _c 32 "$*"; }
yel(){ _c 33 "$*"; }
dim(){ _c 2  "$*"; }
# Pad FIRST, colour after — printf's %-Ns counts escape bytes, so colouring before
# padding breaks every column.
cell(){ local w="$1" s="$2" c="${3:-}" pad; printf -v pad '%-*s' "$w" "$s"
  if [ "$SSHID_COLOUR" = 1 ] && [ -n "$c" ]; then printf '\033[%sm%s\033[0m' "$c" "$pad"; else printf '%s' "$pad"; fi; }

# ── name validation ──────────────────────────────────────────────────────────────────
# Same shape as a Claude profile name and as skm's directory names.
RESERVED_NAMES="none all global default-key"
valid_name(){ [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,38}$ ]]; }
reserved_name(){ case " $RESERVED_NAMES " in *" $1 "*) return 0 ;; esac; return 1; }

# ── locking ──────────────────────────────────────────────────────────────────────────
# git's OWN convention: <file>.lock, created O_EXCL. Using the same path means a
# concurrent `git config` blocks on us and we block on it — which is the point on a
# machine running a dozen agent sessions. `set -o noclobber` gives us O_EXCL in bash.
#
# TWO things need locking, and only locking BOTH is correct. ~/.gitconfig is written
# atomically by mv, so a race there cannot corrupt the file — but it CAN lose an update,
# because every write is read-modify-write. And the manifest is the shared state two
# concurrent `sshid add` runs would both read, both edit, and one would silently win.
# Locks are held in a stack with ONE trap, so a nested take/release cannot clear the
# outer handler and leak the outer lock.
SSHID_LOCKS=()
lock_take(){
  local lock="$1.lock" tries=0 age now mt
  while :; do
    if ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null; then
      SSHID_LOCKS+=("$lock"); trap 'lock_release_all' EXIT INT TERM HUP PIPE; return 0
    fi
    if [ -f "$lock" ]; then
      now=$(date +%s); mt=$(stat -f %m "$lock" 2>/dev/null || echo "$now"); age=$((now - mt))
      # A crashed writer must not wedge the tool forever.
      if [ "$age" -gt 60 ]; then rm -f "$lock" 2>/dev/null; continue; fi
    fi
    tries=$((tries+1))
    [ "$tries" -ge 200 ] && { red "could not lock $1 (held for over 10s)"; return 1; }
    sleep 0.05
  done
}
lock_release(){
  local lock="$1.lock" keep=() l
  rm -f "$lock" 2>/dev/null
  for l in ${SSHID_LOCKS+"${SSHID_LOCKS[@]}"}; do [ "$l" = "$lock" ] || keep+=("$l"); done
  SSHID_LOCKS=(${keep+"${keep[@]}"})
  return 0
}
lock_release_all(){ local l; for l in ${SSHID_LOCKS+"${SSHID_LOCKS[@]}"}; do rm -f "$l" 2>/dev/null; done
  SSHID_LOCKS=(); trap - EXIT INT TERM HUP PIPE; return 0; }
# Every mutating command wraps its whole read-modify-write in this.
man_lock(){ mkdir -p "$SSHID_CONFDIR" 2>/dev/null; lock_take "$MANIFEST"; }
man_unlock(){ lock_release "$MANIFEST"; }

# ── backups ──────────────────────────────────────────────────────────────────────────
# Before EVERY mutation. Never private keys — names and fingerprints only.
backup(){
  local label="${1:-change}" stamp dest
  stamp=$(date +%Y%m%d-%H%M%S); dest="$BK/$stamp-$label"
  mkdir -p "$dest" 2>/dev/null || return 0
  [ -f "$GITCONFIG" ] && cp "$GITCONFIG" "$dest/gitconfig" 2>/dev/null
  [ -f "$SSHCONFIG" ] && cp "$SSHCONFIG" "$dest/ssh_config" 2>/dev/null
  [ -f "$MANIFEST" ]  && cp "$MANIFEST"  "$dest/identities.map" 2>/dev/null
  [ -f "$GHMAP" ]     && cp "$GHMAP"     "$dest/gh-accounts.map" 2>/dev/null
  if [ -d "$FRAGDIR" ]; then mkdir -p "$dest/identities"
    cp "$FRAGDIR"/*.gitconfig "$dest/identities/" 2>/dev/null || true; fi
  # fingerprints only, never key material
  if [ -d "$KEYDIR" ]; then : > "$dest/keys.manifest"
    local d n k
    for d in "$KEYDIR"/*/; do [ -d "$d" ] || continue; n=$(basename "$d")
      k=$(keyfile_for "$n"); [ -n "$k" ] || continue
      printf '%s\t%s\n' "$n" "$(ssh-keygen -lf "$k.pub" 2>/dev/null || echo unreadable)" >> "$dest/keys.manifest"
    done; fi
  chmod -R go-rwx "$dest" 2>/dev/null || true
  printf '%s\n' "$dest"
}

keyfile_for(){ # <identity> -> absolute path of the private key, or empty
  local d="$KEYDIR/$1" f
  for f in "$d"/id_ed25519 "$d"/id_rsa "$d"/id_ecdsa; do [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done
  # any other id_* that is not a .pub
  f=$(ls "$d"/id_* 2>/dev/null | grep -v '\.pub$' | head -1)
  [ -n "$f" ] && printf '%s\n' "$f"
}

# ── manifest ─────────────────────────────────────────────────────────────────────────
# TAB-separated, record type first. TAB because project paths contain spaces.
#   identity <name> <keyfile> <github-account> <gitlab-account>
#   baseline <name>
#   rule dir <name> <path>
#   rule org <name> <host> <org>
#   alias <name> <host> <aliasname>
#   ghid <name> <gh-account>
#   ghorg <org> <gh-account>
man_init(){ mkdir -p "$SSHID_CONFDIR" "$BK"; [ -f "$MANIFEST" ] || {
    printf '# sshid manifest — the source of truth for the managed block in ~/.gitconfig.\n' > "$MANIFEST"
    printf '# TAB separated. Edit with `sshid`, not by hand.\n' >> "$MANIFEST"
    chmod 0600 "$MANIFEST"; }; }
# Read records of a given type. Comment- and blank-guarded, like every reader here.
man_get(){ local t="$1"; [ -f "$MANIFEST" ] || return 0
  while IFS=$'\t' read -r kind rest || [ -n "${kind:-}" ]; do
    case "$kind" in ''|\#*) continue ;; esac
    [ "$kind" = "$t" ] && printf '%s\n' "$rest"
  done < "$MANIFEST"; }
man_field(){ printf '%s' "$1" | cut -f"$2"; }
man_names(){ man_get identity | cut -f1; }
# No pipeline in the test at all — belt and braces against the pipefail trap above, and
# it is what every command's "does this identity exist" check runs through.
man_has(){ local all; all=$(man_names); case $'\n'"$all"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }
man_baseline(){ man_get baseline | head -1 | cut -f1; }
# Rule records are `rule <subtype> ...`, so the subtype is field 1 of the rest.
man_rules(){ local sub="$1" r
  man_get rule | while IFS= read -r r || [ -n "${r:-}" ]; do
    [ -n "$r" ] || continue
    [ "$(printf '%s' "$r" | cut -f1)" = "$sub" ] && printf '%s\n' "$(printf '%s' "$r" | cut -f2-)"
  done
  return 0
}

# Pull the identity name out of a resolved core.sshCommand. The name is the directory the
# key sits in, so this works for ANY key store: matching a literal path (".skm") hardcodes
# one layout and silently returns empty for every other one.
ident_from_cmd(){
  local k; k=$(printf '%s' "$1" | sed -n 's|.*-i \([^ ]*\).*|\1|p')
  [ -n "$k" ] || return 0
  k=${k%/*}          # strip the key filename
  printf '%s' "${k##*/}"
}

# ── repo discovery ───────────────────────────────────────────────────────────────────
# ⚠ NO -maxdepth. The scripts this replaces capped at 5, which hid 82 of 226 repos on
# this machine — including a live ssh:// remote the ssh:// guard was written for, so that
# guard reported "clean" precisely where it could not see. Prune vendored trees by name
# instead: that excludes noise without inventing a depth horizon.
SSHID_PRUNE="${SSHID_PRUNE:-node_modules .build build _deps dbt_packages SourcePackages Pods vendor .venv target Carthage DerivedData}"
# Where to look for repositories. NOT a hardcoded personal layout: prefer the folders the
# user actually has directory rules for, then fall back to the usual places people keep
# code. Scanning all of $HOME would be correct and unusably slow.
sshid_default_roots(){
  local seen="" d p
  # every directory rule's path, deduped to its top level
  while IFS= read -r p; do [ -n "$p" ] || continue
    d=$(printf '%s' "$p" | cut -f2)
    [ -d "$d" ] || continue
    case " $seen " in *" $d "*) ;; *) seen="$seen $d" ;; esac
  done < <(man_rules dir 2>/dev/null)
  for d in "$HOME/workspace/projects" "$HOME/workspace" "$HOME/projects" "$HOME/src" \
           "$HOME/code" "$HOME/dev" "$HOME/repos" "$HOME/git" "$HOME/Developer"; do
    [ -d "$d" ] && seen="$seen $d"
  done
  # Drop any root that lives inside another root, or the walk visits it twice and every
  # repository is reported once per containing root.
  local out="" a b nested
  for a in $seen; do
    nested=0
    for b in $seen; do [ "$a" = "$b" ] && continue; case "$a" in "$b"/*) nested=1 ;; esac; done
    [ "$nested" = 0 ] && case " $out " in *" $a "*) ;; *) out="$out $a" ;; esac
  done
  printf '%s' "${out# }"
}
repos(){
  local root p args=() first=1
  local roots="${SSHID_ROOTS:-$(sshid_default_roots)}"
  for p in $SSHID_PRUNE; do
    if [ $first = 1 ]; then args+=( -name "$p" ); first=0; else args+=( -o -name "$p" ); fi
  done
  for root in $roots; do
    [ -d "$root" ] || continue
    find "$root" \( "${args[@]}" \) -prune -o -name .git -print 2>/dev/null
  done | while IFS= read -r g; do [ -n "$g" ] && dirname "$g"; done | sort -u
}
# Every remote url of every repo: "<repo>\t<remote>\t<url>". ALL remotes, not just
# origin — a repo whose origin is GitLab can still carry a github remote that needs
# routing, and origin-only audits missed exactly that.
remotes(){
  local r k u
  repos | while IFS= read -r r; do
    git -C "$r" config --get-regexp '^remote\..*\.url$' 2>/dev/null | while read -r k u; do
      printf '%s\t%s\t%s\n' "$r" "${k#remote.}" "$u"
    done
  done
}

# ── manifest mutation ────────────────────────────────────────────────────────────────
# An APPEND is atomic under PIPE_BUF and needs no lock. A REWRITE does not: it reads the
# whole file, filters, and swaps — so an append landing between the read and the swap is
# silently lost. Every rewrite therefore takes the manifest lock, and so must any caller
# doing add-then-rewrite as one logical operation.
man_add(){ man_init; printf '%s\n' "$*" >> "$MANIFEST"; }
# Drop every record whose leading fields match the TAB-joined prefix given.
man_del(){
  local pref="$1" tmp line kept=0
  [ -f "$MANIFEST" ] || return 0
  tmp=$(mktemp "${MANIFEST}.XXXXXX") || return 1
  # READ FIRST, write to a temp, then swap — never open the live file for writing.
  while IFS= read -r line || [ -n "${line:-}" ]; do
    case "$line" in "$pref"|"$pref"$'\t'*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp"; kept=$((kept+1))
  done < "$MANIFEST"
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$MANIFEST"
}

# ── the managed-block splice ─────────────────────────────────────────────────────────
# Replace the region between the markers in $2, from the block on stdin, writing the
# result to $3. Appends the block if the markers are absent. REFUSES a malformed file.
splice(){ # <begin> <end> <src-file-or-empty> <out-file> ; block on stdin
  local b="$1" e="$2" src="$3" out="$4" blk seen_b=0 seen_e=0 line
  blk=$(cat)
  : > "$out"
  if [ -n "$src" ] && [ -f "$src" ]; then
    # validate marker structure first
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$line" = "$b" ] && seen_b=$((seen_b+1))
      [ "$line" = "$e" ] && seen_e=$((seen_e+1))
    done < "$src"
    if [ "$seen_b" -gt 1 ] || [ "$seen_e" -gt 1 ] || [ "$seen_b" != "$seen_e" ]; then
      red "refusing to write: $src has malformed sshid markers (begin=$seen_b end=$seen_e)"
      red "  fix it by hand, or remove both markers and re-run \`sshid adopt\`"
      return 1
    fi
    if [ "$seen_b" = 1 ]; then
      local inside=0
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$b" ]; then inside=1; printf '%s\n' "$b" >> "$out"; printf '%s\n' "$blk" >> "$out"; continue; fi
        if [ "$line" = "$e" ]; then inside=0; printf '%s\n' "$e" >> "$out"; continue; fi
        [ "$inside" = 1 ] && continue
        printf '%s\n' "$line" >> "$out"
      done < "$src"
      return 0
    fi
    cat "$src" >> "$out"
    # NEVER add a separator here: a blank line emitted outside the markers counts as
    # unmanaged content and would make the first write mutate the user's own config.
    # Only guarantee the file ends with a newline so the marker starts its own line.
    [ -s "$out" ] && [ -n "$(tail -c 1 "$out")" ] && printf '\n' >> "$out"
  fi
  { printf '%s\n' "$b"; printf '%s\n' "$blk"; printf '%s\n' "$e"; } >> "$out"
}

# ── the ONE writer for ~/.gitconfig ──────────────────────────────────────────────────
# stdin: the block body (without markers). $1: minimum `path =` lines expected.
# Validate with git, refuse to shrink, lock, swap atomically. Any failure leaves the
# original byte-identical.
gc_commit(){
  local floor="${1:-0}" blk tmp got mode rc=0
  blk=$(cat)
  mkdir -p "$(dirname "$GITCONFIG")" 2>/dev/null || true
  lock_take "$GITCONFIG" || return 1
  tmp=$(mktemp "${GITCONFIG}.sshid.XXXXXX") || { lock_release "$GITCONFIG"; return 1; }
  if ! printf '%s' "$blk" | splice "$GC_BEGIN" "$GC_END" "$GITCONFIG" "$tmp"; then
    rm -f "$tmp"; lock_release "$GITCONFIG"; return 1
  fi
  # 1. IT MUST PARSE. We never install a ~/.gitconfig git cannot read — that would
  #    break every git command on the machine, not just ours.
  if ! git config --file "$tmp" --list >/dev/null 2>&1; then
    red "refusing to write: the generated ~/.gitconfig does not parse"
    git config --file "$tmp" --list 2>&1 | head -3 | sed 's/^/  /'
    rm -f "$tmp"; lock_release "$GITCONFIG"; return 1
  fi
  # 2. IT MUST NOT SHRINK. claude-account wiped every rule twice this way.
  # grep -c PRINTS 0 and EXITS 1 on no match. `|| echo 0` therefore appended a second
  # line, `[ "0\n0" -lt N ]` errored, and the floor guard silently never fired.
  got=$(grep -c '^[[:space:]]*path = ' "$tmp" 2>/dev/null); got=${got:-0}
  if [ "$got" -lt "$floor" ]; then
    red "refusing to write: only $got routing rules, expected at least $floor"
    rm -f "$tmp"; lock_release "$GITCONFIG"; return 1
  fi
  if [ -f "$GITCONFIG" ]; then
    mode=$(stat -f %Lp "$GITCONFIG" 2>/dev/null || echo 644); chmod "$mode" "$tmp" 2>/dev/null || true
  else chmod 0644 "$tmp" 2>/dev/null || true; fi
  mv -f "$tmp" "$GITCONFIG" || rc=1
  lock_release "$GITCONFIG"
  return $rc
}

# ── the writer for ~/.ssh/config ─────────────────────────────────────────────────────
sc_commit(){
  local blk tmp mode rc=0
  blk=$(cat)
  mkdir -p "$(dirname "$SSHCONFIG")" 2>/dev/null || true; chmod 0700 "$(dirname "$SSHCONFIG")" 2>/dev/null || true
  lock_take "$SSHCONFIG" || return 1
  tmp=$(mktemp "${SSHCONFIG}.sshid.XXXXXX") || { lock_release "$SSHCONFIG"; return 1; }
  if ! printf '%s' "$blk" | splice "$SC_BEGIN" "$SC_END" "$SSHCONFIG" "$tmp"; then
    rm -f "$tmp"; lock_release "$GITCONFIG"; return 1
  fi
  if [ -f "$SSHCONFIG" ]; then
    mode=$(stat -f %Lp "$SSHCONFIG" 2>/dev/null || echo 600); chmod "$mode" "$tmp" 2>/dev/null || true
  else chmod 0600 "$tmp" 2>/dev/null || true; fi
  mv -f "$tmp" "$SSHCONFIG" || rc=1
  lock_release "$SSHCONFIG"
  return $rc
}

# ── generators ───────────────────────────────────────────────────────────────────────
# The gitconfig block. ORDER IS THE WHOLE POINT: baseline, then every directory rule,
# then every org rule. Precedence here is positional — last match wins — so org must
# sit below folder, and the baseline above both or it clobbers everything.
gen_gitconfig_block(){
  local base r n p h o
  base=$(man_baseline)
  if [ -n "$base" ]; then
    printf '# baseline — every repo no rule below matches lands here.\n'
    printf '[core]\n\tsshCommand = %s\n' "$(frag_sshcommand "$(fragkey "$base")")"
  fi
  printf '\n# --- layer 1: directory rules (a folder is this client) ---\n'
  while IFS= read -r r; do [ -n "$r" ] || continue
    n=$(man_field "$r" 1); p=$(man_field "$r" 2)
    printf '[includeIf "gitdir/i:%s"]\n\tpath = %s/%s.gitconfig\n' "${p%/}/" "$(tilde "$FRAGDIR")" "$n"
  done < <(man_rules dir)
  printf '\n# --- layer 2: org rules (the remote is ground truth; BELOW layer 1 so org wins) ---\n'
  while IFS= read -r r; do [ -n "$r" ] || continue
    n=$(man_field "$r" 1); h=$(man_field "$r" 2); o=$(man_field "$r" 3)
    printf '[includeIf "hasconfig:remote.*.url:git@%s:%s/**"]\n\tpath = %s/%s.gitconfig\n' "$h" "$o" "$(tilde "$FRAGDIR")" "$n"
  done < <(man_rules org)
}
tilde(){ case "$1" in "$HOME"/*) printf '~%s' "${1#$HOME}" ;; *) printf '%s' "$1" ;; esac; }
fragkey(){ local k; k=$(keyfile_for "$1"); [ -n "$k" ] && tilde "$k" || printf '%s/%s/id_rsa' "$(tilde "$KEYDIR")" "$1"; }

gen_ssh_block(){
  local r n h a k
  while IFS= read -r r; do [ -n "$r" ] || continue
    n=$(man_field "$r" 1); h=$(man_field "$r" 2); a=$(man_field "$r" 3)
    k=$(fragkey "$n")
    printf 'Host %s\n    HostName %s\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n    IdentityAgent none\n\n' "$a" "$h" "$k"
  done < <(man_get alias 2>/dev/null || true)
}

write_fragments(){
  local n k
  mkdir -p "$FRAGDIR" 2>/dev/null
  while IFS= read -r n; do [ -n "$n" ] || continue
    k=$(fragkey "$n")
    { printf '# Identity: %s — managed by sshid. Edit with `sshid`, not by hand.\n' "$n"
      printf '[core]\n\tsshCommand = %s\n' "$(frag_sshcommand "$k")"
      printf '# [user]\n#\temail = you@example.com\n#\tname = Your Name\n'
    } > "$FRAGDIR/$n.gitconfig"
    chmod 0644 "$FRAGDIR/$n.gitconfig" 2>/dev/null || true
  done < <(man_names)
}

write_ghmap(){
  local r
  mkdir -p "$FRAGDIR" 2>/dev/null
  { printf '# gh account map — managed by sshid. Edit with `sshid gh`, not by hand.\n'
    printf '# [org] is consulted BEFORE [identity], so an org always wins.\n\n'
    printf '[identity]\n'
    while IFS= read -r r; do [ -n "$r" ] || continue
      printf '%s\t%s\n' "$(man_field "$r" 1)" "$(man_field "$r" 2)"
    done < <(man_get ghid 2>/dev/null || true)
    printf '\n[org]\n'
    while IFS= read -r r; do [ -n "$r" ] || continue
      printf '%s\t%s\n' "$(man_field "$r" 1)" "$(man_field "$r" 2)"
    done < <(man_get ghorg 2>/dev/null || true)
  } > "$GHMAP"
  chmod 0600 "$GHMAP" 2>/dev/null || true
}

# Apply the whole manifest to disk. One entry point, so no caller can write half of it.
apply_all(){
  local floor
  local d o; d=$(man_rules dir | grep -c . ); o=$(man_rules org | grep -c . )
  floor=$(( ${d:-0} + ${o:-0} ))
  write_fragments
  write_ghmap
  gen_ssh_block | sc_commit || return 1
  gen_gitconfig_block | gc_commit "$floor" || return 1
}
