#!/usr/bin/env bash
set -euo pipefail

CHANGELOG="CHANGELOG.md"
TAG=""

usage() {
  echo "Usage:"
  echo "  $0 [--tag <tag>] [--file <CHANGELOG.md>]"
  echo
  echo "Default: uses latest git tag."
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --file)
      CHANGELOG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# default tag = latest
if [[ -z "$TAG" ]]; then
  TAG="$(git describe --tags --abbrev=0)"
fi

[[ -f "$CHANGELOG" ]] || { echo "Missing file: $CHANGELOG" >&2; exit 1; }

notes="$(awk -v tag="$TAG" '
  $0 ~ "^## " tag "$" { in_section=1; next }
  in_section && $0 ~ "^## " { exit }
  in_section { print }
' "$CHANGELOG")"

if [[ -z "$notes" ]]; then
  echo "No changelog entry found for $TAG in $CHANGELOG" >&2
  exit 2
fi

echo "Creating GitHub release for tag: $TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists."
  exit 0
fi

gh release create "$TAG" \
  --title "$TAG" \
  --notes "$notes"