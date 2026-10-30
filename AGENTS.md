# floo for AI agents

floo gives you a temporary, recorded, revocable shell on a machine that isn't yours (or is
yours but unreachable — behind NAT, no open port). This file is for an **AI agent** that was
pointed at this repo. Read the case that fits you.

- **You were asked to connect to a machine and do something there** → you are the *helper*.
  Read "Connecting as the helper" below. This is the common case.
- **You were asked to change floo itself** → start at [`docs/READING.md`](docs/READING.md)
  (how to read the whole codebase in ~20 min), then [`docs/DESIGN.md`](docs/DESIGN.md) and
  [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md). The rest of this file is not for you.

## Connecting as the helper

Someone (a human, or you on that machine earlier) has started floo on the target machine with
`curl -s https://floo.run/sh | bash`. It printed a **pairing code** like `K56X-DI2J-DGHG-E`.
You will be given that code in your prompt. The code is the credential: whoever holds it can
connect, so it is read to one person, never posted.

Your side needs `curl`, `bash` 4+, an `ssh` client, and `openssl` + `sha256sum` (used for the
code proof). Your `$HOME` must be writable — floo adds an `Include` line to `~/.ssh/config` and
keeps keys under `~/.config/floo`. No account, no CA, no key to set up: the key is generated for
you. (Stock macOS lacks `sha256sum` and ships bash 3 — install coreutils and a newer bash first.)

### 1. Open the session — always with `--no-shell`

```sh
bash <(curl -s https://floo.run/powder) connect THE-CODE --no-shell
```

**`--no-shell` is not optional for you.** Without it, `connect` drops into an interactive
`ssh` shell and blocks forever — it never returns, and you hang. With `--no-shell` it
establishes the session and exits, printing a line like:

```
✓ session ready — ssh vps-dev / rsync … vps-dev: / floo-powder exec vps-dev
```

Take the **handle** from that line (here `vps-dev`; it is the machine's label, or a session id
if the label is taken). Everything below uses it. If the code was wrong or the relay was
unreachable, `connect` exits non-zero and says so — stop and tell the human, don't retry blindly.

`✓ session ready` is printed even if the link did not come up. **Your real check is the first
command.** Run `ssh <handle> 'hostname'` and confirm you get output before doing anything else.

### 2. Run commands over the handle

Because you fetched the tool with `bash <(curl …)` and installed nothing, there is no
`floo-powder` on your PATH — ignore the `floo-powder exec` hint in the banner. Use `ssh`, which
needs no install:

```sh
ssh vps-dev 'hostname; uptime'            # one command, output comes back to you
ssh vps-dev 'bash -s' < script.sh         # run a whole script non-interactively
rsync -a ./build/ vps-dev:/srv/app/       # files, if you need them
```

Every command you run is shown live in the person's floo window and written to a recording on
**their** disk. Work as if someone is watching, because they are.

A quick (code-only) session lives about **30 minutes** from when the person started it. After
that `ssh <handle>` fails with "no live socket" even though they never pressed Ctrl-C — ask them
to run the command again and read you a fresh code. Plan the job to fit inside that window.

### 3. Close when done

The person's access ends the moment they press Ctrl-C (or close the window) — that is the real
revoke, and you cannot keep the session alive past it. Tidying your own side is optional:

```sh
bash <(curl -s https://floo.run/powder) close vps-dev   # drops your local routing drop-in
```

## Rules for you

- **The code comes from the human, in your prompt. Never invent, guess or brute-force it**, and
  never print it back into any public place.
- **`--no-shell`, always** (see above), then drive the box with `ssh <handle> '<cmd>'`.
- **Don't install anything on the target** and don't try to leave standing access (a new key, a
  cron, a service). floo's whole promise is that nothing stays behind; keep it true.
- **The target accepts no inbound connections.** It dials *out* to the relay on 443 and keeps
  only a loopback endpoint. The traffic on 443 is SSH, not HTTPS, so an environment that only
  lets HTTP(S) through a proxy (some cloud sandboxes) will fetch the script but block the `ssh`
  to the relay — the connection fails on your side. That is your network, not floo. Report it,
  don't try to route around it.
- **Read before you run, and say what you ran.** `floo.run/sh` and `floo.run/powder` serve the
  bytes of one immutable git tag; the long form with the tag URL on GitHub runs the exact file
  you can read there.
