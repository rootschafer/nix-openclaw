#!/usr/bin/env bash
# scripts/local-bump.sh — local equivalent of
# .github/workflows/pin-stable-openclaw-version.yml.
#
# Mirrors the workflow's structure step-for-step so the workflow file stays
# the source of truth: select → apply (materialize) → validate (linux or
# macOS). Reuses scripts/update-pins.sh for select/apply,
# scripts/check-flake-lock-owners.sh on Linux, and
# scripts/hm-activation-macos.sh for the macOS HM activation step.
#
# Skips the workflow's "promote" job (commit + rebase + push to main); the
# working tree is left dirty for review.
#
# Usage:
#   scripts/local-bump.sh                   # bump to latest stable
#   scripts/local-bump.sh --system <SYSTEM> # override target system
#   scripts/local-bump.sh --skip-validate   # apply only, skip the CI smoke
#
# Requires: gh (authenticated), jq, node, nix, nix-prefetch-url, perl, unzip.
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
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
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
  Darwin)
    case "$(uname -m)" in
    arm64 | aarch64) target_system="aarch64-darwin" ;;
    x86_64) target_system="x86_64-darwin" ;;
    *)
      echo "Unsupported macOS arch: $(uname -m)" >&2
      exit 1
      ;;
    esac
    ;;
  *)
    echo "Unsupported host: $(uname -s)" >&2
    exit 1
    ;;
  esac
fi

# The proof-check surface the pin workflow validates against (no more `.ci`
# aggregate). Keep in sync with jobs.validate-{linux,macos} in
# .github/workflows/pin-stable-openclaw-version.yml.
proof_checks=(
  package-artifacts
  module-render
  runtime-smoke
  platform-activation
  runtime-plugin-packages
  runtime-plugin-host
  qmd-opt-in
)

# update-pins.sh refuses to run outside CI unless GITHUB_ACTIONS is set; we are
# faithfully reusing its select/apply logic locally.
export GITHUB_ACTIONS="true"

# ---- select (pin workflow: jobs.select) --------------------------------
selection="$(scripts/update-pins.sh select)"

has_update=""
source_tag=""
source_sha=""
source_version=""
app_tag=""
app_url=""
while IFS='=' read -r key value; do
  case "$key" in
  has_update) has_update="$value" ;;
  source_tag) source_tag="$value" ;;
  source_sha) source_sha="$value" ;;
  source_version) source_version="$value" ;;
  app_tag) app_tag="$value" ;;
  app_url) app_url="$value" ;;
  esac
done <<<"$selection"

if [[ "$has_update" != "true" ]]; then
  echo "Already pinned to the latest stable release. Nothing to do." >&2
  exit 0
fi

if [[ -z "$source_tag" || -z "$source_sha" ]]; then
  echo "select did not return a complete release record:" >&2
  echo "$selection" >&2
  exit 1
fi

echo ">> Selected source $source_tag ($source_sha)${app_tag:+, app $app_tag} for $target_system" >&2

# ---- apply/materialize (pin workflow: steps[Materialize selected release]) ---
scripts/update-pins.sh apply "$source_tag" "$source_sha" "$app_tag" "$app_url"

if $skip_validate; then
  echo ">> --skip-validate: pin applied, leaving smoke test to caller." >&2
  exit 0
fi

# ---- validate (pin workflow: jobs.validate-{linux,macos}.steps[*]) -----
echo ">> Validating $target_system supported surface..." >&2
check_refs=()
for check in "${proof_checks[@]}"; do
  check_refs+=(".#checks.${target_system}.${check}")
done

case "$target_system" in
x86_64-linux | aarch64-linux)
  scripts/check-flake-lock-owners.sh
  nix build --accept-flake-config "${check_refs[@]}"
  ;;
aarch64-darwin | x86_64-darwin)
  nix build --accept-flake-config "${check_refs[@]}"
  # macOS additionally exercises real Home Manager activation.
  nix build --accept-flake-config \
    --out-link result-platform-activation \
    ".#checks.${target_system}.platform-activation"
  OPENCLAW_HM_ACTIVATION_PACKAGE="$PWD/result-platform-activation" \
    scripts/hm-activation-macos.sh
  ;;
*)
  echo "Unsupported target system: $target_system" >&2
  exit 1
  ;;
esac

echo ">> Bumped to $source_tag and validated $target_system. Working tree is dirty." >&2
echo ">> Review with: git diff --stat" >&2
echo ">> Commit and push when satisfied." >&2
