# A tag set is not a thing you can assume

**2026-07-02** — publishing, signing

## What happened

The workflow pushed the same local image once per tag: `latest`,
`latest.YYYYMMDD`, `YYYYMMDD`. That looks like three names for one artifact, and
it was not.

podman can emit different manifest bytes for sequential pushes of the same local
image — the first push compresses and uploads, later pushes reuse cached blob
info — and the resulting manifests can carry different digests. So the tags
drifted apart, and because signing operates on **one digest**, `latest` could
end up pointing at a manifest that was never signed.

Nothing failed. The build was green, every tag existed, every tag pulled. The
defect was only visible if you compared the digests, which nothing did.

## What changed

Push exactly one tag, then copy that manifest server-side to the others with
`skopeo copy --preserve-digests`, which fails rather than rewriting a manifest.
Then, before signing, assert the property outright: `Verify pushed tags share
one digest` resolves every published tag and fails the run if any of them
disagrees.

Both steps are in [`.github/workflows/build.yml`](../../.github/workflows/build.yml).

**Follow-up, 2026-10-06 (#348):** the order is now push, sign, copy, verify.
Pushing `latest` first meant that any failure between the push and the
signature left hosts following an unsigned image until the next good build. The
push now publishes only `latest.YYYYMMDD`, which no host follows, that digest
is signed, and only then is it copied to the other tags, with `latest` last.
`Verify pushed tags share one digest` runs after the copies and checks the
finished tag set against the signed digest.

## What to carry forward

**An invariant that nothing checks is a belief.** The pipeline "obviously"
produced one manifest per build, and that belief was load-bearing for signing.
The cheap fix was not the `skopeo copy` — it was the four-line loop that turns
the belief into a failure when it stops being true.

Two consequences for this repo:

- When a step's correctness depends on two artifacts being identical, compare
  them. Digest comparisons cost a second.
- Green CI proved nothing here because nothing was asking the right question.
  When reviewing a change to publishing or signing, ask what would have to go
  wrong for CI to still be green — that is the failure mode you have.

`.github/workflows/nightly-compliance.yml` now re-checks this against the
*published* registry rather than only at push time, because the property can
break after the run that established it.
