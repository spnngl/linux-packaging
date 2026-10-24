# spnngl/linux-packaging

Read `PLAN.md` before any task: it holds every numbered decision, the phase order and each phase's "Done when". `PLAN.md` is git-ignored and local. Update it in the same change whenever the code deviates from it.

## Rules

- Write agent-facing documents (this file, docs reached by a pointer) per the `writing-for-agents` skill. Each `AGENTS.md` has a `CLAUDE.md` symlink beside it.
- Give each comment its own reason. `PLAN.md` is local, so only this file names it.
- Keep logic in `scripts/*.nu`; workflows only call them, so CI and a local run are the same run.
- Keep one source of truth per fact: packages in `packages.toml`, the public key in `keys/spnngl.asc`, install commands in the `README.md` fences tagged `install-<family>` (`scripts/install-test.nu` runs them verbatim).
- Commit per phase using the `git-commit` skill; the human pushes. Pull requests fail CI unless every commit subject is a Conventional Commit (`type(scope)!: description`).

## Verify

Finish a change when it passes the checks of its kind:

- Scripts: run them in an `ubuntu:26.04` container with `reprepro createrepo-c rpm gnupg`, nushell and a current `gh` (Ubuntu's is too old for `attestation verify --signer-workflow`), `GH_TOKEN` set, `--throwaway` for the key. Failure cases count: a tampered asset, a foreign signature.
- Workflows: `actionlint`, and `GH_TOKEN="$(gh auth token)" uvx zizmor .`.
- `renovate.json5`: `renovate-config-validator --strict --no-global renovate.json5` from the image pinned in `spnngl/.github`'s `renovate.yml`.

## Read before you work

- Before adding or changing a package, read the "Add a package" section of `README.md` (the contract a source repository meets).
- Before changing signing, read decisions 7 and 8 of `PLAN.md`.
