#!/bin/bash
# Install sshid from a source checkout. Homebrew and npm users do not need this.
set -eu
BINDIR="${BINDIR:-$HOME/.local/bin}"
LIBDIR="${LIBDIR:-$HOME/.config/sshid}"
here="$(cd "$(dirname "$0")" && pwd)"
quiet=0
case "${1:-}" in --quiet|--npm) quiet=1 ;; esac

mkdir -p "$BINDIR" "$LIBDIR"
install -m 0755 "$here/bin/sshid"          "$BINDIR/sshid"
install -m 0644 "$here/libexec/lib.sh"     "$LIBDIR/lib.sh"
install -m 0755 "$here/libexec/resolve.sh" "$LIBDIR/resolve.sh"
install -m 0755 "$here/libexec/gh-shim"    "$LIBDIR/gh-shim"

[ "$quiet" = 1 ] && exit 0
echo "installed sshid -> $BINDIR/sshid"
# Check the LOGIN shell's PATH, not this one: this script may have been run from a shell
# with a hand-edited PATH, which tells the user nothing about their day-to-day setup.
if ! "$SHELL" -lc 'command -v sshid' >/dev/null 2>&1; then
  echo
  echo "⚠ $BINDIR is not on your login shell's PATH. Add to ~/.zshenv:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo
echo "next:"
echo "  sshid setup     # install the resolver, and the gh shim if you have gh"
echo "  sshid adopt     # import the routing already on this machine"
echo "  sshid doctor"
