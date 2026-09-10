# sshid

Multiple SSH identities on one machine, picked per repository by git itself.

If you have more than one SSH key — a personal account and a work one, several
organisations, a fork you push under a different name — every repository needs the right
key, and `gh` needs the right login. The usual approach is to switch something global
before starting work. That breaks as soon as two repositories are open at once: whichever
switch ran last wins, and a push goes out under the wrong account.

`sshid` removes the switch. Which key a repository uses is a function of the repository
itself — where it lives and which organisation its remote belongs to. Nothing to set
beforehand, nothing to remember, and nothing two terminals can race over.

```
$ sshid whoami
  identity       work                  (matched a rule)
  key            ~/.ssh/sshid/work/id_ed25519
  decided by     ~/.config/git/identities/work.gitconfig
  gh account     octo-work             (org 'example-org')
```

## Install

```sh
brew install reddeer-tech/tap/sshid
npm install -g ssh-persona              # the npm package; the command it installs is `sshid`
```

The npm package is published as `ssh-persona` because npm blocks short `ssh`-prefixed
names as possible typosquats. The command it installs is `sshid`, which is what you type.

Then:

```sh
sshid setup     # installs the gh shim, if you have gh
sshid adopt     # imports any routing already on this machine
sshid doctor
```

Installing the package on its own changes nothing — `setup` is the opt-in, and it is what
puts the `gh` shim on your PATH.

SSH routing works without `setup`: `sshid create` and `sshid bind` write git config directly,
and git picks the key up on the next command. `setup` is what you need for the **`gh` half**,
because routing `gh` means putting a shim ahead of it on PATH, and no package install should
do that to you silently. Run it unless you have no use for `gh`.

## How it works

Two layers of `includeIf` in `~/.gitconfig`, which git evaluates on every command:

| Layer | Matches on | Example |
|---|---|---|
| baseline | everything else | unmatched repositories use one nominated key |
| 1 | the folder | `~/code/example/` uses the `example` key |
| 2 | the organisation in any remote | `git@github.com:example-org/**` uses it too |

Precedence is positional and last-match-wins, so layer 2 beats layer 1. That matters more
than it sounds: a third-party repository cloned inside one of your folders keeps its own
key rather than inheriting the folder's, and a repository with no remote yet still gets
the right key from its path. `sshid` maintains that ordering for you — it is the part most
easily broken by hand.

`gh` cannot be routed this way, because it authenticates with OAuth tokens and keeps a
single global "active account". So `sshid` installs a small shim ahead of `gh` on your
PATH that works out the account per call and passes a token to that one invocation.

**It does not bundle `gh`.** The shim hands off to whatever `gh` you already have, reading
the tokens already in your keyring — no re-login, and your active account never moves. If
you don't have `gh` at all, `setup` says so and skips it; SSH routing works regardless.

### The fallback key

A repository that matches nothing uses the **baseline** — one identity you nominate:

```sh
sshid baseline personal     # what unmatched repositories use
sshid baseline              # show the current one
sshid baseline --none       # clear it; git falls back to its own ssh defaults
```

Keys live in `~/.ssh/sshid/<name>/` by default. If you already keep them elsewhere,
`sshid` uses that instead — point `SSHID_KEYDIR` at it, or let `sshid adopt` find them.

## Everyday use

There isn't any. `cd` into a repository and use git.

```sh
cd ~/code/project-a && git push     # project-a's key
cd ~/code/project-b && git push     # project-b's key, at the same time, another terminal
```

Worth knowing:

```sh
sshid whoami        # what applies here, and why
sshid list          # every identity, what it is bound to, how many repos use it
sshid paths         # every repository, and which identity it uses
sshid doctor        # exits non-zero when something is actually wrong
```

## Adding an identity

Create the key, put it on the account, bind it to a folder. That's the whole flow:

```sh
sshid create example                       # make the key; nothing is bound to it yet
sshid pubkey example | pbcopy              # register the public key on the account
sshid bind example --dir ~/code/example    # bind it to a folder — done

# optional, and usually unnecessary:
sshid bind example --org github.com:example-org \
                   --proof git@github.com:example-org/some-repo.git
```

After the third line, every repository under `~/code/example` uses that key — including
ones that have no remote yet. Nothing else is required.

`--org` takes `host:org`, `host/org`, or just `org` (which assumes github.com).

### When you'd want the optional org binding

A folder binding says *"repositories in this directory"*. An org binding says
*"repositories belonging to this organisation, wherever they happen to be on disk"*.

Two reasons to add one:

- a repository of theirs lives outside the folder — cloned to a scratch directory, say —
  and you still want the right key
- a **third-party** repository is cloned *inside* your folder. An org binding beats a
  folder binding, so that repository keeps its own key instead of silently borrowing yours

If everything for that account lives in one folder, skip it.

### Why the org binding needs `--proof`

Binding a folder contacts nothing. It is a statement about files on your own disk, and it
cannot be wrong in a way that surprises you — so nothing is checked.

Binding an organisation is a claim about a remote server: *this key can reach that org's
repositories.* That claim is easy to get wrong and it fails misleadingly. An SSH key can
authenticate perfectly — the server greets you by name — and still be denied every
repository on the account, because authenticating and being authorised are different
things. When that happens git says:

```
ERROR: Repository not found.
```

which reads like a typo in the URL and is almost always the wrong identity. So `sshid`
will not bind an organisation until it has watched the key reach a real repository there.
`--proof` takes any repository URL in that org; `sshid` makes one read-only request and
refuses the binding if it fails. `--force` skips the check if you have a reason to.

## Undoing things

Every change is snapshotted first, and `sshid undo` restores the last one.

`sshid rename <old> <new>` renames an identity — the key directory, every binding, the ssh
alias and the gh mapping all move with it, and repositories follow automatically.

`sshid unbind <name> --all` removes every binding but keeps the key; `--org` or `--dir`
removes just one. `sshid forget` removes the identity and *still* keeps the key, because an
unbound key costs nothing and deleting one cannot be undone — `--delete-key` does that, and
asks you to type the name back to confirm.

`sshid` only rewrites the block it owns, between two markers in `~/.gitconfig`. Everything
else in that file is read, never written. `adopt` is the one exception, since it has to
absorb rules written by hand: it records what every repository resolves to before and
after, refuses to install a result that would drop any unrelated setting, and rolls back
if a single repository would resolve differently.

## Requirements

macOS, and git 2.36 or newer. Below 2.36 git ignores `hasconfig` rules silently and every
repository falls back to the baseline key, so `sshid doctor` checks the version first.

MIT licensed.
