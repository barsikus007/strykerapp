#!/bin/bash
# Propose a stryker_manifest.json change as a pull request.
#
# The manifest pins the sha256 of every download, so it is never written by a
# build: it is reviewed. A workflow builds the artifact, runs
# images/lib/update-manifest.py, and hands the result to this, which puts the
# diff in front of a human before the app starts trusting it.
#
# usage: manifest-pr.sh <branch> <title> [extra-body-file]
set -euo pipefail

BRANCH=${1:?usage: manifest-pr.sh <branch> <title> [extra-body-file]}
TITLE=${2:?usage: manifest-pr.sh <branch> <title> [extra-body-file]}
EXTRA=${3:-}

cd "$(dirname "$0")/../.."
MANIFEST=stryker_manifest.json

# Compared against the commit this started from, not against HEAD: on a re-run
# HEAD already carries the change, `git diff` is empty, and the update would be
# silently dropped instead of pushed.
BASE_REF=${BASE_REF:-HEAD}
if git diff --quiet "$BASE_REF" -- "$MANIFEST"; then
	printf 'manifest-pr.sh: %s is unchanged -- nothing to propose\n' "$MANIFEST"
	exit 0
fi

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

printf '%s\n' "$TITLE" > "$BODY"
printf '\n%s\n\n' 'Written by CI from the artifact it actually built. Review the
checksums against the release before merging -- the app refuses a download whose
sha256 does not match, and ships a *different* core to every install that
manages to fetch one.' >> "$BODY"

if [ -n "$EXTRA" ] && [ -f "$EXTRA" ]; then
	printf '\n<details><summary>build</summary>\n\n```\n' >> "$BODY"
	cat "$EXTRA" >> "$BODY"
	printf '```\n\n</details>\n' >> "$BODY"
fi

printf '\n<details><summary>diff vs %s</summary>\n\n```diff\n' "$BASE_REF" >> "$BODY"
git --no-pager diff "$BASE_REF" -- "$MANIFEST" >> "$BODY"
printf '```\n\n</details>\n' >> "$BODY"

git config user.name  'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git checkout -B "$BRANCH"
git add -- "$MANIFEST"
if git diff --cached --quiet -- "$MANIFEST"; then
	printf 'the branch already carries this manifest -- nothing new to commit\n'
else
	git commit -m "$TITLE"
fi

git fetch --quiet origin "$BRANCH" 2>/dev/null || true
git push --force-with-lease origin "$BRANCH"

if gh pr view "$BRANCH" --json number >/dev/null 2>&1; then
	printf 'updating the existing pull request for %s\n' "$BRANCH"
	gh pr edit "$BRANCH" --title "$TITLE" --body-file "$BODY" >/dev/null
else
	gh pr create --base "${BASE_BRANCH:-main}" --head "$BRANCH" \
		--title "$TITLE" --body-file "$BODY" >/dev/null
	printf 'opened a pull request for %s\n' "$BRANCH"
fi

gh pr view "$BRANCH" --json url --jq .url