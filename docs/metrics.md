# Metrics

Reproducible commands, and an honest account of what the numbers are worth on a
repo this size.

There is no metrics service and no scheduled collector. Adding one would be more
machinery than the signal justifies — roughly forty merged PRs total, most of
them Dependabot. What follows is what to run when the question actually comes
up, and how to avoid drawing a conclusion the data does not support.

## PR acceptance

```bash
merged=$(gh pr list --state merged --limit 500 --json number -q 'length')
rejected=$(gh pr list --state closed --limit 500 --json number,mergedAt \
  -q '[.[] | select(.mergedAt == null)] | length')
printf 'merged %s, closed unmerged %s, acceptance %s%%\n' \
  "$merged" "$rejected" "$(( merged * 100 / (merged + rejected) ))"
```

At the time of writing: 35 merged, 6 closed unmerged, 85%.

**What that does not mean.** A high acceptance rate on a single-maintainer repo
measures how often the maintainer merges their own work, not review quality. The
figure only becomes interesting when broken out by author:

```bash
gh pr list --state merged --limit 500 --json author -q \
  '[.[].author.login] | group_by(.) | map({author: .[0], merged: length}) | sort_by(-.merged)[]'
```

Dependabot dominates the count. Separate bot PRs from human ones before reading
anything into a trend.

## Which changes get pushed back on

More useful than the acceptance rate, because it is about substance:

```bash
# Review comments per PR, most-reviewed first
gh pr list --state merged --limit 50 --json number -q '.[].number' | while read -r n; do
  c=$(gh api "repos/{owner}/{repo}/pulls/$n/comments" -q 'length')
  [ "$c" -gt 0 ] && printf '%s\t%s\n' "$c" "$n"
done | sort -rn
```

Most inline review comments here come from `chatgpt-codex-connector[bot]`. Its
findings carry a severity badge and are *often* right, not automatically right —
`AGENTS.md` covers how to fetch and respond to them. A PR that accumulated
several P1/P2 findings is worth reading afterward to see whether the class of
mistake is one the tests or the rubric should have caught.

## Build health

The number that matters is not the pass rate — it is **how many consecutive
scheduled builds were lost**, since each one is a skipped image refresh and
therefore a week of missed Aurora and security updates.

```bash
gh run list --workflow build.yml --event schedule --limit 20 \
  --json createdAt,conclusion -q '.[] | "\(.createdAt[0:10])\t\(.conclusion)"'
```

A run of failures here during upstream skew is expected and is not a repo
health signal. Correlate against the OpenZFS/kernel badge before treating it as
one: red builds *with* a green badge are the ones worth investigating.

```bash
gh run list --workflow build.yml --limit 40 \
  --json conclusion -q '[.[] | select(.conclusion == "failure")] | length'
```

## Image freshness

What a user actually experiences. Same source as the "last good build" badge:

```bash
skopeo inspect --format '{{.Created}}' \
  docker://ghcr.io/danathar/aurora-zfs-simple:latest
```

More than two weeks old means at least two scheduled builds did not produce an
image. That is the threshold worth reacting to, because the weekly schedule
means one miss is routine.

## Deliberately not tracked

- **Test coverage percentage.** Most of this repo's shell only runs inside an
  image build and cannot be reached from the host, so a percentage would sit
  near zero or be gamed. The `MANIFEST` in `tests/test-coverage.sh` records
  which scripts are unreachable and why — a stated decision per script rather
  than a number — while `tests/README.md` explains the gate.
- **Time to merge.** Single maintainer; it measures availability, not process.
- **Image size over time.** Chunkah's layering makes this non-comparable across
  base-image changes, and nothing acts on the number.
