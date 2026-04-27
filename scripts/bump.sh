#!/usr/bin/env bash
# scripts/bump.sh — local openclaw source pin bump.
#
# Rewrites nix/sources/openclaw-source.nix (and optionally
# nix/packages/openclaw-app.nix), regenerates
# nix/generated/openclaw-config-options.nix, and runs a smoke build.
# Leaves the working tree dirty for review — does not commit or push.
#
# Usage:
#   scripts/bump.sh                  bump to latest stable openclaw release
#   scripts/bump.sh v2026.4.24       bump to a specific tag
#   scripts/bump.sh 2026.4.24        ('v' prefix optional)
#
# Options:
#   --dry-run            Resolve hashes, print plan, write nothing.
#   --skip-darwin-app    Skip nix/packages/openclaw-app.nix (default on Linux).
#   --no-smoke-test      Skip the final 'nix build .#checks.<system>.ci'.
#   --system <SYSTEM>    Nix system attr for TOFU + smoke test.
#                        Defaults to x86_64-linux (your deploy target).
#                        Cross-system builds dispatch via nix.buildMachines.
#   -h, --help           Show this help.
#
# Failure mode:
#   Any error after edits begin restores the three pin files to their
#   on-disk state at script start. The smoke test failure is treated as
#   an error: the bump is reverted, and you can investigate from a clean
#   slate.

set -euo pipefail

# ---- args --------------------------------------------------------------

target_tag=""
dry_run=false
skip_darwin_app=false
do_smoke_test=true
target_system="x86_64-linux"

show_help() {
  awk '/^# scripts\/bump\.sh/,/^$/ { sub(/^# ?/,""); print }' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         dry_run=true; shift ;;
    --skip-darwin-app) skip_darwin_app=true; shift ;;
    --no-smoke-test)   do_smoke_test=false; shift ;;
    --system)
      if [[ $# -lt 2 ]]; then
        printf -- '--system requires a value (e.g. x86_64-linux, aarch64-darwin)\n' >&2
        exit 2
      fi
      target_system="$2"; shift 2 ;;
    --system=*)        target_system="${1#--system=}"; shift ;;
    -h|--help)         show_help; exit 0 ;;
    -*)
      printf 'Unknown flag: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$target_tag" ]]; then
        printf 'Multiple version arguments: %s and %s\n' "$target_tag" "$1" >&2
        exit 2
      fi
      target_tag="$1"
      shift
      ;;
  esac
done

# Default to skipping the macOS app pin when not on macOS.
if [[ "$skip_darwin_app" == false && "$(uname -s)" != "Darwin" ]]; then
  skip_darwin_app=true
fi

# ---- paths and helpers -------------------------------------------------

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$repo_root/nix/sources/openclaw-source.nix"
app_file="$repo_root/nix/packages/openclaw-app.nix"
config_options_file="$repo_root/nix/generated/openclaw-config-options.nix"

# macOS resolves /tmp → /private/tmp and /var → /private/var. Newer Nix
# refuses to add a store path whose ancestry contains a symlink, which
# breaks nix-prefetch-url and `nix hash path` when TMPDIR is under /var.
# Canonicalize once so every child inherits a symlink-free TMPDIR.
export TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

if [[ -t 2 ]]; then
  C_BLUE=$'\e[1;36m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_RESET=$'\e[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { printf '%s▸%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "$1 not found in PATH"; exit 1; }
}

require_cmd git
require_cmd nix
require_cmd jq
require_cmd perl

current_field() {
  local file="$1" key="$2"
  awk -F'"' -v key="$key" '$0 ~ key" =" { print $2; exit }' "$file"
}

cd "$repo_root"

# ---- pre-flight: warn on pre-existing dirt -----------------------------

dirty=false
if ! git diff --quiet -- "$source_file" "$app_file" "$config_options_file"; then
  dirty=true
fi
if ! git diff --cached --quiet -- "$source_file" "$app_file" "$config_options_file"; then
  dirty=true
fi
if $dirty && ! $dry_run; then
  warn "Pin files already have uncommitted changes:"
  git diff --name-only        -- "$source_file" "$app_file" "$config_options_file" >&2 || true
  git diff --cached --name-only -- "$source_file" "$app_file" "$config_options_file" >&2 || true
  printf '%sContinue? Existing changes will be overwritten on rollback. (y/N) %s' "$C_YELLOW" "$C_RESET" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

current_rev=$(current_field "$source_file" "rev")
current_version=$(current_field "$app_file" "version")
log "Current pin: rev=$current_rev (version $current_version)"

# ---- resolve target tag -----------------------------------------------

app_url=""
if [[ -z "$target_tag" ]]; then
  require_cmd gh
  log "Resolving latest stable openclaw release"
  release_json=$(gh api '/repos/openclaw/openclaw/releases?per_page=20')
  selected=$(printf '%s' "$release_json" | jq -c '
    ([.[] | select(.draft|not) | select(.prerelease|not)][0]) // empty')
  if [[ -z "$selected" ]]; then
    err "No stable openclaw releases found"
    exit 1
  fi
  target_tag=$(printf '%s' "$selected" | jq -r '.tag_name')
  if ! $skip_darwin_app; then
    app_url=$(printf '%s' "$selected" | jq -r '
      [.assets[]
        | select(.name | (test("^OpenClaw-.*\\.zip$") and (test("dSYM")|not)))
        | .browser_download_url][0] // empty')
  fi
else
  [[ "$target_tag" == v* ]] || target_tag="v$target_tag"
  if ! $skip_darwin_app; then
    require_cmd gh
    app_url=$(gh api "/repos/openclaw/openclaw/releases/tags/$target_tag" 2>/dev/null \
      | jq -r '
        [.assets[]
          | select(.name | (test("^OpenClaw-.*\\.zip$") and (test("dSYM")|not)))
          | .browser_download_url][0] // empty' || true)
  fi
fi

target_version="${target_tag#v}"
log "Target: $target_tag (version $target_version)"

# Resolve tag → commit SHA, preferring the dereferenced (^{}) annotated form.
tag_refs=$(git ls-remote https://github.com/openclaw/openclaw.git \
  "refs/tags/${target_tag}" "refs/tags/${target_tag}^{}")
if [[ -z "$tag_refs" ]]; then
  err "Tag $target_tag not found on github.com/openclaw/openclaw"
  exit 1
fi
selected_sha=$(printf '%s\n' "$tag_refs" | awk '/\^\{\}$/ { print $1; exit }')
if [[ -z "$selected_sha" ]]; then
  selected_sha=$(printf '%s\n' "$tag_refs" | awk '!/\^\{\}$/ { print $1; exit }')
fi
log "Tag $target_tag → $selected_sha"

if [[ "$current_rev" == "$selected_sha" && "$current_version" == "$target_version" ]]; then
  log "Already pinned to $target_tag. Nothing to do."
  exit 0
fi

# ---- prefetch source --------------------------------------------------

log "Prefetching openclaw source tarball"
source_url="https://github.com/openclaw/openclaw/archive/${selected_sha}.tar.gz"
source_prefetch=$(nix --extra-experimental-features 'nix-command flakes' \
  store prefetch-file --unpack --json "$source_url")
source_hash=$(printf '%s' "$source_prefetch" | jq -r '.hash // empty')
source_store_path=$(printf '%s' "$source_prefetch" | jq -r '.path // .storePath // empty')
if [[ -z "$source_hash" || -z "$source_store_path" ]]; then
  err "Source prefetch did not return hash/path"
  exit 1
fi
log "Source hash: $source_hash"

# ---- resolve macOS app hash (optional) --------------------------------

app_hash=""
if ! $skip_darwin_app; then
  if [[ -z "$app_url" ]]; then
    warn "No macOS .zip asset found on $target_tag — leaving openclaw-app.nix untouched."
    skip_darwin_app=true
  else
    require_cmd nix-prefetch-url
    require_cmd unzip
    log "Prefetching macOS app: $app_url"
    archive_path=$(nix-prefetch-url "$app_url" --print-path | tail -n1)
    if [[ ! -e "$archive_path" ]]; then
      err "nix-prefetch-url did not return a valid path"
      exit 1
    fi
    unpack_dir=$(mktemp -d)
    unzip -q "$archive_path" -d "$unpack_dir"
    app_hash=$(nix hash path "$unpack_dir")
    rm -rf "$unpack_dir"
    log "App hash: $app_hash"
  fi
fi

# ---- dry-run exit -----------------------------------------------------

if $dry_run; then
  cat >&2 <<EOF

== Dry run plan ==
target tag:     $target_tag
target version: $target_version
target sha:     $selected_sha
target system:  $target_system
source hash:    $source_hash
EOF
  if ! $skip_darwin_app; then
    cat >&2 <<EOF
app url:        $app_url
app hash:       $app_hash
EOF
  fi
  printf '\n(no files written)\n' >&2
  exit 0
fi

# ---- backup + rollback trap -------------------------------------------

backup_dir=""
success=0

cleanup() {
  local rc=$?
  if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
    if [[ "$success" -ne 1 ]]; then
      err "Failed (rc=$rc) — restoring previous pin files"
      cp "$backup_dir/source.nix"        "$source_file"          2>/dev/null || true
      cp "$backup_dir/app.nix"           "$app_file"             2>/dev/null || true
      cp "$backup_dir/config-options.nix" "$config_options_file" 2>/dev/null || true
    fi
    rm -rf "$backup_dir"
  fi
  exit "$rc"
}
trap cleanup EXIT

backup_dir=$(mktemp -d)
cp "$source_file"          "$backup_dir/source.nix"
cp "$app_file"             "$backup_dir/app.nix"
cp "$config_options_file"  "$backup_dir/config-options.nix"

# ---- apply pin edits --------------------------------------------------

log "Updating $source_file"
perl -0pi -e "s|rev = \"[^\"]+\";|rev = \"${selected_sha}\";|" "$source_file"
perl -0pi -e "s|hash = \"[^\"]+\";|hash = \"${source_hash}\";|" "$source_file"
perl -0pi -e 's|pnpmDepsHash = "[^"]*";|pnpmDepsHash = "";|'    "$source_file"

if ! $skip_darwin_app; then
  log "Updating $app_file"
  perl -0pi -e "s|version = \"[^\"]+\";|version = \"${target_version}\";|" "$app_file"
  perl -0pi -e "s|url = \"[^\"]+\";|url = \"${app_url}\";|"                "$app_file"
  perl -0pi -e "s|hash = \"[^\"]+\";|hash = \"${app_hash}\";|"             "$app_file"
fi

# ---- TOFU pnpmDepsHash ------------------------------------------------

gateway_attr=".#packages.${target_system}.openclaw-gateway"

log "Building $gateway_attr to discover pnpmDepsHash (TOFU)"
build_log=$(mktemp)
if nix build "$gateway_attr" --accept-flake-config --no-link >"$build_log" 2>&1; then
  warn "Build succeeded with empty pnpmDepsHash — that should have failed."
  warn "Inspect $source_file before continuing."
else
  pnpm_hash=$(grep -Eo 'got: *sha256-[A-Za-z0-9+/=]+' "$build_log" | head -n1 | sed 's/.*got: *//' || true)
  if [[ -z "$pnpm_hash" ]]; then
    err "Could not extract pnpmDepsHash from build log; tail follows:"
    tail -n 80 "$build_log" >&2
    rm -f "$build_log"
    exit 1
  fi
  log "pnpmDepsHash: $pnpm_hash"
  perl -0pi -e "s|pnpmDepsHash = \"[^\"]*\";|pnpmDepsHash = \"${pnpm_hash}\";|" "$source_file"

  log "Re-building $gateway_attr to confirm pnpmDepsHash"
  if ! nix build "$gateway_attr" --accept-flake-config --no-link >"$build_log" 2>&1; then
    err "Gateway build still failing after pnpmDepsHash update; tail follows:"
    tail -n 200 "$build_log" >&2
    rm -f "$build_log"
    exit 1
  fi
fi
rm -f "$build_log"

# ---- regenerate config-options ----------------------------------------

log "Regenerating $config_options_file"
tmp_src=$(mktemp -d)
cleanup_tmp_src() { rm -rf "$tmp_src"; }
if [[ -d "$source_store_path" ]]; then
  cp -R "$source_store_path/." "$tmp_src/src"
elif [[ -f "$source_store_path" ]]; then
  mkdir -p "$tmp_src/src"
  tar -xf "$source_store_path" -C "$tmp_src/src" --strip-components=1
else
  err "Source store path missing: $source_store_path"
  exit 1
fi
chmod -R u+w "$tmp_src/src"

if ! nix shell --extra-experimental-features 'nix-command flakes' \
    nixpkgs#nodejs_22 nixpkgs#pnpm_10 -c bash -c "
      set -euo pipefail
      cd '$tmp_src/src'
      pnpm install --frozen-lockfile --ignore-scripts >/dev/null
      OPENCLAW_SCHEMA_REV='$selected_sha' pnpm exec tsx \
        '$repo_root/nix/scripts/generate-config-options.ts' \
        --repo . \
        --out '$config_options_file'
"; then
  cleanup_tmp_src
  err "Config-options regeneration failed"
  exit 1
fi
cleanup_tmp_src

# ---- smoke test -------------------------------------------------------

if $do_smoke_test; then
  log "Smoke test: nix build .#checks.${target_system}.ci"
  if ! nix build ".#checks.${target_system}.ci" --accept-flake-config --no-link; then
    err "Smoke test failed for $target_tag on $target_system — rolling back."
    err "If this is a real upstream regression, retry with --no-smoke-test"
    err "to keep the bumped pin and investigate from there."
    exit 1
  fi
fi

success=1

# ---- summary ----------------------------------------------------------

cat >&2 <<EOF

${C_BLUE}Done.${C_RESET} Bumped openclaw to $target_tag ($selected_sha).

Files changed:
$(git diff --stat -- "$source_file" "$app_file" "$config_options_file")

Review:
  git diff -- nix/sources/openclaw-source.nix
  git diff -- nix/generated/openclaw-config-options.nix$(! $skip_darwin_app && printf '\n  git diff -- nix/packages/openclaw-app.nix')

Commit when satisfied:
  git checkout -b bump-openclaw-${target_version}
  git add nix/sources/openclaw-source.nix nix/generated/openclaw-config-options.nix$(! $skip_darwin_app && printf ' nix/packages/openclaw-app.nix')
  git commit -m "bump openclaw to $target_tag"
EOF
