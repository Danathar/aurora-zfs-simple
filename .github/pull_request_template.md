## What this changes

<!-- One or two sentences. What was wrong, or what is new. -->

## Why

<!-- The reasoning, especially if the change reverses an earlier decision or
     touches something the comments call deliberate. -->

## Checks

- [ ] `./tests/run-tests.sh` passes locally
- [ ] `shellcheck` was installed while running it, so its pass was enforced and
      not skipped (CI installs it; a developer machine may not have it)
- [ ] Docs that name a path or describe behaviour still match the code.
      README.md and AGENTS.md are load-bearing incident-response inputs

## If this touches the image build

`build_files/build.sh`, `build_files/kernel-akmods.sh`, `build_files/zfs.sh` and
the `Containerfile` only really run inside a full image build, which the shell
suite cannot reach. (`post-check.sh` has sourceable helpers.) If you changed
image-build code:

- [ ] I have said below how it was verified, or that it was not

<!-- A green `Build container image` run on this PR is the strongest evidence.
     Note that it does not publish or sign anything from a PR. -->

## Notes for review

<!-- Anything you want looked at closely, or a decision you are unsure about.
     If a build here is red because of upstream kernel / ZFS akmod skew rather
     than this change, say so and link AGENTS.md's diagnosis. -->
