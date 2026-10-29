# Security policy

## Supported versions

Only the latest tagged release is supported. Fixes land on `main` and ship as a new tag; older tags
are not patched.

## Reporting a vulnerability

Please report privately, not in a public issue.

- GitHub private vulnerability reporting: https://github.com/interkelstar/floo/security/advisories/new

Include the version, what you did, and what happened. Expect an acknowledgement; there is no
formal response-time promise.

## In scope

- The client, `floo`.
- The operator tool, `floo-powder` (and `floo-go`).
- The relay scripts in `relay/` (`install-relay.sh`, `floo-route`, `floo-authkeys`).
- The floo.run Worker in `web/`.

## Out of scope

- Availability of the free public relay `relay.floo.run`. It is best effort.
- The helper being able to forge or tamper with the session recording. This is a known limit of the
  design; see [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).

## Past reviews

- 2026-06-11: adversarial multi-agent review before publishing (five dimensions, 20 issues raised, 16
  confirmed and fixed, relay host-key pinning the main one). Details in
  [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).
- 2026-09 audit by two independent scanners, [VVAH](https://github.com/visa/visa-vulnerability-agentic-harness)
  (Visa) and OpenAI codex-security, on identical bytes: findings fixed on `main` on 2026-09-09 and released as
  0.7.3 (2026-10-29). 0.7.4 (2026-10-29) fixed a relay installer regression introduced in 0.7.3.
  See [CHANGELOG.md](CHANGELOG.md).

## Automated checks on every push

- The full test suite (unit tests, CA loopbacks, quick loopback).
- ShellCheck at warning level, with results uploaded to GitHub code scanning.
- OpenSSF Scorecard (on push to `main` and weekly), published at
  https://scorecard.dev/viewer/?uri=github.com/interkelstar/floo
- Dependabot keeps the GitHub Actions versions current.
