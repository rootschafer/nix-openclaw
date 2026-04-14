# Make Stable Release Mirroring Safe

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

Maintain this file in accordance with `/Users/josh/code/nix-openclaw/.agent/PLANS.md`.

## Purpose / Big Picture

After this change, `nix-openclaw` will do one simple thing reliably: mirror the latest upstream OpenClaw stable release only when that release is actually complete, and only after the same Linux + macOS contract that defines green has passed. A maintainer should be able to look at GitHub Actions and know one of three states without reading code: already current, blocked by a broken upstream release, or promoted after full validation.

The current complexity is paid by maintainers and operators. They must know that `Yolo Update Pins` pushes directly to `main`, that `scripts/update-pins.sh` contains both selection and promotion policy, that pushes from `GITHUB_TOKEN` are not fanning out into `CI`, and that an upstream stable tag can exist without the macOS asset we require. After this work, that sequencing and policy knowledge moves behind one deeper updater flow: select a release, validate it on both platforms, then promote it. The special case of “stable tag exists but app artifact is missing” becomes a visible red failure instead of a silent stale pin.

## Progress

- [x] (2026-04-14 10:05Z) Confirmed current `CI` shape in `.github/workflows/ci.yml`: Linux runs `scripts/check-flake-lock-owners.sh` and `nix build .#checks.x86_64-linux.ci --accept-flake-config`; macOS runs `nix build .#checks.aarch64-darwin.ci --accept-flake-config` and `scripts/hm-activation-macos.sh`.
- [x] (2026-04-14 10:06Z) Confirmed current `Yolo Update Pins` shape in `.github/workflows/yolo-update.yml`: one Ubuntu job, direct write permission, direct call to `scripts/update-pins.sh`, no validation jobs, no gating on `CI`.
- [x] (2026-04-14 10:07Z) Confirmed `scripts/update-pins.sh` still owns selection, mutation, commit, rebase, and push in one script.
- [x] (2026-04-14 10:08Z) Confirmed `origin/main` had reached `13deaaf`, pinned to OpenClaw `v2026.4.11`.
- [x] (2026-04-14 10:09Z) Confirmed upstream had an incomplete stable release `v2026.4.12` whose public GitHub release had zero assets.
- [x] (2026-04-14 10:10Z) Confirmed upstream public `macOS Release` workflow is validation-only and explicitly says the real publish/upload path lives in `openclaw/releases-private`.
- [x] (2026-04-14 10:11Z) Confirmed `Yolo Update Pins` runs are green and frequent, but no full nix-openclaw `CI` runs exist for the yolo-produced SHAs `a003810` or `13deaaf`.
- [x] (2026-04-14 10:12Z) Confirmed product decision: when the latest stable release is missing the app asset, yolo should fail red and leave the old pin untouched.
- [x] (2026-04-14 10:18Z) Confirmed current checkout is stale relative to `origin/main`: working tree pin files still show `v2026.4.9`, while `origin/main` is at `v2026.4.11`; implementation and validation commands in this plan must always anchor on the checked-out workflow run or `origin/main`, not the local stale branch state.
- [x] (2026-04-14 14:47Z) Confirmed newest upstream stable release is now `v2026.4.14` and it does include the expected app assets, while older stable `v2026.4.12` remains assetless.
- [x] (2026-04-14 15:21Z) Confirmed the current unsafe behavior on a healthy newest release: yolo selected `v2026.4.14`, built, committed `b023ed1`, and pushed directly to `main`, still without full nix-openclaw `CI` validation.
- [x] (2026-04-14 15:44Z) Refactored `scripts/update-pins.sh` into explicit `select` and `apply` modes; removed commit/rebase/push authority from the script.
- [x] (2026-04-14 15:46Z) Rewrote `.github/workflows/yolo-update.yml` into `select`, `validate-linux`, `validate-macos`, and `promote`, with read-only default permissions and write access only in `promote`.
- [x] (2026-04-14 15:47Z) Implemented the newest-stable-release failure policy: `select` now fails only when the newest stable release is incomplete, and otherwise ignores older broken stable releases.
- [x] (2026-04-14 15:48Z) Updated `AGENTS.md` and `README.md` so they describe the new safe yolo policy instead of the old direct-push behavior.
- [x] (2026-04-14 15:50Z) Verified local syntax and selection behavior: `bash -n scripts/update-pins.sh`, Ruby YAML parse of `.github/workflows/yolo-update.yml`, no-op `select` on current `v2026.4.14`, and emitted release tuple from a temp copy pinned to `v2026.4.11`.
- [ ] Push the implementation and verify real GitHub Actions behavior on the live repository.

## Surprises & Discoveries

- Observation: upstream stable release tags are not enough by themselves; the release can exist without the macOS app asset we require.
  Evidence: `gh release view v2026.4.12 -R openclaw/openclaw --json tagName,assets` returns `"assets":[]`, while `v2026.4.11` includes `OpenClaw-2026.4.11.zip`, `.dmg`, and `.dSYM.zip`.

- Observation: release selection must only care about the newest stable release, not any older broken stable releases below it.
  Evidence: current upstream order is `v2026.4.14` (stable, assets present), then `v2026.4.12` (stable, no assets), then `v2026.4.11` (stable, assets present). The repo should pick `v2026.4.14`, not fail on historical `v2026.4.12`.

- Observation: upstream public macOS release automation no longer uploads public artifacts.
  Evidence: `.github/workflows/macos-release.yml` in `openclaw/openclaw` says “This workflow validates the public release handoff… It does not sign, notarize, or upload macOS assets,” and points operators to `openclaw/releases-private`.

- Observation: current yolo success does not mean `main` is safe.
  Evidence: `gh run list --workflow 'Yolo Update Pins'` shows repeated green runs on `13deaaf`, but `gh run list --workflow CI --branch main` shows no `CI` runs for `13deaaf` or `a003810`.

- Observation: the safety problem is not limited to broken upstream releases; it also applies to healthy newest releases.
  Evidence: yolo run `24405552249` selected `v2026.4.14`, committed `b023ed1`, and pushed `13deaaf..b023ed1 HEAD -> main`, but the workflow still contained only the single `update` job.

- Observation: the current updater is a shallow module because it mixes policy and mutation.
  Evidence: `scripts/update-pins.sh` both selects the target release and also edits files, commits, rebases, and pushes.

- Observation: the current stale state is correct for the wrong reason.
  Evidence: `nix-openclaw` is stuck on `v2026.4.11` because `v2026.4.12` lacks assets, but the workflow presents that as repeated green success instead of an actionable failure.

- Observation: the checked-out branch in this workspace is not the same thing as deploy truth.
  Evidence: local `nix/sources/openclaw-source.nix` and `nix/packages/openclaw-app.nix` still show `v2026.4.9`, while `git log origin/main` shows yolo bumped `main` to `v2026.4.11`.

- Observation: config-options regeneration has a concrete tool dependency that the workflow must preserve.
  Evidence: `nix/scripts/generate-config-options.ts` imports `src/config/zod-schema.ts` from the selected upstream source tree and is currently run through `nix shell ... nodejs_22 pnpm_10 ... pnpm exec tsx`.

- Observation: the read-only `select` phase does not need Nix at all once command checks are split by mode.
  Evidence: after moving `require_cmd nix` and `require_cmd perl` into `apply`, `GITHUB_ACTIONS=true GH_TOKEN=... scripts/update-pins.sh select` succeeds without installing Nix locally in the job.

- Observation: the selection boundary is now demonstrably deterministic.
  Evidence: on current repo state `select` prints no stdout and logs `Selected stable release: v2026.4.14 ...`; on a temp copy edited back to `v2026.4.11`, `select` emits `release_tag=v2026.4.14`, `release_sha=323493fa...`, `app_url=https://github.com/openclaw/openclaw/releases/download/v2026.4.14/OpenClaw-2026.4.14.zip`.

## Decision Log

- Decision: the latest non-draft, non-prerelease upstream GitHub release remains the target stable release.
  Rationale: this preserves the intended stable-release mirroring model and keeps the policy aligned with upstream’s public release channel.
  Date/Author: 2026-04-14 / Codex

- Decision: missing app asset on the latest stable release is a hard yolo failure.
  Rationale: the release is incomplete for nix-openclaw’s current package model, and a quiet no-op hides a real upstream publication error. This failure rule applies only to the newest stable release, not to older broken stable releases behind a newer healthy release.
  Date/Author: 2026-04-14 / Josh/Codex

- Decision: yolo must validate the same Linux + macOS contract as `CI` before any promotion.
  Rationale: relying on push-triggered `CI` is already proven unsafe here because `GITHUB_TOKEN` pushes are not producing the expected follow-on `CI` runs.
  Date/Author: 2026-04-14 / Codex

- Decision: `scripts/update-pins.sh` will no longer commit or push.
  Rationale: commit/push is workflow orchestration, not pin-selection logic; keeping it in the script leaks sequencing and makes validation impossible to enforce cleanly.
  Date/Author: 2026-04-14 / Codex

- Decision: the release selection output must include the exact app URL in addition to the tag and SHA.
  Rationale: later jobs must not recompute “latest asset” and accidentally validate one release asset while promoting another.
  Date/Author: 2026-04-14 / Codex

- Decision: yolo should validate on the same runner classes and installer actions that `CI` uses today.
  Rationale: validating on different runners or with different Nix installers would reintroduce a weaker acceptance rule under a new name.
  Date/Author: 2026-04-14 / Codex

## Outcomes & Retrospective

The current system got the repo most of the way to the desired policy: it switched from “latest green upstream `main` commit” to “stable release mirroring.” The missing piece is safety. The updater currently mirrors by directly moving `main`, not by proving the candidate first. That is why `main` can now drift to `v2026.4.11` without any proof that Linux and macOS still pass there.

That unsafe behavior has now repeated on a healthy newest release too: `v2026.4.14` was mirrored straight to `main` as `b023ed1` by yolo, again without the full repo contract. So the fix is not a niche “broken-release” cleanup. It is the core promotion policy.

The complexity lesson is concrete. Stable-release selection was the right simplification. Direct-to-`main` promotion inside the updater script was not. The simpler long-term system is one where the script owns only selection and pin materialization, while the workflow owns validation and promotion.

Implementation has now landed locally in that shape. The remaining proof step is live GitHub Actions behavior on the pushed repository: repository `CI` on the workflow-change commit, and a manual no-op yolo run on already-current `v2026.4.14`.

## Context and Orientation

There are three moving parts relevant to this plan, plus one source-of-truth warning.

`.github/workflows/ci.yml` defines what “green” means today. Linux runs a repository-policy check in `scripts/check-flake-lock-owners.sh` and then builds `.#checks.x86_64-linux.ci`. macOS builds `.#checks.aarch64-darwin.ci` and then runs `scripts/hm-activation-macos.sh`. That full contract is the only acceptable proof that a pin is safe.

`.github/workflows/yolo-update.yml` is the hourly updater. Today it is one Ubuntu job with write permission. It checks out the repo, installs Nix, sets bot Git identity, and runs `scripts/update-pins.sh`. There are no validation jobs and no separation between selection and promotion.

`scripts/update-pins.sh` is the current shallow boundary. It fetches releases, selects the latest stable release that has a matching macOS zip asset, rewrites `nix/sources/openclaw-source.nix`, rewrites `nix/packages/openclaw-app.nix`, regenerates `nix/generated/openclaw-config-options.nix`, commits, rebases, and pushes. A novice maintainer currently has to know all of that sequencing to understand why `main` moved.

One more upstream fact matters. In `openclaw/openclaw`, the public `macOS Release` workflow is validation-only and the real macOS artifact publish path lives in a private repository called `openclaw/releases-private`. This means a public stable release can legitimately exist before the asset we need exists, or can remain incomplete if a maintainer forgets to finish the private publish path. In this repo, an incomplete newest stable release must be treated as a visible failure, but an older broken stable release must not block a newer complete stable release from being selected.

One local-repo fact also matters. This workspace’s checked-out branch is stale relative to `origin/main`; the tracked pin files in the working tree still show `v2026.4.9`, while remote `main` is already at `v2026.4.11`. Any implementation or validation work for this plan must therefore anchor on the branch being edited for the fix or on `origin/main`, not assume the current checkout reflects production truth.

One generator detail matters too. `nix/scripts/generate-config-options.ts` loads `src/config/zod-schema.ts` from the selected upstream source tree by path and emits `nix/generated/openclaw-config-options.nix`. That means the updater’s `apply` mode must continue to own the temporary source checkout plus the `nodejs + pnpm + tsx` invocation needed to run this generator; callers should not learn that sequencing.

## Plan of Work

The first change is to deepen `scripts/update-pins.sh` by narrowing its responsibility. Instead of a one-shot script that decides, edits, commits, and pushes, it must become a two-mode tool.

In `scripts/update-pins.sh`, add a `select` mode that is read-only. It should fetch the latest upstream releases from `openclaw/openclaw`, pick the first release in release order that is non-draft and non-prerelease, and treat that single release as the only candidate. Then resolve three exact values from that chosen release: the `release_tag`, the concrete `release_sha` from the tag ref, and the exact `app_url` for the public `OpenClaw-*.zip` asset. This selection rule must be strict about the newest stable release only. If the newest stable release has no asset, `select` must fail on that newest stable tag; it must not silently fall back to an older stable release. But if the newest stable release has the asset, `select` must pick it even if an older stable release lower in the release list is still broken. If the current pin already matches both the selected release version and the selected SHA, `select` must exit zero and emit nothing. Otherwise it must print the exact tuple in a parseable form for the workflow to reuse unchanged.

Still in `scripts/update-pins.sh`, add an `apply <release_tag> <release_sha> <app_url>` mode. This mode should contain the existing file-rewrite work: prefetch source and app, update `nix/sources/openclaw-source.nix`, blank and refresh `pnpmDepsHash` by building `.#openclaw-gateway`, update `nix/packages/openclaw-app.nix`, and regenerate `nix/generated/openclaw-config-options.nix`. Preserve the concrete generator contract that exists today: `apply` owns copying or unpacking the prefetched source into a temporary writable directory and running `nix/scripts/generate-config-options.ts` through the existing `nix shell ... nodejs_22 ... pnpm_10 ... pnpm exec tsx` flow. Keep the current backup-and-restore behavior so a failed `apply` leaves the working tree cleanly restorable. Remove all commit, fetch, rebase, and push behavior from the script.

The second change is to move orchestration into `.github/workflows/yolo-update.yml`. Replace the current single-job updater with four jobs.

The `select` job runs first on Ubuntu with read-only permissions. Set top-level workflow permissions to `contents: read`; grant `contents: write` only to the later `promote` job. The `select` job checks out the repo, installs Nix only if needed by the script’s existing tooling, and runs `scripts/update-pins.sh select`. It must not configure bot identity because it must not mutate anything. If `select` emits nothing, the workflow ends as a no-op success. If `select` fails because the latest stable release is missing the app asset, the workflow must fail red. If `select` succeeds with a tuple, expose `release_tag`, `release_sha`, and `app_url` as job outputs.

The `validate-linux` job runs only when `select` returned a tuple. It must use the same runner class and Nix installer as `CI` today: `blacksmith-16vcpu-ubuntu-2404` and `cachix/install-nix-action@v31`. It checks out a fresh copy of the repo, runs `scripts/update-pins.sh apply <tag> <sha> <app_url>`, and then runs exactly the Linux half of `CI`: `scripts/check-flake-lock-owners.sh` followed by `nix build .#checks.x86_64-linux.ci --accept-flake-config`. Do not invent a lighter smoke test here.

The `validate-macos` job also runs only when `select` returned a tuple. It must use the same runner class and Nix installer as `CI` today: `macos-14` and `DeterminateSystems/nix-installer-action@v13`. It checks out a fresh copy, runs the same `apply`, then runs exactly the macOS half of `CI`: `nix build .#checks.aarch64-darwin.ci --accept-flake-config` and `scripts/hm-activation-macos.sh`.

The `promote` job runs only when both validation jobs pass. It is the only job with `contents: write`. It checks out a fresh copy with `fetch-depth: 0`, configures bot identity, runs `apply` again with the same exact tuple, stages only `nix/sources/openclaw-source.nix`, `nix/packages/openclaw-app.nix`, and `nix/generated/openclaw-config-options.nix`, creates one commit, rebases on `origin/main`, and pushes once. This keeps all sequencing knowledge in the workflow instead of in the updater script.

The third change is documentation. Update the “Golden path for pins” section in `AGENTS.md` and the stable-release update section in `README.md` so both documents say the same thing as the code. Specifically: yolo targets the latest stable upstream release, a missing app asset on that release is a failure, and promotion only happens after the same Linux + macOS contract as `CI` passes. Remove the current implication that yolo success alone proves the repo is safe.

The complexity dividend is direct. Callers no longer need to know the updater’s sequencing rules. Maintainers no longer need to infer whether a green yolo run meant “current”, “silently stale”, or “actually promoted”. The policy becomes visible in one place: select fails on incomplete releases, validate proves the candidate, promote moves `main`.

## Concrete Steps

Run all commands from `/Users/josh/code/nix-openclaw`.

Start by confirming the release ordering and the current target release:

    gh release list -R openclaw/openclaw --limit 6
    gh release view v2026.4.14 -R openclaw/openclaw --json tagName,assets,publishedAt
    gh release view v2026.4.12 -R openclaw/openclaw --json tagName,assets,publishedAt
    gh run list --workflow CI --branch main --limit 5 --json databaseId,headSha,conclusion,createdAt
    gh run list --workflow "Yolo Update Pins" --limit 5 --json databaseId,headSha,conclusion,createdAt

Expected observations today:

    - v2026.4.14 is the newest stable release and has the expected assets
    - v2026.4.12 exists with "assets": []
    - latest CI head is older than origin/main
    - yolo has already pushed b023ed1 for v2026.4.14 without matching CI runs

After refactoring the updater script:

    bash -n scripts/update-pins.sh
    GITHUB_ACTIONS=true GH_TOKEN="$(gh auth token)" scripts/update-pins.sh select

Expected behavior:

    - on current upstream state, select chooses v2026.4.14 and ignores the older broken v2026.4.12 release
    - if the newest stable release ever lacks the required app asset, select fails and names that newest stable release

After rewriting the workflow:

    git fetch origin --quiet
    gh workflow view "Yolo Update Pins" --yaml
    gh workflow run "Yolo Update Pins"
    gh run list --workflow "Yolo Update Pins" --limit 3
    gh run view <new-yolo-run-id> --log

Expected behavior for the current upstream state:

    - select chooses v2026.4.14
    - validate-linux passes
    - validate-macos passes
    - promote pushes one commit only after those validations pass

Expected behavior for a future broken newest stable release:

    - select job fails red with a clear missing-asset message naming that newest stable release
    - validate and promote jobs do not run
    - main stays pinned to the previous complete stable release

After a successful promote:

    gh run list --workflow CI --branch main --limit 3
    git show origin/main:nix/packages/openclaw-app.nix | sed -n '1,40p'
    git show origin/main:nix/sources/openclaw-source.nix | sed -n '1,20p'

Expected observations:

    - main points at the new release version
    - even if push-triggered CI does not fan out, the yolo run itself has already proven Linux and macOS before the push

## Validation and Acceptance

The change is complete when a maintainer can verify six behaviors.

First, release ordering is correct. With the current upstream release list, `select` and yolo must choose `v2026.4.14`, because it is the newest stable release and it has the required asset, even though older stable `v2026.4.12` is still broken.

Second, the broken-newest-release case is visible. If the newest stable release ever lacks the required app asset, yolo must fail red and clearly name that newest stable release. `main` must remain pinned to the previous complete release.

Third, no-op behavior remains clean. If the currently pinned release already matches the newest complete upstream stable release, `select` must exit zero without mutating tracked files, and the workflow must finish green without a promotion commit.

Fourth, promotion is safe. When yolo selects the newest stable release, it must use that exact release tuple in Linux validation, macOS validation, and promote. A release may only land if both platform validations pass.

Fifth, file scope remains tight. A successful promotion commit must change only the source pin, app pin, and generated config options. `flake.lock` must remain untouched.

Sixth, runner parity is preserved. The Linux validation job must use the same runner class and Nix installer as `CI`, and the macOS validation job must use the same runner class and Nix installer as `CI`, so the new boundary does not quietly weaken acceptance by validating on different infrastructure.

Seventh, the generator path is preserved. A successful implementation must still regenerate `nix/generated/openclaw-config-options.nix` from the selected upstream source tree using the existing TypeScript generator path, not by introducing a second schema-generation mechanism.

## Idempotence and Recovery

The `select` mode must be read-only and repeatable. Running it multiple times against the same upstream state should either fail with the same missing-asset error, produce the same release tuple, or no-op if already current.

The `apply` mode may edit the working tree, but it must keep backup-and-restore behavior so a failed prefetch, failed `pnpmDepsHash` refresh, or failed config regeneration can be retried safely in the same checkout.

The workflow is safe to rerun. If `select` fails due to a broken newest upstream release, the next hourly run should fail the same way until upstream fixes that newest release or a newer healthy stable release supersedes it. That repeated red signal is intentional because it is the visibility mechanism for an incomplete upstream stable release. If validation fails on Linux or macOS, no promotion occurs and `main` remains unchanged. If promote fails after commit but before push, rerunning the workflow should reconstruct the same state from the same selected tuple.

## Artifacts and Notes

Current upstream-state evidence:

    $ gh release list -R openclaw/openclaw --limit 6
    v2026.4.14
    v2026.4.14-beta.1
    v2026.4.12
    v2026.4.12-beta.1
    v2026.4.11

    $ gh release view v2026.4.14 -R openclaw/openclaw --json tagName,assets
    {"tagName":"v2026.4.14","assets":[...]}

Historical broken-release evidence:

    $ gh release view v2026.4.12 -R openclaw/openclaw --json tagName,assets
    {"tagName":"v2026.4.12","assets":[]}

Current stale-vs-green evidence:

    $ git log --oneline -n 4 origin/main
    b023ed1 🤖 codex: mirror OpenClaw stable release v2026.4.14
    13deaaf 🤖 codex: mirror OpenClaw stable release v2026.4.11
    a003810 🤖 codex: mirror OpenClaw stable release v2026.4.10
    c2e8301 fix(ci): resolve vitest entrypoint in gateway tests

    $ gh run list --workflow CI --branch main --limit 3
    24247056188  success  c2e8301...

Unsafe healthy-release promotion evidence:

    $ gh run view 24405552249 --log | tail -n 5
    [main b023ed1] 🤖 codex: mirror OpenClaw stable release v2026.4.14
    ...
    13deaaf..b023ed1  HEAD -> main

Local-workspace caveat:

    $ sed -n '1,20p' nix/sources/openclaw-source.nix
    rev = "0512059..."

This workspace file state is stale and must not be treated as production truth while implementing this plan.

Public upstream release pipeline evidence:

    public macOS Release workflow summary:
    "This workflow validates the public release handoff... It does not sign, notarize, or upload macOS assets."

This proves two things: the repo should not silently treat a stable release as promotable merely because the tag exists, and it should not let an older broken stable release block a newer healthy stable release.

## Interfaces and Dependencies

In `scripts/update-pins.sh`, define two stable entrypoints:

    scripts/update-pins.sh select
    scripts/update-pins.sh apply <release_tag> <release_sha> <app_url>

`select` hides release discovery policy. Callers must not know how to query the GitHub releases API, how to ignore prereleases, how to resolve a tag SHA, or how to verify that the app asset exists.

`apply` hides pin materialization policy. Callers must not know how to refresh `pnpmDepsHash`, how to prefetch the source/app hashes, or how to regenerate config options.

In `.github/workflows/yolo-update.yml`, define four jobs:

    select
    validate-linux
    validate-macos
    promote

The workflow becomes the only place that knows the sequencing policy: select once, validate twice, then promote once. That is the deeper boundary this plan is creating. Top-level workflow permissions should default to read-only, with write permission granted only to `promote`.

The Linux validation job must reuse the exact current `CI` contract:

    scripts/check-flake-lock-owners.sh
    nix build .#checks.x86_64-linux.ci --accept-flake-config

The macOS validation job must reuse the exact current `CI` contract:

    nix build .#checks.aarch64-darwin.ci --accept-flake-config
    scripts/hm-activation-macos.sh

Revision note (2026-04-14 10:15Z): replaced the prior general stable-release-mirroring plan with a narrower safety plan after observing real production behavior. The new plan is grounded in the current broken upstream `v2026.4.12` release, the missing downstream CI fan-out on yolo-produced commits, and the explicit maintainer decision that missing release assets must fail red rather than silently no-op.

Revision note (2026-04-14 10:20Z): tightened the implementation details after re-reading the current repo and docs. The plan now locks validation to the exact current CI runners/installers, makes the “latest stable but assetless” failure semantics explicit, scopes workflow permissions to read-by-default/write-only-on-promote, and warns that the local checkout is stale relative to `origin/main` so implementation must anchor on remote truth.

Revision note (2026-04-14 14:50Z): updated the release-selection rules after re-checking upstream. The newest stable release is now `v2026.4.14` and it has the expected assets, while older stable `v2026.4.12` remains broken. The plan now explicitly says to fail only when the newest stable release is incomplete, and otherwise to pick the newest stable release even if an older stable release is still assetless.

Revision note (2026-04-14 15:25Z): tightened the plan after observing the live `v2026.4.14` yolo run. The plan now explicitly captures that the unsafe behavior reproduces even on a healthy newest release, updates evidence to `b023ed1`, and preserves the concrete config-options generator dependency so implementation does not accidentally split schema-generation policy across multiple places.

Revision note (2026-04-14 15:50Z): implementation is now in progress in the working tree. The plan was updated to record the completed script/workflow/docs slices, the split command requirements that make `select` truly read-only, and the concrete local validation results for both the no-op and stale-pin selection paths.
