# Findings: Chainguard Actions in a real pipeline

Measured on 6 and 7 October 2026, the day Chainguard Actions became generally available. One pipeline (test, build,
SBOM, two scanners, keyless signing, GitHub build provenance) was run with 14 upstream actions on tags, then with
their hardened copies pinned by SHA. Every number below comes from a run linked here or a file in [`evidence/`](evidence/).

**The short version:** the migration took one script and one Dependabot loop, cost nothing measurable in run time, and
removed every unpinned reference. Most of the protection comes from *where* the code lives (an immutable, reviewed copy
built from the exact upstream commit) rather than from code changes. Three gaps need a decision from you: nested
upstream actions that an allowlist must name, binaries that actions download at run time, and a usage hook that
reports to Chainguard.

| # | Finding | Evidence |
|---|---|---|
| 1 | Swapping the org name is not enough: 9 of the 12 major tags (`@v7`, `@v4`) these actions publish do not exist in the catalog | [`scripts/migrate.sh`](scripts/migrate.sh) |
| 2 | Hardened tags move; one Trivy version was re-hardened 129 times. Pin SHAs and let Dependabot move them | [`tag-history.txt`](evidence/tag-history.txt), [PR #1](https://github.com/sathpal/chainguard-actions-end-to-end/pull/1) |
| 3 | 5 of 14 actions run upstream's code unchanged; 3 carry security fixes to code that runs | [`runtime-diffs.txt`](evidence/runtime-diffs.txt) |
| 4 | 11 of 15 `HARDENING.md` findings are in files that never run in your pipeline | [`hardening-findings.txt`](evidence/hardening-findings.txt) |
| 5 | Provenance matches every executed file (839 of 862 entries overall); the signature cannot be verified yet | [`verify-pins.txt`](evidence/verify-pins.txt) |
| 6 | An allowlist of `chainguard-actions/*` alone broke the hardened pipeline; it needed 4 nested upstream SHAs | [`allowlist.txt`](evidence/allowlist.txt) |
| 7 | Hardening does not cover what an action downloads while it runs | [hardened run log](https://github.com/sathpal/chainguard-actions-end-to-end/actions/runs/37510147374) |
| 8 | 9 of 14 hardened actions report usage to Chainguard; with `id-token: write` the report is OIDC-verified | [`survey.txt`](evidence/survey.txt) |
| 9 | Hardened actions do not fix your own workflow: keep a workflow scanner | [`zizmor.txt`](evidence/zizmor.txt) |
| 10 | 13 of 14 latest upstream releases were hardened on GA day; Trivy was one release behind | [`survey.txt`](evidence/survey.txt) |
| 11 | No measurable run-time cost: 221 s against 228 s, averaged over three runs each | [`timings.txt`](evidence/timings.txt) |

---

## 1. Swapping the org name is not enough

The documented change is one line per step: `uses: actions/checkout@v7` becomes
`uses: chainguard-actions/actions-checkout@<sha> # v7.0.1`. The repository name gains the upstream owner as a prefix.

Most workflows reference major tags, and most hardened repositories do not carry them. Of the 12 major tags these
actions publish upstream, 9 have no hardened equivalent (`actions/checkout@v7`, `actions/setup-go@v7`,
`docker/build-push-action@v7` and six more). A plain org rename fails on those steps. A reference to `@main` fails on
every hardened repository, by design: the main branch holds only metadata.

[`scripts/migrate.sh`](scripts/migrate.sh) handles it: when the hardened tag is missing, it resolves the upstream major
tag to its commit, finds the exact version tag on that commit, and pins the hardened copy of that version. It rewrote
all 16 `uses:` lines of this pipeline in 21 seconds using only `git ls-remote`, so it needs no token and hits no API
rate limit:

```text
RESOLVED actions/checkout@v7 -> v7.0.1 -> chainguard-actions/actions-checkout@279383ec3b8d
PINNED   tj-actions/changed-files@v47 -> chainguard-actions/tj-actions-changed-files@4b4bd2ed96c7
RESOLVED anchore/scan-action@v7 -> v7.4.0 -> chainguard-actions/anchore-scan-action@6fd51fc1c2c6
PINNED   aquasecurity/trivy-action@v0.35.0 -> chainguard-actions/aquasecurity-trivy-action@c02135b2a61e
```

Note the third line: upstream's own `v7` tag pointed at 7.4.0, not the latest 7.4.2. The script pins what you were
actually running; Dependabot moved it to 7.4.2 the same day (finding 2).

**Do this:** migrate with a script or Chainguard's Guardener app, never by hand-renaming, and keep the version as a
comment after the SHA so people and Dependabot can read it.

## 2. Hardened tags move: pin SHAs, and let Dependabot move them

Chainguard re-hardens a published version in place whenever its ruleset changes, and moves the tag, including exact
tags such as `v6.0.3`. Counting the hardening bot's commits on version branches:

```text
actions-checkout@v6.0.3: 5 hardenings: 2026-06-12 2026-06-19 2026-07-23 2026-09-11 2026-09-19
sigstore-cosign-installer@v4.1.2: 5 hardenings: 2026-05-29 2026-05-29 2026-06-12 2026-08-19 2026-09-20
aquasecurity-trivy-action@v0.35.0: 129 hardenings, 124 of them between 16 and 21 April, the latest on 2 October
```

So a tag is a moving target even in the hardened catalog. That is deliberate: it is how fixes reach people who use
tags. But it means only a SHA says exactly what runs, and a SHA without an updater leaves you on an old hardening.

Dependabot handles SHA pins with a version comment. Three minutes after the first push it opened
[PR #1](https://github.com/sathpal/chainguard-actions-end-to-end/pull/1), moving `anchore-scan-action` from the 7.4.0 hardening to 7.4.2. Both pipelines ran on the pull
request: they build and scan a local image, and push and sign nothing until the change is on `main`. It passed and
was merged. That loop, a new hardening proposed, tested on a pull request, then merged, is the operating model.

**Do this:** pin every action by SHA, add `.github/dependabot.yml` for `github-actions`, and run your pipeline on
pull requests so each new hardening is tested before it runs on `main`.

## 3. What hardening changed in code that runs

[`scripts/diff-upstream.sh`](scripts/diff-upstream.sh) diffs each hardened version against the exact upstream commit
named in its `source.json`. Every one of the 14 was built from exactly the upstream commit that version's tag pointed
to. Then:

| Executed code | Actions |
|---|---|
| Identical to upstream | `docker/build-push-action`, `docker/setup-buildx-action`, `actions/checkout`, `docker/login-action`, `actions/setup-go` |
| Usage hook added, nothing else | `actions/upload-artifact`, `docker/metadata-action`, `anchore/scan-action`, `anchore/sbom-action`, `tj-actions/changed-files` |
| Nested reference rewritten to its hardened copy | `actions/attest-build-provenance` (calls `chainguard-actions/actions-attest` instead of `actions/attest`) |
| Security fixes | `sigstore/cosign-installer` and `aquasecurity/trivy-action` (values sanitized before they are written to `$GITHUB_PATH`, shell quoting); `zizmorcore/zizmor-action` (user input tokenized instead of expanded unquoted in `docker run`) |

For the first ten, what you gain is the location, not new code. The tag you reference is controlled by Chainguard, built
from a reviewed upstream commit, and recorded in a signed provenance. That is the protection that matters against
the attacks that defined the last two years: in March 2025 the `tj-actions/changed-files` tags were repointed
([CVE-2025-30066](https://github.com/advisories/GHSA-mrrh-fwg8-r2c3)), and on
19 March 2026 an attacker force-pushed 76 of 77 `aquasecurity/trivy-action` tags to a credential stealer
([Aqua's advisory](https://www.aquasec.com/blog/trivy-supply-chain-attack-what-you-need-to-know)). Neither attack
changed code you had reviewed; both changed what a tag pointed to. A hardened copy pinned by SHA is immune to both.

It does not make upstream's code better where nothing was found. Say it that way to customers.

## 4. Read `HARDENING.md` for where a finding is, not how many there are

Each version ships a `HARDENING.md` listing what the static pass and the AI review found and fixed. Across the five
actions in this pipeline with findings:

```text
ACTION                               FINDINGS RUNTIME  REPO CI/EXAMPLES
tj-actions-changed-files@v47.0.6     6        0        6
sigstore-cosign-installer@v4.1.2     3        2        1
aquasecurity-trivy-action@v0.35.0    4        1        3
docker-metadata-action@v6.2.0        1        0        1
zizmorcore-zizmor-action@v0.6.4      1        1        0
TOTAL                                15       4        11
```

11 of the 15 are in the action repository's own CI workflows or example files. Those never run in a consumer's
pipeline, and the workflows are not even shipped on the version branch. The 4 that matter are in `action.yml` or a
script it runs. The report's iteration notes also list fixes that are not counted as findings, such as the quoted
`case` operands in cosign-installer.

## 5. Provenance matches every executed file; the signature cannot be verified yet

Every hardened version this pipeline uses ships `attestations/provenance.intoto.jsonl`: a DSSE-signed SLSA v1 statement
naming the upstream repository and commit, the ruleset, and a SHA-256 digest for every file.
[`scripts/verify-pins.sh`](scripts/verify-pins.sh) checks those digests against the files at the pinned SHA, and
[`audit.yml`](.github/workflows/audit.yml) runs it on every workflow change and every Monday.

Across the 14 pinned actions, **839 of 862 file digests match, and every executed file matches**. The 23 exceptions are
all files that never run: 19 action-repository workflows listed in the provenance but removed from the published branch,
3 READMEs that received a privacy notice after signing, and one `package.json` whose line endings changed.

The signature is another matter. The envelope carries key ID `sha256:9d8c3dc4…`, but Chainguard has not published the
key, and its documentation says so. Today the provenance proves internal consistency (the files are the ones it
describes), not who signed it.

**Do this:** run `verify-pins.sh` in CI now, and add signature verification when Chainguard publishes the key.

## 6. An allowlist needs the nested actions too

GitHub can restrict a repository to approved actions (Settings > Actions > General). The documentation says to add
`chainguard-actions/*`. With only that pattern, the upstream pipeline was refused before it started, as intended. The
hardened pipeline failed too:

```text
The actions aquasecurity/setup-trivy@e6c2c5e3… and actions/cache@0400d5f6… are not allowed …
The action github/codeql-action/upload-sarif@cdf488f5… is not allowed …
```

Hardened composite actions still call some upstream actions inside, pinned by SHA but not replaced with hardened
copies: Chainguard rewrites a nested reference only when a hardened copy of that exact commit exists, and the
rewriting is still rolling out. GitHub resolves every nested action when the job is set up, so zizmor's SARIF upload
was refused even though that step was configured never to run. After adding those three, a fourth appeared one level
deeper: `aquasecurity/setup-trivy` calls `actions/checkout@08c6903c…`.

The pipeline passed with `chainguard-actions/*` plus exactly those four upstream commits, each by SHA. Two ways to find
them before you switch the policy on: `chainctl actions discover . --recursive` ([`discover.txt`](evidence/discover.txt),
32 actions; it works without a Chainguard login, only the catalog matching needs one), or
[`scripts/nested.sh`](scripts/nested.sh), which walks the nested `action.yml` files and prints the patterns to paste:

```text
DEPTH  NESTED UPSTREAM ACTION                                                     VERSION   CALLED BY
1      actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809                     v4.2.4    chainguard-actions/aquasecurity-trivy-action
1      aquasecurity/setup-trivy@e6c2c5e321ed9123bda567646e2f96565e34abe1          v0.2.4    chainguard-actions/aquasecurity-trivy-action
1      github/codeql-action/upload-sarif@cdf488f595d80d6e07e03d4674febd5ab45fa938 v4.37.9   chainguard-actions/zizmorcore-zizmor-action
2      actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8                  v5.0.0    aquasecurity/setup-trivy
```

**Do this:** build the allowlist from `discover --recursive`, add nested upstream actions by full SHA rather than by
owner, and re-run discovery when Dependabot moves a pin.

## 7. Hardening does not cover what an action downloads while it runs

The hardened Trivy action's log, two seconds into the step:

```text
aquasecurity/trivy info checking GitHub for tag 'v0.69.3'
aquasecurity/trivy info found version: 0.69.3 for v0.69.3/Linux/64bit
```

The action's code is pinned and reviewed; the Trivy binary is fetched from GitHub releases by tag while the job runs.
That is the channel the March incident used for the malicious Trivy v0.69.4. The scan action goes further: it
installs grype by running an install script fetched from a branch, not a tag:

```text
Downloading grype v0.110.0 via https://raw.githubusercontent.com/anchore/grype/main/install.sh
```

The SBOM action downloads syft the same way. Chainguard documents this boundary: binaries and packages an action downloads at run time are
outside the review, and a JavaScript action's bundle ships the same dependencies upstream's lockfile pinned.

**Do this:** set each tool's `version:` input explicitly, prefer actions that verify a checksum they ship, and for
the most sensitive jobs run the tool from a digest-pinned container image instead.

## 8. The usage hook, and what `id-token: write` adds

9 of the 14 hardened actions report each use to `https://actions.enforce.dev/actions/v1/record`: a `pre:` script in
JavaScript actions (it shows in the job as *Pre Run chainguard-actions/…*) or a first step named *Chainguard usage
telemetry* in composite ones. It has a two-second timeout and ignores every error, so it cannot fail a build.

When the job grants `id-token: write`, the hook mints a GitHub OIDC token for the audience `actions.chainguard.dev` and
sends it, so the record is verified and carries the repository, ref, commit, workflow path and run identifiers (not
who started the run, per Chainguard's privacy page). This pipeline's `sign` job needs `id-token: write` for keyless
signing, so the cosign-installer and attest steps there send a verified record. The token cannot be used elsewhere:
its audience is Chainguard's.

Two inconsistencies: the hardened `actions/checkout` and `docker/login-action` README says the action *"contacts
Chainguard's licensing server to verify authorization"*, but nothing calls the hook in those two; and Chainguard's
documentation says the entitlement does not gate use (the repositories are public).

**Do this:** add `actions.enforce.dev` to runner egress allowlists, or each hooked step waits two seconds. Grant
`id-token: write` only to jobs that need it, which you should do anyway.

## 9. Hardened actions do not fix your own workflow

zizmor, run by the audit workflow on both pipelines:

```text
hardened pipeline + audit.yml: No findings to report.
upstream pipeline:             16 high (unpinned-uses)
```

The difference here is entirely pinning. Hardened actions fix injection inside the action; a `${{ github.event... }}`
expression interpolated into one of *your* `run:` steps is still yours. This repository's workflows pass values
through `env:` and set least-privilege `permissions:` per job, and the audit workflow keeps zizmor as a gate.

## 10. Catalog freshness

On GA day, 13 of the 14 latest upstream releases this pipeline uses had hardened copies. The exception was
`aquasecurity/trivy-action` v0.36.0: the catalog has only v0.35.0, the one tag the March attacker did not repoint.
Dependabot then bumped the upstream pipeline to v0.36.0 while the hardened pipeline stayed on v0.35.0. Expect a lag
for some actions, and request missing versions through Chainguard's
[new-action template](https://github.com/chainguard-actions/.github/issues/new?template=new-action.yml).

Each version also carries `.actionchain/test-result.json`, Chainguard's own test run. For the actions here it read
`passed: false` for 5, `true` for 1, and no record for 8. All 14 worked in this pipeline. Treat the flag as a question
to ask, not a verdict.

## 11. Cost: none measurable

| | Upstream | Hardened |
|---|---|---|
| Wall time, three runs on `main` | 227, 223, 212 s (mean 221) | 200, 254, 229 s (mean 228) |
| Images, grype and Trivy | 0 findings | 0 findings |
| Signed keyless and verified | yes | yes |
| GitHub build provenance attestation | yes | yes |
| zizmor high findings | 16 | 0 |

The spread between runs of the same pipeline (up to 54 s) is wider than the gap between the two.

## Adoption checklist

1. Inventory with `chainctl actions discover <owner/repo> --recursive`.
2. Migrate with `scripts/migrate.sh` (or the Guardener app): exact versions, SHA pins, version comments.
3. Add Dependabot for `github-actions`, and run the pipeline on pull requests.
4. Restrict allowed actions to `chainguard-actions/*` plus the nested upstream SHAs from step 1.
5. Allow egress to `actions.enforce.dev`; keep `id-token: write` to the jobs that sign.
6. Pin the versions of tools that actions download (`version:` inputs).
7. Keep zizmor and `scripts/verify-pins.sh` in CI.
