# Chainguard Actions hands-on: every command, what it prints, what it proves

You take a real CI pipeline that uses 14 popular GitHub Actions by tag, look inside the hardened copies Chainguard
publishes, migrate the pipeline to them, and check the result. Part A needs only a terminal. Part B runs both pipelines
on your own GitHub repository, so you can watch Dependabot and an organization allowlist do their jobs.

Outputs are from 7 October 2026, the day after general availability. Chainguard re-hardens actions continuously, so
your SHAs and counts will differ. The pattern will not.

| | Part A: your terminal | Part B: your GitHub repository |
|---|---|---|
| Time | 25 minutes | 20 minutes, mostly waiting for runs |
| You need | `git`, `curl`, `jq`, `bash` | a GitHub account and the `gh` CLI |
| Optional | `chainctl` (no Chainguard login needed) | |
| Costs | nothing | nothing on a public repository |

Every command uses `git ls-remote`, `git clone` or `raw.githubusercontent.com`, not the GitHub API, so it works
without a token and does not hit the API's 60-requests-an-hour limit for anonymous users.

---

## Part A: on your terminal

### A1. Get the repository and look at the "before" pipeline

```bash
git clone https://github.com/sathpal/chainguard-actions-end-to-end && cd chainguard-actions-end-to-end
grep -hE '^\s*(- )?uses:' .github/workflows/pipeline-upstream.yml | sed -E 's/^ *(- )?uses: *//' | sort | uniq -c | sort -rn
```

```output
   3 actions/checkout@v7
   2 docker/login-action@v4
   1 tj-actions/changed-files@v47
   1 sigstore/cosign-installer@v4.1.2
   1 docker/setup-buildx-action@v4
   1 docker/metadata-action@v6
   1 docker/build-push-action@v7
   1 aquasecurity/trivy-action@v0.36.0
   1 anchore/scan-action@v7
   1 anchore/sbom-action@v0
   1 actions/upload-artifact@v7
   1 actions/setup-go@v7
   1 actions/attest-build-provenance@v4
```

**What to notice.** 16 references, every one by tag, most by a major tag like `@v7` that the publisher moves on every
release. Whoever controls those repositories decides what runs in this pipeline. That is not hypothetical:
`tj-actions/changed-files` had its tags repointed in March 2025
([CVE-2025-30066](https://github.com/advisories/GHSA-mrrh-fwg8-r2c3)), and on 19 March 2026 an attacker force-pushed
76 of 77 `aquasecurity/trivy-action` tags to a credential stealer that ran before the real scan
([Aqua's account](https://www.aquasec.com/blog/trivy-supply-chain-attack-what-you-need-to-know)).

**Good to know.** `grep` only sees direct references. Composite actions call other actions. `chainctl actions discover
. --recursive` follows them and lists 32 actions for this pipeline; it works without a Chainguard login (only the catalog
matching needs one).

### A2. The action that hurt people, in the catalog

```bash
echo "upstream trivy-action tags: $(git ls-remote --tags https://github.com/aquasecurity/trivy-action | grep -vc '\^{}')"
git ls-remote --tags https://github.com/chainguard-actions/aquasecurity-trivy-action | grep -v '\^{}' | sed 's|refs/tags/||'
curl -s https://raw.githubusercontent.com/chainguard-actions/aquasecurity-trivy-action/v0.35.0/source.json | jq -c '{repo, version, commit_sha}'
echo "upstream v0.35.0 -> $(git ls-remote https://github.com/aquasecurity/trivy-action 'refs/tags/v0.35.0^{}' 'refs/tags/v0.35.0' | tail -1 | cut -c1-40)"
```

```output
upstream trivy-action tags: 75
c02135b2a61e8a6d603c53db55145af34b25ce4d	v0.35.0
{"repo":"trivy-action","version":"v0.35.0","commit_sha":"57a97c7e7821a5776cebc9bb87c984fa69cba8f1"}
upstream v0.35.0 -> 57a97c7e7821a5776cebc9bb87c984fa69cba8f1
```

**What to notice.** Upstream has 75 tags anyone with the right credentials can move. The catalog carries one Trivy
version, `v0.35.0`, the one tag the March attacker did not repoint, and records the exact upstream commit it was built
from. If upstream's tag moved tomorrow, the hardened copy would not follow.

### A3. Open a hardened action

Each hardened repository has a `main` branch with metadata only and one branch per version holding the action.

```bash
cd ..
git clone -q --depth 1 https://github.com/chainguard-actions/sigstore-cosign-installer ci-main
git clone -q --depth 1 -b v4.1.2 https://github.com/chainguard-actions/sigstore-cosign-installer ci-412 2>/dev/null
echo "main:   $(ls ci-main | xargs)"; echo "v4.1.2: $(ls ci-412 | xargs)"
jq -c '{owner, repo, version, commit_sha: .commit_sha[0:12], policy_sha: .policy_sha[0:12]}' ci-412/source.json
grep -E 'finding\(s\)|^### [a-z-]+ ' ci-412/HARDENING.md
tail -1 ci-412/attestations/provenance.intoto.jsonl | jq -r '.payload | @base64d | fromjson | "type:    \(.predicateType)\nsource:  \(.predicate.buildDefinition.externalParameters.source.repository)@\(.predicate.buildDefinition.externalParameters.source.commit[0:12])\nfiles:   \(.subject | length)"'
tail -1 ci-412/attestations/provenance.intoto.jsonl | jq -r '"key id:  \(.signatures[0].keyid)"'
cd chainguard-actions-end-to-end
```

```output
main:   LICENSE_CHAINGUARD README.md source.json
v4.1.2: CODEOWNERS HARDENING.md LICENSE LICENSE_CHAINGUARD README.md action.yml attestations source.json tests
{"owner":"sigstore","repo":"cosign-installer","version":"v4.1.2","commit_sha":"6f9f17788090","policy_sha":"d636be7e43ef"}
Action **sigstore--cosign-installer/v4.1.2** was hardened automatically. 3 finding(s) were identified and resolved across 2 iteration(s).
### github-env-injection (severity: high)
### github-env-injection (severity: high)
### script-injection (severity: high)
type:    https://slsa.dev/provenance/v1
source:  https://github.com/sigstore/cosign-installer@6f9f17788090
files:   11
key id:  sha256:9d8c3dc425c1c0b77b64e855a5b4d2e9e515d7aaeca28843a63052751690df24
```

**What to notice.** `HARDENING.md` lists what was found and fixed; `source.json` names the upstream commit and the
ruleset (`policy_sha`); the provenance is a signed SLSA v1 statement with a SHA-256 digest for each of the 11 files.

**Caveat.** Chainguard has not published the key behind that key ID yet (its documentation says so). Today you can
prove the files match the provenance (A7), not who signed it.

**Caveat.** `@main` never works for a hardened action: that branch has no `action.yml`.

### A4. What did hardening change in the code that runs?

`scripts/diff-upstream.sh` clones a hardened version and the exact upstream commit from its `source.json`, removes docs,
tests and the action's own CI from both, and diffs what is left.

```bash
scripts/diff-upstream.sh docker/build-push-action v7.4.0
scripts/diff-upstream.sh sigstore/cosign-installer v4.1.2 | grep -E '^[-+].*(GITHUB_PATH|safe_install_dir|tr -d)'
```

```output
hardened chainguard-actions/docker-build-push-action@v7.4.0 (5b225cb1d6f5) built from docker/build-push-action@c3c9e263c25d
no difference in executed files
-      run: envsubst <<<"${input_install_dir}" >> "$GITHUB_PATH"
+        safe_install_dir=$(printf '%s' "$(envsubst <<< "${input_install_dir}")" | tr -d '\n\r')
+        printf '%s\n' "${safe_install_dir}" >> "$GITHUB_PATH"
-        echo "${install_dir}" | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
+        $safe_install_dir = $install_dir -replace '[\r\n]', ''
+        $safe_install_dir | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
```

**What to notice.** The hardened build-push-action runs upstream's code byte for byte. The hardened cosign-installer
fixes a real injection: a value containing a newline, written to `$GITHUB_PATH`, can put a directory of an attacker's
choosing on the `PATH` of every later step. It is fixed for Linux, macOS and Windows runners.

**Observation.** Across all 14 actions in this pipeline ([`evidence/runtime-diffs.txt`](../evidence/runtime-diffs.txt)):
5 run upstream's code unchanged, 5 add only a usage hook (A9), 1 rewrites a nested reference to its hardened copy, and
3 carry security fixes to code that runs. Of the 15 findings in their reports, 11 are in the action repository's own CI
and example files, which never run in your pipeline. The protection is mostly *where the code lives*: an immutable,
reviewed copy of a known commit.

### A5. Migrate the pipeline

```bash
scripts/migrate.sh .github/workflows/pipeline-upstream.yml > my-hardened.yml
```

```output
RESOLVED actions/checkout@v7 -> v7.0.1 -> chainguard-actions/actions-checkout@279383ec3b8d
PINNED   tj-actions/changed-files@v47 -> chainguard-actions/tj-actions-changed-files@4b4bd2ed96c7
RESOLVED actions/setup-go@v7 -> v7.0.0 -> chainguard-actions/actions-setup-go@738fd0174f4f
RESOLVED docker/setup-buildx-action@v4 -> v4.4.1 -> chainguard-actions/docker-setup-buildx-action@9e5cde6a2bfe
RESOLVED docker/login-action@v4 -> v4.6.0 -> chainguard-actions/docker-login-action@471f865b6525
RESOLVED docker/metadata-action@v6 -> v6.2.0 -> chainguard-actions/docker-metadata-action@897c7d20d500
RESOLVED docker/build-push-action@v7 -> v7.4.0 -> chainguard-actions/docker-build-push-action@5b225cb1d6f5
PINNED   anchore/sbom-action@v0 -> chainguard-actions/anchore-sbom-action@f26b93287efa
RESOLVED anchore/scan-action@v7 -> v7.4.0 -> chainguard-actions/anchore-scan-action@6fd51fc1c2c6
NO-MATCH aquasecurity/trivy-action@v0.36.0 (upstream ed142fd0673e = v0.36.0): no hardened tag for that version; pick one by hand
RESOLVED actions/upload-artifact@v7 -> v7.0.1 -> chainguard-actions/actions-upload-artifact@dc8d35a3347d
PINNED   sigstore/cosign-installer@v4.1.2 -> chainguard-actions/sigstore-cosign-installer@b87981cc3b02
RESOLVED actions/attest-build-provenance@v4 -> v4.2.2 -> chainguard-actions/actions-attest-build-provenance@8328d5e203fe
```

(Repeated lines for the same action are left out here.)

**What to notice.** Renaming the organization is not enough: 9 of the 12 major tags these actions publish (`@v7`, `@v4`)
do not exist in the catalog. `RESOLVED` means the script followed upstream's major tag to its exact version and pinned
the hardened copy of that version by SHA, with the version as a comment.

**Observation.** One action did not migrate. Dependabot had moved this pipeline to Trivy `v0.36.0`, released after the
attack, and the catalog only has `v0.35.0`. That is a decision, not a bug: stay on the newest hardened version, or
[request the new one](https://github.com/chainguard-actions/.github/issues/new?template=new-action.yml). Pin the
hardened `v0.35.0` (on macOS use `sed -i ''`):

```bash
T=$(git ls-remote https://github.com/chainguard-actions/aquasecurity-trivy-action refs/tags/v0.35.0 | cut -f1)
sed -i "s|uses: aquasecurity/trivy-action@v0.36.0|uses: chainguard-actions/aquasecurity-trivy-action@$T # v0.35.0|" my-hardened.yml
diff .github/workflows/pipeline-upstream.yml my-hardened.yml | grep -c '^>'
```

```output
16
```

Only the 16 `uses:` lines changed.

### A6. Tags move, even in the hardened catalog

```bash
git clone -q --filter=blob:none --no-checkout --single-branch -b v6.0.3 https://github.com/chainguard-actions/actions-checkout ../co-603
git -C ../co-603 log --format='%cs %h %s' --grep='^Update actions/checkout@v6.0.3$'
echo "tag v6.0.3 now -> $(git ls-remote https://github.com/chainguard-actions/actions-checkout refs/tags/v6.0.3 | cut -c1-12)"
```

```output
2026-09-19 bf4cd70 Update actions/checkout@v6.0.3
2026-09-11 a5784d3 Update actions/checkout@v6.0.3
2026-07-23 0582da5 Update actions/checkout@v6.0.3
2026-06-19 13fd614 Update actions/checkout@v6.0.3
2026-06-12 a520786 Update actions/checkout@v6.0.3
tag v6.0.3 now -> bf4cd70b8ca3
```

**What to notice.** Chainguard re-hardens a published version whenever its ruleset changes and moves the tag, exact
version tags included. `v6.0.3` has pointed at five commits since June; Trivy `v0.35.0` has moved 129 times. That is how
fixes reach tag users, and it is why only a SHA says exactly what runs.

**Caveat.** A SHA pin with nothing to update it leaves you on an old hardening. Pair it with Dependabot or Renovate
(Part B shows it working).

### A7. Check every pin against its provenance

```bash
scripts/verify-pins.sh my-hardened.yml 2>/dev/null; echo "exit $?"
```

```output
ACTION                                 PIN            VERSION    TAG                      FILES
chainguard-actions/actions-attest-build-provenance 8328d5e203fe   v4.2.2     current                  14/14 match; upstream 4d101475d8b2
chainguard-actions/actions-checkout    279383ec3b8d   v7.0.1     current                  100/100 match; upstream 3d3c42e5aac5
chainguard-actions/actions-setup-go    738fd0174f4f   v7.0.0     current                  111/112 match (0 missing, 1 differ, none executed); upstream b7ad1dad31e0
chainguard-actions/anchore-scan-action 6fd51fc1c2c6   v7.4.0     current                  49/56 match (6 missing, 1 differ, none executed); upstream e1165082ffb1
chainguard-actions/aquasecurity-trivy-action c02135b2a61e   v0.35.0    current                  42/42 match; upstream 57a97c7e7821
chainguard-actions/docker-build-push-action 5b225cb1d6f5   v7.4.0     current                  81/81 match; upstream c3c9e263c25d
chainguard-actions/docker-metadata-action 897c7d20d500   v6.2.0     current                  100/109 match (8 missing, 1 differ, none executed); upstream dc8028041006
chainguard-actions/tj-actions-changed-files 4b4bd2ed96c7   v47        current                  66/77 match (10 missing, 1 differ, none executed); upstream 24d32ffd4924
...
exit 0
```

**What to notice.** For each pin: it is a full SHA, its version tag still points there (`current`), and every file at
that SHA was hashed and compared with the provenance. Every executed file in all 13 actions matches.

**Observation.** The exceptions are files that never run: the action repository's own CI workflows, which the
provenance lists but the published branch does not ship; READMEs that received a privacy notice after signing; one
`package.json` with different line endings. Run with `2>&1` to see each by name. Worth reporting to Chainguard (the
provenance should describe what is published), but it does not touch what runs.

### A8. The nested actions an allowlist will need

```bash
scripts/nested.sh my-hardened.yml
```

```output
DEPTH  NESTED UPSTREAM ACTION                                                     VERSION   CALLED BY
1      actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809                     v4.2.4    chainguard-actions/aquasecurity-trivy-action
1      aquasecurity/setup-trivy@e6c2c5e321ed9123bda567646e2f96565e34abe1          v0.2.4    chainguard-actions/aquasecurity-trivy-action
2      actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809                     v4.2.4    aquasecurity/setup-trivy
2      actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8                  v5.0.0    aquasecurity/setup-trivy

Allowlist patterns (Settings > Actions > General > Allow select actions):
  chainguard-actions/*
  actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809
  actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8
  aquasecurity/setup-trivy@e6c2c5e321ed9123bda567646e2f96565e34abe1
```

**What to notice.** Some hardened composite actions still call upstream actions inside, pinned by SHA but not replaced
with hardened copies. Chainguard swaps a nested reference only when a hardened copy of that exact commit exists (the
hardened `attest-build-provenance` already calls `chainguard-actions/actions-attest`), and that rewriting is still
rolling out. You will see why this matters in B4.

### A9. The usage hook

```bash
for a in docker-metadata-action@897c7d20d500ba5c444ff537bcce1278724b6c96 docker-build-push-action@5b225cb1d6f5196bc2459eaa52642b902bf3750f; do
  printf "%-26s %s\n" "${a%@*}" "$(curl -sf https://raw.githubusercontent.com/chainguard-actions/${a%@*}/${a#*@}/action.yml | grep -E '^\s+(pre|main|post):' | tr -s ' ' | tr '\n' ' ')"
done
curl -sf https://raw.githubusercontent.com/chainguard-actions/docker-metadata-action/897c7d20d500ba5c444ff537bcce1278724b6c96/chainguard-phonehome.js | grep -nE "RECORD_URL =|AUDIENCE =|repository:|action:"
```

```output
docker-metadata-action      pre: chainguard-phonehome.js  main: 'dist/index.cjs'
docker-build-push-action    main: 'dist/index.cjs'  post: 'dist/index.cjs'
13:  const RECORD_URL = 'https://actions.enforce.dev/actions/v1/record';
14:  const AUDIENCE = 'actions.chainguard.dev';
22:          repository: process.env.GITHUB_REPOSITORY || '',
23:          action: process.env.GITHUB_ACTION_REPOSITORY || '',
```

**What to notice.** 9 of the 14 hardened actions report each use to Chainguard: the repository and the action. The
hook times out after two seconds and swallows every error, so it cannot fail a build.

**Caveat.** If the job grants `id-token: write`, the hook also mints a GitHub OIDC token for the audience
`actions.chainguard.dev`, so the record is verified and carries ref, commit, workflow and run identifiers
([Chainguard's telemetry page](https://edu.chainguard.dev/chainguard/actions/telemetry/); it says the person who started
the run is not stored). Keyless signing jobs have that permission. Grant it only where it is needed.

**Good to know.** If your runners have an egress allowlist, add `actions.enforce.dev`, or every hooked step waits out
its two-second timeout.

### A10. Acceptance

```bash
scripts/acceptance.sh my-hardened.yml; echo "exit $?"
```

```output
PASS 1  16 of 16 actions come from chainguard-actions
PASS 2  16 of 16 references are full commit SHAs
PASS 3  16 of 16 pins carry a version comment
PASS 4  0 references to @main or @master
PASS 5  13 actions: every executed file matches its provenance
PASS 6  3 nested upstream actions to allow by SHA: actions/cache@0400…,actions/checkout@08c6…,aquasecurity/setup-trivy@e6c2…
exit 0
```

Run it on the original for contrast: `scripts/acceptance.sh .github/workflows/pipeline-upstream.yml` fails checks 1,
2, 3, 5 and 6. Put the script in your own CI next to `verify-pins.sh`.

---

## Part B: on your own GitHub repository

### B1. Make your own copy and let both pipelines run

A new repository (rather than a fork) gets Actions, Dependabot and packages without extra switches.

```bash
gh repo create chainguard-actions-demo --public --source . --remote mine --push
gh run list -R "$(gh api user --jq .login)/chainguard-actions-demo" --limit 5
```

Pushing starts three workflows: `pipeline (upstream actions, tags)`, `pipeline (Chainguard Actions, pinned)` and
`audit`. Both pipelines test a small Go service, build it on `cgr.dev/chainguard/go` and `cgr.dev/chainguard/static`,
push it to your GHCR, generate an SBOM, scan with grype and Trivy, sign it keyless with cosign and attach GitHub build
provenance. On the original repository both finished green on the first run.

**Observation.** In the hardened run, open the `build` job. Some steps have a *Pre* step:

```text
Pre Run chainguard-actions/docker-metadata-action@897c7d20…
Pre SBOM (syft)
Pre Scan gate (grype)
Pre Run chainguard-actions/actions-upload-artifact@dc8d35a3…
```

That is the usage hook from A9. In composite actions it appears as a first step called *Chainguard usage telemetry*.

**Observation.** Open the Trivy step in either run:

```text
aquasecurity/trivy info checking GitHub for tag 'v0.69.3'
aquasecurity/trivy info found version: 0.69.3 for v0.69.3/Linux/64bit
```

and the grype step:

```text
Downloading grype v0.110.0 via https://raw.githubusercontent.com/anchore/grype/main/install.sh
```

**Caveat.** Hardening reviews the action's code, not what it downloads while it runs. The Trivy binary comes from
GitHub releases by tag, which is how the March attack delivered a malicious Trivy v0.69.4, and grype's installer comes
from a branch. Set each tool's `version:` input, and for your most sensitive jobs run the tool from a digest-pinned
image.

**Results on the original repository** ([`evidence/timings.txt`](../evidence/timings.txt)):

| | Upstream | Hardened |
|---|---|---|
| Wall time, mean of three runs | 221 s | 228 s |
| grype and Trivy findings | 0 | 0 |
| Signed and verified | yes | yes |
| zizmor high findings | 16 | 0 |

The spread between runs of the same pipeline (up to 54 s) was wider than the gap between the two.

### B2. Verify an image you just built

```bash
ME=$(gh api user --jq .login)
D=$(gh run view -R $ME/chainguard-actions-demo "$(gh run list -R $ME/chainguard-actions-demo -w pipeline-hardened.yml -L 1 --json databaseId --jq '.[0].databaseId')" --log | grep -oE 'verified sha256:[0-9a-f]{64}' | head -1 | cut -d' ' -f2)
IMG=ghcr.io/$ME/chainguard-actions-demo/hello@$D
cosign verify "$IMG" --certificate-identity "https://github.com/$ME/chainguard-actions-demo/.github/workflows/pipeline-hardened.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com > /dev/null 2>&1 && echo "signature ok"
gh attestation verify "oci://$IMG" -R $ME/chainguard-actions-demo > /dev/null 2>&1 && echo "provenance ok"
```

```output
signature ok
provenance ok
```

**Good to know.** cosign 3 stores signatures as Sigstore bundles, and `cosign verify` output no longer fills the
`optional` block with the signer's identity. If a script reads `.optional.Subject`, it now prints `null` even though
verification passed. The pipeline prints the verified digest and the identity it enforced instead.

### B3. Watch Dependabot move a pin

`.github/dependabot.yml` asks for weekly grouped updates of actions and base images. On the original repository the
first pull request arrived three minutes after the first push:

```text
actions: bump the actions group with 2 updates
  chainguard-actions/anchore-scan-action  7.4.0 -> 7.4.2   (a newer hardening, by SHA)
  aquasecurity/trivy-action               v0.35.0 -> v0.36.0 (upstream pipeline only)
```

Both pipelines run on the pull request: they build and scan a local image, and push and sign only on `main`.

**Observation.** Dependabot understands SHA pins with a version comment, which is why the comment matters.

**Caveat.** Without a `pull_request` trigger, Dependabot's changes merge untested. The pipelines here run on pull
requests for exactly that reason; the first version did not, and its first Dependabot pull request had no checks.

### B4. Turn on the allowlist, and watch it break

Restrict your repository to the catalog, as the documentation suggests:

```bash
R=$(gh api user --jq .login)/chainguard-actions-demo
gh api -X PUT repos/$R/actions/permissions -F enabled=true -f allowed_actions=selected
gh api -X PUT repos/$R/actions/permissions/selected-actions -F github_owned_allowed=false -F verified_allowed=false -f 'patterns_allowed[]=chainguard-actions/*'
gh workflow run pipeline-upstream.yml -R $R; gh workflow run pipeline-hardened.yml -R $R
```

The upstream pipeline is refused before it starts (`startup_failure`), which is the point. The hardened one fails too,
at *Set up job*:

```text
The actions aquasecurity/setup-trivy@e6c2c5e3… and actions/cache@0400d5f6… are not allowed in <you>/chainguard-actions-demo
because all actions must be from a repository owned by <you> or match the pattern: chainguard-actions/*.
```

GitHub checks every nested action when a job is set up, even one in a step that will never run (the audit workflow
fails the same way on `github/codeql-action/upload-sarif`, inside the zizmor action, in a step switched off). Add exactly
what A8 printed, plus the zizmor one, each by SHA:

```bash
gh api -X PUT repos/$R/actions/permissions/selected-actions -F github_owned_allowed=false -F verified_allowed=false \
  -f 'patterns_allowed[]=chainguard-actions/*' \
  -f 'patterns_allowed[]=aquasecurity/setup-trivy@e6c2c5e321ed9123bda567646e2f96565e34abe1' \
  -f 'patterns_allowed[]=actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809' \
  -f 'patterns_allowed[]=actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8' \
  -f 'patterns_allowed[]=github/codeql-action/upload-sarif@cdf488f595d80d6e07e03d4674febd5ab45fa938'
gh workflow run pipeline-hardened.yml -R $R
```

The hardened pipeline goes green; the upstream one stays blocked.

**Observation.** On the original repository this took two rounds: after adding the first three, a fourth appeared one
level deeper (`setup-trivy` calls `actions/checkout@08c6903…`). Run `nested.sh` or `chainctl actions discover
--recursive` before you switch the policy on, and again whenever Dependabot moves a pin.

### B5. Clean up

```bash
gh repo delete "$(gh api user --jq .login)/chainguard-actions-demo" --yes   # needs: gh auth refresh -s delete_repo
cd .. && rm -rf chainguard-actions-end-to-end ci-main ci-412 co-603
```

Delete the `hello` package under your profile's *Packages* tab if you want it gone too.

---

## Failures we hit, and the fixes

| What happened | Why | Fix |
|---|---|---|
| `uses: chainguard-actions/actions-checkout@v7` would not resolve | 9 of 12 major tags are not in the catalog | `migrate.sh` resolves to the exact version |
| Trivy `v0.36.0` did not migrate | The catalog only has `v0.35.0` | Pin the newest hardened version; request the new one |
| The hardened pipeline failed at *Set up job* under the allowlist | Nested upstream actions inside hardened composites | Allow them by SHA; find them with `nested.sh` |
| It failed again after that fix | A second level of nesting | Walk the full tree before turning the policy on |
| The signature check printed `signed by null` | cosign 3's bundle format leaves `.optional` empty | Print the verified digest and the identity enforced |
| `changed-files` printed nothing on the first push | A repository's first push has no previous commit to compare with | Expected; it works from the second push |
| Dependabot's first pull request had no checks | The pipelines only ran on `push` | Add a `pull_request` trigger that builds and scans without pushing |
| `verify-pins.sh` first reported mismatches in 4 actions | The provenance lists CI workflows the branch does not ship, and READMEs changed after signing | Only executed files fail the check; the rest are reported |
| `diff-upstream.sh` failed in a Chainguard-based container | BusyBox `diff` has no `-x` option | Prune excluded paths first, then plain `diff -r` |
| The "before" pipeline can no longer run | The allowlist refuses it, by design | Disabled; its earlier runs are the evidence |

## Caveats

- **Provenance signature.** The signing key is not published yet, so the signature cannot be verified. File digests can.
- **Run-time downloads.** Binaries, scripts and packages an action fetches while it runs are outside the review. A
  JavaScript action's bundle keeps the dependency versions upstream's lockfile pinned.
- **Your own workflows.** Hardened actions fix injection inside the action. An untrusted `${{ github.event… }}` value in
  your own `run:` step is still yours: keep zizmor (or similar) in CI. The audit workflow here does.
- **Telemetry.** Most hardened actions report use to Chainguard, OIDC-verified when the job has `id-token: write`.
- **Catalog lag.** On GA day, 13 of the 14 latest releases this pipeline uses were in the catalog; Trivy was one behind.
- **Chainguard's own test flag.** `.actionchain/test-result.json` said `passed: false` for 5 of these actions; all 14
  worked here. Treat it as a question to ask, not a verdict.
- **License.** The hardened actions are under the Chainguard Source Available License v1.0, not an open-source license.
  Use in your own internal CI/CD is unrestricted and royalty-free; offering their functionality to third parties or
  building a competing product is not allowed.

## Good to know

- `git ls-remote --tags <repo>` lists every tag and its commit without the API; `^{}` lines are the commits annotated
  tags point to.
- Hardened repositories are named `<upstream-owner>-<upstream-repo>`; some old names redirect, but pin the canonical one.
- Each version branch carries `source.json` (upstream commit, ruleset), `HARDENING.md`, `attestations/` and
  `.actionchain/` (Chainguard's dependency and test records).
- `chainctl actions discover` works without a Chainguard login; only matching against the catalog needs one.
- Dependabot reads the version comment after a SHA; without it, it cannot tell you what you are on.
- The open-beta announcement promised a one-day SLA for requested actions.
- Chainguard's Guardener GitHub app can comment on pull requests that add unhardened actions and open migration pull
  requests; it needs `.chainguard/actions.yaml` in each repository (this one has it, inert until the app is installed).

## Where to go next

- [FINDINGS.md](../FINDINGS.md): the twelve findings with evidence
- [Chainguard Actions overview](https://edu.chainguard.dev/chainguard/actions/overview/) and
  [telemetry and privacy](https://edu.chainguard.dev/chainguard/actions/telemetry/)
- [The catalog](https://github.com/chainguard-actions) and [zizmor](https://docs.zizmor.sh/)
