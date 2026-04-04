#!/usr/bin/env bash
set -euo pipefail

CHANGELOG="CHANGELOG.md"
VERSION="${1:-}"

usage() {
  echo "Usage: $0 <version-tag>"
  echo "Example: $0 v1.3.0"
  exit 1
}

[[ -n "$VERSION" ]] || usage
[[ -f "$CHANGELOG" ]] || { echo "Missing file: $CHANGELOG" >&2; exit 1; }

command -v git >/dev/null 2>&1 || { echo "Missing command: git" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "Missing command: gh" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "Missing command: awk" >&2; exit 1; }
command -v sed >/dev/null 2>&1 || { echo "Missing command: sed" >&2; exit 1; }
command -v mktemp >/dev/null 2>&1 || { echo "Missing command: mktemp" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Not inside a git repository." >&2
  exit 1
}

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree is not clean. Commit or stash changes first." >&2
  exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Tag already exists: $VERSION" >&2
  exit 1
fi

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "$LAST_TAG" ]]; then
  echo "No previous tag found. Aborting." >&2
  exit 1
fi

COMMITS="$(git log --pretty=format:'%s' "${LAST_TAG}..HEAD")"
if [[ -z "$COMMITS" ]]; then
  echo "No commits found since $LAST_TAG" >&2
  exit 1
fi

tmp_added="$(mktemp)"
tmp_changed="$(mktemp)"
tmp_fixed="$(mktemp)"
tmp_other="$(mktemp)"
tmp_block="$(mktemp)"
tmp_changelog="$(mktemp)"

cleanup() {
  rm -f "$tmp_added" "$tmp_changed" "$tmp_fixed" "$tmp_other" "$tmp_block" "$tmp_changelog"
}
trap cleanup EXIT

while IFS= read -r subject; do
  [[ -z "$subject" ]] && continue
  line="$subject"

  case "$subject" in
    feat:*|feat\(*\):*)
      printf -- "- %s\n" "${line#*: }" >> "$tmp_added"
      ;;
    fix:*|fix\(*\):*)
      printf -- "- %s\n" "${line#*: }" >> "$tmp_fixed"
      ;;
    refactor:*|refactor\(*\):*)
      printf -- "- %s\n" "${line#*: }" >> "$tmp_changed"
      ;;
    perf:*|perf\(*\):*)
      printf -- "- %s\n" "${line#*: }" >> "$tmp_changed"
      ;;
    docs:*|docs\(*\):*)
      ;;
    chore:*|chore\(*\):*)
      ;;
    install:*|trackrec-status:*|trackrec-enrich:*|spotify_apply_tags:*)
      printf -- "- %s\n" "${line#*: }" >> "$tmp_changed"
      ;;
    *)
      printf -- "- %s\n" "$line" >> "$tmp_other"
      ;;
  esac
done <<< "$COMMITS"

{
  echo "## $VERSION"
  echo

  if [[ -s "$tmp_added" ]]; then
    echo "### Added"
    cat "$tmp_added"
    echo
  fi

  if [[ -s "$tmp_changed" || -s "$tmp_other" ]]; then
    echo "### Changed"
    [[ -s "$tmp_changed" ]] && cat "$tmp_changed"
    [[ -s "$tmp_other" ]] && cat "$tmp_other"
    echo
  fi

  if [[ -s "$tmp_fixed" ]]; then
    echo "### Fixed"
    cat "$tmp_fixed"
    echo
  fi
} > "$tmp_block"

echo
echo "Last tag: $LAST_TAG"
echo "New tag : $VERSION"
echo
echo "Generated changelog block:"
echo "------------------------------------------------------------"
cat "$tmp_block"
echo "------------------------------------------------------------"
echo

read -r -p "Write this to $CHANGELOG and create release? [y/N]: " confirm
case "${confirm:-N}" in
  y|Y) ;;
  *)
    echo "Aborted."
    exit 0
    ;;
esac

{
  echo "# Changelog"
  echo
  cat "$tmp_block"
  sed '1{/^# Changelog$/d;}' "$CHANGELOG" | sed '1{/^$/d;}'
} > "$tmp_changelog"

mv "$tmp_changelog" "$CHANGELOG"

git add "$CHANGELOG"
git commit -m "chore(release): prepare $VERSION"

git tag "$VERSION"

current_branch="$(git branch --show-current)"
if [[ -z "$current_branch" ]]; then
  echo "Could not determine current branch." >&2
  exit 1
fi

git push origin "$current_branch"
git push origin "$VERSION"

notes="$(awk -v tag="$VERSION" '
  $0 ~ "^## " tag "$" { in_section=1; next }
  in_section && $0 ~ "^## " { exit }
  in_section { print }
' "$CHANGELOG")"

if [[ -z "$notes" ]]; then
  echo "Failed to extract release notes for $VERSION from $CHANGELOG" >&2
  exit 1
fi

if gh release view "$VERSION" >/dev/null 2>&1; then
  echo "GitHub release already exists: $VERSION"
  exit 0
fi

gh release create "$VERSION" \
  --title "$VERSION" \
  --notes "$notes"

echo
echo "Release created: $VERSION"