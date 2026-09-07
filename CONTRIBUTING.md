# Contributing

## The public repository policy

This repository is public, indexed and archived. Nothing that names the
operator's infrastructure belongs in it — not in code, not in comments, not in
fixtures, not in a commit message, and not in a branch name:

- IP addresses, hostnames and internal URLs;
- account names, passwords, tokens, API keys and device identifiers;
- names of people, customers, projects or ticket numbers;
- local filesystem paths that carry a user name.

Use the reserved documentation ranges instead — `192.0.2.0/24`,
`198.51.100.0/24`, `203.0.113.0/24` and the `.invalid` and `.example` domains —
and generic placeholders for anything else. Operational detail lives in the
maintainer notes, which are not part of this repository.

`tool/public_repo_gate.py` enforces this. Run it before every push; it must
report zero findings.

```
python tool/public_repo_gate.py
```

## Tests

The gates and the trap that makes one of them lie are in the README's
[Running the tests](README.md#running-the-tests) section. In short:
`flutter analyze`, `flutter test` in `apps/mobile`, and `dart test` — not
`flutter test` — in `packages/talk_protocol`.

Run them before you open anything. A change that touches protocol wire shapes
also has to keep the contract fixtures under `contracts/` in step; those
fixtures are executable evidence, so a fixture edited to match a defect makes
the defect permanent.

## Commits

One line, imperative, saying what changed:

```
fix: a call finds the other side again after a network drop
```

Prefixes in use: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`.
No tool attribution, no co-author trailers, no emoji.

## Claims

A statement about behaviour is bound to evidence: a commit SHA, a version, or a
run whose output you can point at. "Should work" is not a state a change can be
merged in. If something was not verified, the honest move is to write down what
was not verified rather than to round it up.

## Licence

Contributions are made under [`GPL-3.0-or-later`](LICENSE), the licence this
project ships under.
