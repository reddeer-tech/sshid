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

Then, and this part is not optional:

```sh
sshid setup     # installs the resolver, and the gh shim if you have gh
sshid adopt     # imports any routing already on this machine
sshid doctor
```

Installing the package on its own changes nothing. `setup` is the opt-in.

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

```sh
sshid add example                       # ed25519 by default; --type=rsa or ecdsa too
sshid add example --show-key | pbcopy   # register the public key on the account
sshid route example --org github.com:example-org \
                    --proof git@github.com:example-org/some-repo.git
```

The `--proof` is not ceremony. An SSH key can authenticate perfectly and still be denied
every repository on an account, and when that happens git reports `repository not found` —
which reads as a wrong URL and is almost always a wrong identity. `sshid` will not route
an organisation until it has watched the key actually reach a real repository there.

## Undoing things

Every change is snapshotted first, and `sshid undo` restores the last one.

`sshid unbind` stops routing an identity but keeps the key. `sshid forget` removes the
identity and still keeps the key, because an unrouted key costs nothing and deleting one
cannot be undone — `--delete-key` does that, and asks you to type the name to confirm.

`sshid` only rewrites the block it owns, between two markers in `~/.gitconfig`. Everything
else in that file is read, never written. `adopt` is the one exception, since it has to
absorb rules written by hand: it records what every repository resolves to before and
after, refuses to install a result that would drop any unrelated setting, and rolls back
if a single repository would resolve differently.

## Requirements

macOS, and git 2.36 or newer. Below 2.36 git ignores `hasconfig` rules silently and every
repository falls back to the baseline key, so `sshid doctor` checks the version first.

MIT licensed.
