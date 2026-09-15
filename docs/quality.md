# Quality

Where the signal about this repo actually comes from, and what each source can
and cannot tell you.

There is no dashboard service here. The dashboard is three badges in
`README.md`, two CI workflows, and a shell suite — and the useful thing to write
down is what each one *means*, because two of the badges are routinely
misread.

## The badges

| Badge               | Source                                                                   | Answers                                     |
| ------------------- | ------------------------------------------------------------------------ | ------------------------------------------- |
| **build**           | Actions status for `build.yml` on `main`                                 | Did the last run pass?                      |
| **last good build** | `Created` timestamp on the published `:latest` image                     | Is there a usable image, and how old is it? |
| **OpenZFS/kernel**  | `ostree.linux` labels on the two akmods images the `Containerfile` pulls | If the build is red, *why*?                 |

Read them together. A red **build** with a recent **last good build** and a
`blocked` **OpenZFS/kernel** is the normal, expected state during upstream skew:
the published image is still installable and still boots, it just has not been
refreshed. That is very different from a red build with a green OpenZFS/kernel
badge, which means something in *this* repo broke.

Two properties of the badge pipeline are deliberate and worth knowing:

- **It refuses to guess.** If `ci/write-badges.sh` cannot read an input, it
  leaves that badge at its last value rather than overwriting it with something
  invented. A stale-but-true badge beats a fresh-but-wrong one, so a badge that
  has not moved is not automatically a badge that is working.
- **It does not read build logs.** The OpenZFS/kernel badge is derived from
  upstream labels, so it goes green again the moment upstream re-converges,
  without waiting for a build to prove it. It runs on its own daily schedule
  rather than only after a build, because skew appears and clears between this
  repo's weekly builds.

## The gates

| Gate                                  | Runs on                                 | Blocks                                     |
| ------------------------------------- | --------------------------------------- | ------------------------------------------ |
| `Shell tests` job in `build.yml`      | every PR and push, minus `paths-ignore` | `build_push`, via `needs: tests`           |
| The image build itself                | same                                    | publishing — a failed build pushes nothing |
| `post-check.sh`                       | inside the build, as a `RUN` step       | the build                                  |
| `bootc container lint`                | inside the build, as a `RUN` step       | the build                                  |
| `Verify pushed tags share one digest` | default-branch non-PR runs              | signing                                    |

### What each one does not cover

`Shell tests` cannot reach `build_files/build.sh`,
`build_files/kernel-akmods.sh`, `build_files/zfs.sh` or the `Containerfile`;
those scripts do their work at the top level inside an image build. A green
suite is not evidence for a change to any of them.

`build_files/post-check.sh` is the exception: its `BASH_SOURCE`-guarded entry
point lets the suite source and exercise its helpers.

`post-check.sh` and `bootc container lint` are `RUN` steps, so they validate the
image **before** the workflow hands it to Chunkah. The re-layered archive that
comes back is loaded, tagged, pushed and signed with neither running again.
`Verify pushed tags share one digest` proves every tag resolves to one manifest;
it says nothing about that manifest's contents. **There is no automated check on
the far side of the rechunk.**

`post-check.sh` also cannot prove a real pool imports — the runner does not give
the build those devices. It proves the image *contains* the right kernel
modules, tools, libraries and boot integration.

## Reading a red build

Start at the OpenZFS/kernel badge, not the logs. If it says `blocked`, the cause
is upstream and `AGENTS.md` has the diagnosis and the options. If it does not,
check which step failed and match it against
[Other failure modes](../AGENTS.md#other-failure-modes).

## What is not measured

Honest list, so nobody assumes otherwise:

- no coverage percentage — most of this repo's shell cannot be reached from the
  host, so the number would be meaningless
- no performance or image-size tracking over time
- no post-rechunk content validation in CI
- no runtime verification that ZFS works on a booted system; the manual checks
  after a rebase are in `README.md`
