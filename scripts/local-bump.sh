#!/usr/bin/env bash
# scripts/local-bump.sh — local equivalent of .github/workflows/yolo-update.yml.
#
# Mirrors the workflow's structure step-for-step so the workflow file stays
# the source of truth: select → apply → validate (linux or macOS). Reuses
# scripts/update-pins.sh for select/apply and scripts/hm-activation-macos.sh
# for the macOS HM activation step.
#
# Skips the workflow's "promote" job (commit + rebase + push to main); the
# working tree is left dirty for review.
#
# Usage:
#   scripts/local-bump.sh                   # bump to latest stable
#   scripts/local-bump.sh --system <SYSTEM> # override target system
#   scripts/local-bump.sh --skip-validate   # apply only, skip the CI smoke
#
# Detected system defaults: x86_64-linux on Linux, aarch64-darwin on macOS.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

target_system=""
skip_validate=false
while [[ $# -gt 0 ]]; do
  case "$1" in
  --system)
    target_system="$2"
    shift 2
    ;;
  --system=*)
    target_system="${1#--system=}"
    shift
    ;;
  --skip-validate)
    skip_validate=true
    shift
    ;;
  -h | --help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

if [[ -z "$target_system" ]]; then
  case "$(uname -s)" in
  Linux) target_system="x86_64-linux" ;;
  Darwin) target_system="aarch64-darwin" ;;
  *)
    echo "Unsupported host: $(uname -s)" >&2
    exit 1
    ;;
  esac
fi

# Setting this so that we can use update-pins.sh rather than rewriting all it's logic in here.
export GITHUB_ACTIONS="true"

# ---- select (yolo-update.yml: jobs.select) -----------------------------
selection="$(scripts/update-pins.sh select)"
if [[ -z "$selection" ]]; then
  echo "Already pinned to the latest stable release. Nothing to do." >&2
  exit 0
fi

release_tag=""
release_sha=""
app_url=""
release_version=""
while IFS='=' read -r key value; do
  case "$key" in
  release_tag) release_tag="$value" ;;
  release_sha) release_sha="$value" ;;
  app_url) app_url="$value" ;;
  release_version) release_version="$value" ;;
  esac
done <<<"$selection"

if [[ -z "$release_tag" || -z "$release_sha" || -z "$app_url" ]]; then
  echo "select did not return a complete release record:" >&2
  echo "$selection" >&2
  exit 1
fi

echo ">> Selected $release_tag ($release_sha) for $target_system" >&2

# ---- apply (yolo-update.yml: jobs.validate-{linux,macos}.steps[Materialize]) -
scripts/update-pins.sh apply "$release_tag" "$release_sha" "$app_url"

if $skip_validate; then
  echo ">> --skip-validate: pin applied, leaving smoke test to caller." >&2
  exit 0
fi

# ---- validate (yolo-update.yml: jobs.validate-{linux,macos}.steps[*]) --
case "$target_system" in
x86_64-linux | aarch64-linux)
  scripts/check-flake-lock-owners.sh
  nix build ".#checks.${target_system}.ci" --accept-flake-config
  ;;
aarch64-darwin | x86_64-darwin)
  nix build ".#checks.${target_system}.ci" --accept-flake-config
  scripts/hm-activation-macos.sh
  ;;
*)
  echo "Unsupported target system: $target_system" >&2
  exit 1
  ;;
esac

echo ">> Bumped to $release_tag and validated $target_system. Working tree is dirty." >&2
echo ">> Review with: git diff --stat" >&2
echo ">> Commit and push when satisfied." >&2
