# Agent Notes

Orientation for LLM agents (Claude Code, Codex, etc.) asked to investigate a
failed build in this repo. Read this before digging through logs — most build
failures here have the same shape, and the diagnosis is mechanical. For the
ones that do not, see [Other failure modes](#other-failure-modes).

Companion doc: [`docs/manual-input-check.md`](docs/manual-input-check.md) covers
*pre-flight* checks before a Fedora major-release bump. This file covers
*post-mortem* diagnosis of a build that already broke.

## Writing issues, PRs and comments

A person who was not in your head will read what you write. Write for them.

- **Start with a plain summary**: two or three short sentences saying what
  changed (or what is wrong), why it matters, and what the reader should look
  at or do. Someone who reads only that should still get the point.
- In a PR, put the rest under the pull request template's headings.
- Short sentences. One idea per bullet. No nested dash-clauses.
- Use this project's own words. If you coin a term, define it the first time
  you use it.
- Tell the reader what they can check themselves: the command to run, the file
  to open, the number to compare.
- Keep the body under about 300 words. Long evidence (mutation lists, full test
  output, logs) goes in a collapsed `<details>` block.
- Issues: state the problem as a user would see it, then the evidence, then the
  proposed fix. The title says what is wrong, not what kind of finding it is;
  keep any prefix the tooling requires.

## Pull request review

After opening a PR here, check what `chatgpt-codex-connector[bot]` said before
handing the PR back. It posts as a PR **review** with **inline review
comments**, which `gh pr view <N> --comments` does not show:

```bash
gh api repos/{owner}/{repo}/pulls/<N>/comments \
  --jq '.[] | "PATH: \(.path):\(.line // .original_line)\n\(.body)\n---"'
gh api repos/{owner}/{repo}/pulls/<N>/reviews \
  --jq '.[] | "\(.user.login) [\(.state)]: \(.body)"'
```

Findings carry a severity badge (`P1`, `P2`, …). Verify each claim against the
code or docs before acting — it is often right, but not automatically right.
Fix what is valid and push to the same branch; push back with evidence on what
is not. Either way, report what it found and what you did.

**No review is not the same as no verdict.** When the bot has nothing to say it
does not post — it reacts to the pull request with 👍, which neither endpoint
above returns. Read that before concluding it stayed silent:

```bash
gh api repos/{owner}/{repo}/issues/<N>/reactions \
  --jq '.[] | "\(.content) by \(.user.login)"'
```

The reaction has two values and they are not the same verdict. 👍 means it
reviewed and found nothing — reporting that as "no review appeared" throws away
the one clean signal it gives. 👀 means it has *accepted* the work and is still
doing it; it appears within seconds of an `@codex review` comment and says
nothing about the outcome. Treat 👀 as "keep waiting", never as approval.

**Pushing a fix does not re-trigger it.** A review is bound to the commit it
read, and the bot only reviews on three events: the PR being opened, a draft
being marked ready, and the comment `@codex review`. Push a fix for a P2 and the
PR still carries a review of the code before the fix, with nothing saying so
except the `Reviewed commit:` line in the review body. Compare that against
`git rev-parse HEAD`; if they differ and the difference matters, ask for another
pass:

```bash
gh pr comment <N> --body "@codex review"
```

**A request can be dropped, so silence is not a verdict.** Turnaround is
normally two or three minutes. Once in this repo a request produced nothing for
38 minutes, and an identical re-request answered in two — so a long silence is
more likely a lost trigger than a slow review. Re-request once before drawing
any conclusion from quiet.

**Re-read the PR before merging, not just before pushing.** Reviews arrive while
you are working, and a review of an earlier commit stays on the PR looking
current. Two arrived unread here during a rewrite and were found only because
somebody asked whether the PR was clear; one of them was a real bypass. Before
merging, list the reviews and check the newest against `HEAD`:

```bash
gh api repos/{owner}/{repo}/pulls/<N>/reviews \
  --jq '.[] | "\(.commit_id[0:10]) \(.submitted_at)"'
git rev-parse --short=10 HEAD
```

Verify each finding against the code before acting on it — findings are written
against the commit they were made on, and one made two revisions ago may already
be fixed, or may no longer describe the design at all. Of three found that way
here, one was real and two had already been closed by an intervening rewrite;
the assertion counts quoted in their text were what gave that away.

**A force-push orphans the reviews.** They stay visible but point at commits no
longer on the branch. If you rewrite a branch that has been reviewed, say in a
comment where each finding went, or the review record is silently lost.

**Do not block on it.** Give it a couple of minutes, and if neither a review nor
a 👍 has appeared, proceed and say so (a lone 👀 is not an answer). An empty `/issues/<N>/comments` is not
evidence the bot stayed silent — check the three endpoints above. Never sit in a
polling loop waiting for it.

## What this image is

A thin derivative of Aurora DX that adds ZFS back. It does not compile ZFS. It
assembles three prebuilt Universal Blue artifacts, and its correctness depends
entirely on those three agreeing about one thing: **the kernel version**.

## The three upstream inputs

| Input                                                  | Referenced at                                                | Provides                                                                                 |
| ------------------------------------------------------ | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `ghcr.io/ublue-os/aurora-dx:stable`                    | [`Containerfile`](Containerfile) `AURORA_IMAGE`/`AURORA_TAG` | The base OS. Its own kernel is discarded.                                                |
| `ghcr.io/ublue-os/akmods:coreos-stable-<N>-x86_64`     | [`Containerfile`](Containerfile) `FROM ... AS akmods`        | `/kernel-rpms` (**the kernel actually shipped**) plus common kmods (xone, v4l2loopback). |
| `ghcr.io/ublue-os/akmods-zfs:coreos-stable-<N>-x86_64` | [`Containerfile`](Containerfile) `FROM ... AS akmods-zfs`    | `/rpms/kmods/zfs` — `kmod-zfs` plus ZFS userspace.                                       |

All three are built by **`ublue-os/akmods`** (not ucore — ucore is a separate
consumer of the same `akmods-zfs` artifacts). Both akmods tags are *floating*:
they are rebuilt on upstream's schedule and silently move to new kernels.

## Build pipeline

1. [`build_files/kernel-akmods.sh`](build_files/kernel-akmods.sh) erases
   Aurora's kernel RPMs and deletes `/usr/lib/modules` entirely, then installs
   the kernel from the **akmods** image and `versionlock`s it.
2. [`build_files/zfs.sh`](build_files/zfs.sh) derives `KERNEL` by reading back
   the single remaining directory under `/usr/lib/modules`, then installs
   `kmod-zfs-${KERNEL}*.rpm` from the **akmods-zfs** image, runs `depmod`, and
   rebuilds the initramfs.
3. [`build_files/build.sh`](build_files/build.sh) and
   [`build_files/post-check.sh`](build_files/post-check.sh) finish and validate.

The load-bearing consequence: `KERNEL` comes from the **akmods** image, but
`kmod-zfs` must come from the **akmods-zfs** image. Nothing forces those two
floating tags to agree.

## Dominant failure mode: kernel / ZFS akmod skew

### Symptom

The `Build and push image` step fails in `zfs.sh` with a glob that matched
nothing:

```
+ KERNEL=<new-kernel>
+ dnf5 -y install /tmp/rpms/kmods/zfs/kmod-zfs-<new-kernel>*.rpm ...
Failed to access RPM "/tmp/rpms/kmods/zfs/kmod-zfs-<new-kernel>*.rpm": No such file or directory
Error: building at STEP "RUN --mount=type=bind,... /ctx/kernel-akmods.sh && /ctx/zfs.sh"
```

The ZFS **userspace** RPMs in the same command resolve fine (`libnvpair*`,
`libzfs*`, `zfs-*`) — they are not kernel-versioned. Only `kmod-zfs` is. Seeing
userspace resolve while `kmod-zfs` fails is the signature of skew, not of a
missing or corrupt artifact.

### Why it happens

`akmods` tracks whatever kernel Fedora ships. `akmods-zfs` can only advance
when OpenZFS supports that kernel. OpenZFS hard-gates this in `configure` using
`Linux-Maximum` from its `META` file. When Fedora's kernel minor version
overtakes `Linux-Maximum` for the current OpenZFS release, upstream's ZFS build
job starts failing, `akmods-zfs` freezes on the last good kernel, `akmods`
keeps moving, and this repo breaks the next time it builds.

This is expected, recurring, and anticipated in the `Containerfile` comments —
it is the same reason Aurora dropped ZFS. It is not a regression in this repo.

### 60-second diagnosis

Confirm the skew first. **Only the two akmods labels decide this.** If they
differ, you already have your answer and can skip the logs:

```bash
FEDORA_VERSION=44
for img in akmods akmods-zfs; do
  printf '%-12s %s\n' "$img" "$(skopeo inspect --format '{{ index .Labels "ostree.linux" }}' \
    "docker://ghcr.io/ublue-os/${img}:coreos-stable-${FEDORA_VERSION}-x86_64")"
done
# context only — not part of the skew test
printf '%-12s %s\n' "aurora-dx" \
  "$(skopeo inspect --format '{{ index .Labels "ostree.linux" }}' docker://ghcr.io/ublue-os/aurora-dx:stable)"
```

The `ostree.linux` label is the authoritative kernel version for these images.

Do **not** treat a differing `aurora-dx` kernel as skew. `kernel-akmods.sh`
erases Aurora's kernel outright, and `zfs.sh` only requires `kmod-zfs` to match
the replacement kernel from `akmods`. This image legitimately runs a kernel
newer than Aurora stable whenever the akmods stream is ahead — that is the
design, not a fault. The `aurora-dx` value is useful context for judging *how
far* ahead the akmods stream has run, nothing more.

Then confirm the failure matches:

```bash
gh run list --limit 10
gh run view <run-id> --log-failed | grep -E "KERNEL=|Failed to access RPM|Error: building"
```

Note `gh run view --log-failed` on this workflow reports the step as
`UNKNOWN STEP` and dumps a lot of image-pull noise; grep is required.

### Tracing to the upstream root cause

Work outward in this order. Do not stop at "the tag is stale" — find the reason
it is stale, because that determines which fix is appropriate.

1. **Is upstream's build failing?**

   ```bash
   gh run list --repo ublue-os/akmods --limit 20
   ```

   Look for `Build COREOS-STABLE akmods`. Then identify the failing job:

   ```bash
   gh run view <run-id> --repo ublue-os/akmods
   ```

   The `Build zfs coreos-stable (<N>)` jobs are the relevant ones.

2. **Why is the ZFS job failing?** The kernel gate appears in the `Test Image`
   step:

   ```bash
   gh run view --repo ublue-os/akmods --job <job-id> --log \
     | grep -E "Cannot build against kernel|maximum supported kernel"
   ```

   Expected output when this is a version gate:

   ```
   *** Cannot build against kernel version <kernel>.
   *** The maximum supported kernel version is <X.Y>.
   ```

3. **Has OpenZFS raised the ceiling yet?** `master` raises `Linux-Maximum`
   first, but what matters is the **release branch**, since that is what
   upstream akmods builds against. Compare them:

   ```bash
   for ref in master zfs-2.4-release; do
     printf '%-18s ' "$ref"
     gh api "repos/openzfs/zfs/contents/META?ref=$ref" --jq '.content' \
       | base64 -d | grep -E "Version:|Linux-Maximum:" | tr '\n' ' '; echo
   done
   ```

   To estimate how long a backport will take, look at the cadence of past
   compat bumps on the release branch:

   ```bash
   gh api repos/openzfs/zfs/commits -X GET -f path=META -f sha=zfs-2.4-release \
     --jq '.[] | "\(.commit.author.date[0:10]) \(.commit.message | split("\n")[0])"' | head
   ```

   OpenZFS reliably backports `Linux N.M compat: META` to the active release
   branches — historically same-day or within a week of master — and tags a
   point release days to a couple of weeks later. A long gap between a master
   compat bump and the backport usually just means no point release has been
   cut yet.

4. **What tags are actually available to pin to?**

   ```bash
   skopeo list-tags docker://ghcr.io/ublue-os/akmods     | grep coreos-stable-44 | sort -V
   skopeo list-tags docker://ghcr.io/ublue-os/akmods-zfs | grep coreos-stable-44 | sort -V
   ```

   Kernel-pinned tags look like `coreos-stable-44-7.0.12-201.fc44.x86_64`. A
   pin is only viable if the **same** kernel-pinned tag exists in *both*
   repositories.

5. **Upstream policy**, if the streams behave inconsistently:

   ```bash
   gh api repos/ublue-os/akmods/contents/images.yaml --jq '.content' | base64 -d | head -20
   ```

   The `zfs:` block sets `minor_version` and `linux_experimental` per kernel
   flavor. `coreos-testing` typically sets `linux_experimental: true`, which
   passes OpenZFS's `--enable-linux-experimental` and bypasses the
   `Linux-Maximum` check. That is why a `coreos-testing` ZFS build for a new
   kernel can exist while `coreos-stable` has none.

## Fix options

Listed in ascending order of risk.

**Wait.** Legitimate and usually correct. Upstream's stable ZFS job goes green
on its own once OpenZFS tags a release whose `Linux-Maximum` covers Fedora's
kernel; the floating tags then re-converge and this repo builds again with no
change at all.

Crucially, this is automatic only *within* the pinned minor series. Upstream's
`images.yaml` pins ZFS to a `minor_version` (e.g. `"2.4"`), so a 2.4.x point
release carrying the compat bump flows through with no action from anyone. If
the ceiling is raised only in the *next* minor (2.5), upstream ublue must first
bump `minor_version` — a PR on their side, so a longer and less certain wait.
Check step 3 to determine which case applies before committing to waiting.

There is a third resolution path worth checking for before assuming the wait is
gated on OpenZFS at all: ublue can **carry the upstream commits as patches** on
the pinned release rather than wait for the tag. They did exactly this in
akmods#566 (see incident log). So when the OpenZFS release branch looks stuck,
check for a ublue-side patch PR before concluding that nothing is moving:

```bash
gh pr list --repo ublue-os/akmods --search zfs --state all --limit 20
```

`--state all` is load-bearing. `gh pr list` defaults to `--state open`, and the
window that matters most is the one *after* a patch PR merges but *before* the
floating tag rebuilds — exactly when the default would show nothing and lead you
to pin unnecessarily. The default also hides #554 and #566, the two PRs this
file tells you to look for.

Waiting is also not the same as waiting for the cron. The workflow has
`workflow_dispatch`, so once the `akmods-zfs` label re-converges you can build
on demand instead of losing up to a week to the Sunday schedule.

The cost of waiting is that **no new image is published**, so the deployed
system stops receiving Aurora and security updates until it clears. The
scheduled build runs weekly (`00 05 * * 0`), so the CI noise is one failed run
per Sunday — but that same cadence is also the normal refresh rate, so each
week spent waiting is one skipped image. Fine for a short gap, bad for a long
one.

**Pin both images to the last matching kernel.** In the `Containerfile`,
replace *both* floating tags with the same kernel-pinned tag, e.g.
`coreos-stable-44-7.0.12-201.fc44.x86_64`. This restores builds immediately and
keeps Aurora userspace updates flowing. They must be pinned **together** — the
`Containerfile` comments say so, and pinning only one recreates the skew. Both
must be unpinned again later, or the image is frozen on an unpatched kernel;
leave a tracking note when doing this.

**Take the ZFS kmod from the `coreos-testing` stream.** Before dismissing this
as reckless, check *why* `Linux-Maximum` is low. There are two very different
cases, and they call for opposite decisions:

- *The compat code does not exist yet.* Genuinely unsupported. Avoid.
- *The compat code landed, but the cap was not raised because the kernel was
  not final at release time.* Then the cap is *metadata*, and
  `--enable-linux-experimental` is the workaround OpenZFS maintainers
  themselves recommend. Read the relevant openzfs/zfs issue before judging.

The 2026-07 event was the second kind (see incident log). Note the two streams
publish builds for the **same** kernel, so the pin can be mixed — the kernel
still comes from `coreos-stable`, only the ZFS kmod comes from
`coreos-testing`:

```Dockerfile
FROM ghcr.io/ublue-os/akmods:coreos-stable-44-7.1.3-200.fc44.x86_64 AS akmods
FROM ghcr.io/ublue-os/akmods-zfs:coreos-testing-44-7.1.3-200.fc44.x86_64 AS akmods-zfs
```

Verify the `ostree.linux` labels are identical before doing this — that is the
whole safety property. This keeps the stable kernel stream and confines the
"experimental" part to the configure flag.

Do not "fix" this by loosening the glob in `zfs.sh` or making the kmod install
non-fatal. A `kmod-zfs` built for a different kernel will not load, and the
failure would move from the build to the boot.

## Other failure modes

Not every red build is skew. Before tracing upstream kernel versions, check
*which step* failed — skew always dies inside `zfs.sh` during
`Build Image`. A failure in a later step is something else.

### Chunkah rechunk: `Argument list too long` (exit 126)

Symptom, in `Rechunk Image with Chunkah`:

```
/home/runner/work/_temp/....sh: line NN: /usr/local/bin/podman: Argument list too long
##[error]Process completed with exit code 126.
```

The image itself built fine; this is the re-layering step. `CHUNKAH_CONFIG_STR`
is passed to `podman run -e`, and Linux caps a single argv/env string at
`MAX_ARG_STRLEN` (32 pages = 128 KiB). A full `podman inspect` embeds per-layer
data three times over (`RootFS.Layers`, `History`,
`GraphDriver.Data.LowerDir`), so it grows with the base image's layer count and
crossed the cap when Aurora went from 128 to 256 layers on 2026-08-25.

The step now passes `--format '{{json .Config}}'`, which is what Chunkah
documents `--config-str` as taking; `.Config` carries no per-layer data and
stays ~1.5 KiB. If this recurs, look for something *else* in the pipeline
piping large JSON through the environment rather than reverting to the full
inspect.

Layer count of the current base:

```bash
skopeo inspect --raw docker://ghcr.io/ublue-os/aurora-dx:stable \
  | jq '.layers | length'
```

## Incident log

Keep this appended to; the recurrence pattern is the useful part.

### 2026-07-22: Fedora kernel 7.1 vs OpenZFS 2.4.3

- Last green scheduled build 2026-07-19. First failure 2026-07-22 (PR run),
  then every scheduled run.
- `akmods:coreos-stable-44-x86_64` moved to `7.1.3-200.fc44.x86_64`;
  `akmods-zfs:coreos-stable-44-x86_64` stayed at `7.0.12-201.fc44.x86_64`.
  `aurora-dx:stable` was also still on `7.0.12-201.fc44.x86_64`, so the akmods
  stable stream had run ahead of Aurora itself.
- Upstream `Build COREOS-STABLE akmods` failing daily; `Build zfs
  coreos-stable (44)` died in `Test Image` with
  `*** The maximum supported kernel version is 7.0.`
- Cause: newest tagged OpenZFS was `zfs-2.4.3` (2026-06-12) with
  `Linux-Maximum: 7.0`. OpenZFS `master` (2.4.99) already had
  `Linux-Maximum: 7.1`, but no tagged 2.4.x release carried it.
- `akmods-zfs:coreos-testing-44-7.1.3-200.fc44.x86_64` did exist, via
  `linux_experimental: true` for `coreos-testing` (ublue-os/akmods PR #554).
- Viable pin at the time: `coreos-stable-44-7.0.12-201.fc44.x86_64`, present in
  both `akmods` and `akmods-zfs`.
- Backport status as of 2026-07-26: `Linux 7.1 compat: META` (#18682) landed on
  `master` 2026-06-17, five days *after* 2.4.3 was tagged, and had not yet been
  backported to `zfs-2.4-release`. Since ublue pins `minor_version: "2.4"`, a
  2.4.4 carrying the backport would resolve this with no change to this repo or
  to ublue.
- **The cap was metadata-only.** In
  [openzfs/zfs#18760](https://github.com/openzfs/zfs/issues/18760), maintainer
  `behlendorf` stated on 2026-07-08 that the needed 7.1 compatibility patches
  shipped in **2.4.2**, and were simply not declared supported because the 7.1
  kernel was not final at release time; that building with
  `--enable-linux-experimental` is safe for 7.1; and that 7.1 would be on by
  default in the next release. So the `coreos-testing` kmod was not a gamble
  here — it was the upstream-recommended workaround.

### 2026-08-09: kernel moves to 7.1.4; ublue patches 2.4.3 directly

Same skew, one kernel bump further along, but the resolution path changed.

- Scheduled run [31296445197](https://github.com/Danathar/aurora-zfs-simple/actions/runs/31296445197)
  failed with `KERNEL=7.1.4-200.fc44.x86_64` and the usual
  `Failed to access RPM ".../kmod-zfs-7.1.4-200.fc44.x86_64*.rpm"`.
- Labels: `akmods:coreos-stable-44-x86_64` had advanced 7.1.3 → **7.1.4-200**,
  while `akmods-zfs:coreos-stable-44-x86_64` was **still 7.0.12-201**, frozen
  since July. `aurora-dx:stable` was also still 7.0.12-201.
- Upstream `Build COREOS-STABLE akmods` still failing daily, same gate:
  `*** The maximum supported kernel version is 7.0.` (both 43 and 44, both
  arches).
- OpenZFS had **not** moved in seven weeks: `zfs-2.4-release` still 2.4.3 with
  `Linux-Maximum: 7.0`, newest tagged release still `zfs-2.4.3` (2026-06-12).
  The "just wait for 2.4.4" expectation from the July entry did not pan out.
- **The fix came from ublue instead.**
  [ublue-os/akmods#566](https://github.com/ublue-os/akmods/pull/566)
  (`bsherman`, opened 2026-08-09) stops waiting for 2.4.4 and applies the two
  upstream commits as patches on 2.4.3: `a35e8d8` (openzfs/zfs#18682, the
  one-line `Linux-Maximum` 7.0 → 7.1) and `223b8bc` (openzfs/zfs#18715, a real
  bounds check replacing a debug-only `ASSERT3U` in `zfs_fillpage()` /
  `zfs_getpage()`). The patches are gated to 2.4.3 and turn themselves off when
  2.4.4 arrives. It also drops `linux_experimental` for `coreos-testing`, since
  the META bump makes the flag unnecessary.
- **Decision: wait, no `Containerfile` change.** #566 was maintainer-authored,
  green across every flavor and arch, and blocking `ucore:stable` too, so the
  expected wait was days. Plan was to watch the `akmods-zfs` stable label and
  `workflow_dispatch` as soon as it read 7.1.x, falling back to the mixed pin if
  the 2026-08-16 scheduled run also failed.
- The mixed pin was verified available at the time and deliberately not taken:
  `akmods:coreos-stable-44-7.1.4-200.fc44.x86_64` and
  `akmods-zfs:coreos-testing-44-7.1.4-200.fc44.x86_64` both reported
  `ostree.linux = 7.1.4-200.fc44.x86_64`. Two reasons to prefer waiting over
  pinning when the wait is short: that `coreos-testing` kmod predates #566, so
  it was built `--enable-linux-experimental` (dmesg spam that masks real
  errors), and it lacks the #18715 mmap fix. Pinning would have bought a newer
  kernel while keeping a memory-corruption bug that waiting removes.

**Generalizable lesson:** a stalled OpenZFS release branch is no longer
sufficient evidence that the wait is open-ended. Check for a ublue-side patch PR
before reaching for a pin.

### Upstream issue map (where to look first)

- **openzfs/zfs** — the root cause always lands here first. #18760 tracked the
  7.1 request; #18767 covered the resulting dnf downgrade weirdness. #18682 is
  the `Linux-Maximum` 7.0 → 7.1 META bump and #18715 the `zfs_fillpage()` /
  `zfs_getpage()` mmap bounds check — the two commits akmods#566 backports.
- **ublue-os/akmods** — carries the *policy*, and sometimes the *fix*. PR #554
  (merged 2026-07-20) moved ZFS release policy into `images.yaml` and added the
  per-flavor `linux_experimental` switch, enabled for `coreos-testing` only. PR
  #566 (opened 2026-08-09) went further and patched 2.4.3 directly rather than
  waiting for an OpenZFS tag, which is the precedent to look for when the
  release branch stalls. Issue #523 is a *different*, older ZFS CI problem
  (aarch64 NEON / GCC 16) — do not confuse the two.
- **ublue-os/ucore** — the other big ZFS consumer, but it rides Fedora CoreOS,
  whose stable stream lags Fedora proper, so it usually hits these walls much
  later than this repo does. Green builds there are not evidence this repo is
  fine.
- **ublue-os/aurora** — will not fix ZFS breakage. Aurora is *removing* ZFS
  (#1765: dropped starting with Fedora 45 images, Fall 2026; #2210 and PR #2613
  add a deprecation notifier). Expect no upstream help from Aurora, and expect
  this repo to be the sole carrier of ZFS after Fedora 45.
- **ublue-os/bluefin** — does not ship ZFS. Not a useful signal.
