---
name: upgrade-deps
description: Bump pinned dependency versions, rebuild both image legs, rescan with grype, and reconcile .grype.yaml/README.md/TODO.md against the fresh scan results. Use when the user asks to upgrade dependencies, refresh CVE ignores, do a version-bump pass, or re-audit the grype ignore list.
version: 1.0.0
invocable_by: [ user ]
---

# Upgrade Deps

Runs a full dependency-upgrade pass on this image: clears the existing grype
ignore list, bumps every pinned version, builds + scans both matrix legs
(default and `-dind`), then reconciles `.grype.yaml`, the README "CVEs left
unfixed" table, and `TODO.md` against what the fresh scan actually shows —
re-adding ignores that still apply, dropping the ones that don't, and adding
new ones if the bump introduced a fresh unfixable Critical.

This mirrors the project's own re-audit discipline (see `CLAUDE.md` and the
"Notes" section of `TODO.md`): **every `.grype.yaml` ignore must have a
matching README row and an open/closed `TODO.md` item — never let them drift
out of sync.**

Do this work directly on the current branch/worktree unless the user asked
for a PR — don't create one unprompted. Confirm before pushing or opening a
PR (this repo's own conventions never push automatically).

## Step 0 — snapshot the current state

Before touching anything, capture what's currently ignored so you have a
"before" set to reconcile against at the end:

```bash
cat .grype.yaml
```

Note every `vulnerability:`/`package.name`/`package.location` entry. Cross-check
each one has a row in the README "CVEs left unfixed" table (`grep -n "CVEs left unfixed" -A 30 README.md`)
and a corresponding item in `TODO.md`'s "Open — re-audit and remove when
upstream catches up" section. If any are missing, note the drift now — you'll
need to fix it regardless of what the new scan shows.

## Step 1 — clear the ignore list

Temporarily empty the `ignore:` list in `.grype.yaml` (keep the file's header
comment; just drop the entries) so the upcoming scan reports the **true,
unfiltered** vulnerability set. Don't discard the removed entries — you noted
them in Step 0 and need their exact IDs/scoping back in Step 5.

## Step 2 — bump every pinned dependency

Pinned components and how to find their latest version are documented in
`UPDATING.md`. Walk each one and update the `ARG` in `Dockerfile`:

| ARG                                          | Lookup command                                                                                                                  |
|-----------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `GH_RUNNER_VERSION`                          | `curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/actions/runner/releases/latest \| jq -r '.tag_name'` |
| `GIT_LFS_VERSION`                            | `curl -fsSL https://api.github.com/repos/git-lfs/git-lfs/releases/latest \| jq -r '.tag_name'`                                    |
| `GO_X_NET_VERSION` / `GO_X_CRYPTO_VERSION`   | Compare against the git-lfs tag's `go.mod`; only raise the floor if a newer advisory requires it                                  |
| `HELM_VERSION`                               | `curl -fsSL https://api.github.com/repos/helm/helm/releases \| jq -r '[.[].tag_name \| select(startswith("v3."))][0]'`             |
| `KUBECTL_MINOR_VERSION`                      | Check whether a newer k8s minor ships `x/net >= v0.55.0` in its `go.mod` (see the check command in `TODO.md`) before bumping      |
| `NODE_MAJOR`                                 | Only bump if moving to a new LTS line; a rebuild alone refreshes the patch version                                                |

Leave `FROM ubuntu:noble` and `FROM golang:1` alone (see `UPDATING.md` — noble
LTS and `golang:1` both auto-track already). Don't bump `KUBECTL_MINOR_VERSION`
speculatively — only if the check above shows the new minor actually carries
the fix; otherwise the `GO-2026-5026` ignore just comes right back in Step 5.

The auto-refreshed tools (Docker CLI/buildx/compose, `gh`, `yq`, `crane`,
`aws-cli`, PowerShell, Chrome, all `apt` packages) need no edit — a plain
rebuild already pulls their latest release/package.

## Step 3 — build both legs

```bash
docker build -t hardened-runner:noble .
docker build --build-arg INSTALL_DOCKER_DAEMON=true -t hardened-runner:noble-dind .
```

If either build fails, fix the break before continuing — don't scan a stale
image from a previous successful build.

## Step 4 — post-build verification and scan

Per `CLAUDE.md`, verify every tool actually landed before trusting the scan
(layer caching can silently skip an install step). Spot-check at least the
tools touched by Step 2's bumps, e.g.:

```bash
docker run --rm --entrypoint git-lfs hardened-runner:noble version
docker run --rm --entrypoint helm hardened-runner:noble version
docker run --rm --entrypoint kubectl hardened-runner:noble version --client
docker run --rm --entrypoint node hardened-runner:noble --version
```

Then scan both legs, capturing full JSON (not just the CI-equivalent filtered
view — you need the complete picture to decide what belongs in `.grype.yaml`
vs. only in the README):

```bash
grype docker:hardened-runner:noble -o json > /tmp/scan-default.json
grype docker:hardened-runner:noble-dind -o json > /tmp/scan-dind.json
```

Also compute the CI-equivalent gate result for each leg (this is what
`anchore/scan-action` actually enforces in `build.yml`):

```bash
grype docker:hardened-runner:noble --fail-on critical --only-fixed
grype docker:hardened-runner:noble-dind --fail-on critical --only-fixed
```

## Step 5 — reconcile `.grype.yaml`, README, and `TODO.md`

For each entry you removed in Step 1:

- Search `/tmp/scan-default.json` and `/tmp/scan-dind.json` for that
  vulnerability ID, scoped to the same package/location.
- **Still present and still fixable-critical** → re-add the ignore rule to
  `.grype.yaml`. Update the comment if the facts changed (new upstream
  version checked, new date, new release tag) — follow the existing comment
  style in the file (state the CVE, why it's unfixable today, and the exact
  condition that clears it). Leave the README row and `TODO.md` item in
  place, updating any stale version numbers/dates in them too.
- **No longer present, or no longer fixable-critical** → do **not** re-add
  the ignore. Remove the corresponding README "CVEs left unfixed" row, and in
  `TODO.md` either delete the item (if genuinely obsolete) or move it to
  "Verification still owed" as a `[x]` entry noting what changed and today's
  date — follow the existing pattern for closed items in that file.

Then check the CI-equivalent gate output from Step 4 for anything **new**:
a fixable Critical that isn't fixable upstream and wasn't in the original
ignore list. If you find one, add a new `.grype.yaml` ignore following the
existing entries' comment style (explain the CVE, why no fix exists, and the
exact condition to re-audit under), plus a new README row and a new open
`TODO.md` item — the same three-way link every existing ignore has.

Finally, re-scan with the reconciled `.grype.yaml` in place and confirm the
CI-equivalent command now exits `0` for both legs:

```bash
grype docker:hardened-runner:noble --fail-on critical --only-fixed
grype docker:hardened-runner:noble-dind --fail-on critical --only-fixed
```

## Step 6 — report

Summarize for the user:

- Which `ARG` versions were bumped (old → new) and which were left alone (and
  why, if a lookup showed the upgrade wasn't safe/available yet).
- Which `.grype.yaml` ignores were re-added as-is, updated, removed, or newly
  added.
- Any High-severity residuals in the README table that changed (cleared or
  newly appeared) even though they don't gate CI.
- Confirmation that both legs build, that spot-checked binaries are present,
  and that the CI-equivalent grype gate passes on both.

Don't commit or push without the user's confirmation — surface the diff
(`git diff Dockerfile .grype.yaml README.md TODO.md`) and let them review it
first.
