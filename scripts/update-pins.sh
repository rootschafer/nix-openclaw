#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "This script is intended to run in GitHub Actions (see .github/workflows/yolo-update.yml). Refusing to run locally." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$repo_root/nix/sources/openclaw-source.nix"
app_file="$repo_root/nix/packages/openclaw-app.nix"
config_options_file="$repo_root/nix/generated/openclaw-config-options.nix"

log() {
  printf '>> %s\n' "$*" >&2
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/update-pins.sh select
  scripts/update-pins.sh apply <release_tag> <release_sha> <app_url>
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required but not installed." >&2
    exit 1
  fi
}

current_field() {
  local file="$1"
  local key="$2"
  awk -F'"' -v key="$key" '$0 ~ key" =" { print $2; exit }' "$file"
}

resolve_release_tag_sha() {
  local tag="$1"
  local tag_refs
  tag_refs=$(git ls-remote https://github.com/openclaw/openclaw.git "refs/tags/${tag}" "refs/tags/${tag}^{}" || true)
  if [[ -z "$tag_refs" ]]; then
    echo ""
    return 0
  fi

  local deref_sha plain_sha
  deref_sha=$(printf '%s\n' "$tag_refs" | awk '/\^\{\}$/ { print $1; exit }')
  if [[ -n "$deref_sha" ]]; then
    printf '%s\n' "$deref_sha"
    return 0
  fi

  plain_sha=$(printf '%s\n' "$tag_refs" | awk '!/\^\{\}$/ { print $1; exit }')
  printf '%s\n' "$plain_sha"
}

prefetch_json() {
  local url="$1"
  nix --extra-experimental-features "nix-command flakes" store prefetch-file --unpack --json "$url"
}

refresh_pnpm_hash() {
  local build_log pnpm_hash
  build_log=$(mktemp)
  if ! nix build .#openclaw-gateway --accept-flake-config >"$build_log" 2>&1; then
    pnpm_hash=$(grep -Eo 'got: *sha256-[A-Za-z0-9+/=]+' "$build_log" | head -n 1 | sed 's/.*got: *//' || true)
    if [[ -z "$pnpm_hash" ]]; then
      tail -n 200 "$build_log" >&2 || true
      rm -f "$build_log"
      return 1
    fi
    log "pnpmDepsHash mismatch detected: $pnpm_hash"
    perl -0pi -e "s|pnpmDepsHash = \"[^\"]*\";|pnpmDepsHash = \"${pnpm_hash}\";|" "$source_file"
    nix build .#openclaw-gateway --accept-flake-config >"$build_log" 2>&1 || {
      tail -n 200 "$build_log" >&2 || true
      rm -f "$build_log"
      return 1
    }
  fi
  rm -f "$build_log"
}

regenerate_config_options() {
  local selected_sha="$1"
  local source_store_path="$2"
  local tmp_src
  tmp_src=$(mktemp -d)

  if [[ -d "$source_store_path" ]]; then
    cp -R "$source_store_path" "$tmp_src/src"
  elif [[ -f "$source_store_path" ]]; then
    mkdir -p "$tmp_src/src"
    tar -xf "$source_store_path" -C "$tmp_src/src" --strip-components=1
  else
    echo "Source path not found: $source_store_path" >&2
    rm -rf "$tmp_src"
    exit 1
  fi

  chmod -R u+w "$tmp_src/src"

  nix shell --extra-experimental-features "nix-command flakes" nixpkgs#nodejs_22 nixpkgs#pnpm_10 -c \
    bash -c "cd '$tmp_src/src' && pnpm install --frozen-lockfile --ignore-scripts"

  nix shell --extra-experimental-features "nix-command flakes" nixpkgs#nodejs_22 nixpkgs#pnpm_10 -c \
    bash -c "cd '$tmp_src/src' && OPENCLAW_SCHEMA_REV='${selected_sha}' pnpm exec tsx '$repo_root/nix/scripts/generate-config-options.ts' --repo . --out '$config_options_file'"

  rm -rf "$tmp_src"
}

latest_stable_release() {
  local release_json="$1"
  printf '%s' "$release_json" | jq -c '
    ([.[] | select(.draft | not) | select(.prerelease | not)][0]) // empty
  '
}

select_release() {
  local release_json current_rev current_version selected_release release_tag app_url release_version selected_sha
  current_rev=$(current_field "$source_file" "rev")
  current_version=$(current_field "$app_file" "version")

  log "Fetching latest stable OpenClaw release metadata"
  release_json=$(gh api '/repos/openclaw/openclaw/releases?per_page=20')
  selected_release=$(latest_stable_release "$release_json")

  if [[ -z "$selected_release" ]]; then
    echo "Failed to resolve latest stable OpenClaw release" >&2
    exit 1
  fi

  release_tag=$(printf '%s' "$selected_release" | jq -r '.tag_name // empty')
  if [[ -z "$release_tag" ]]; then
    echo "Latest stable OpenClaw release is missing tag_name" >&2
    exit 1
  fi

  app_url=$(printf '%s' "$selected_release" | jq -r '
    [.assets[]
      | select(.name | (test("^OpenClaw-.*\\.zip$") and (test("dSYM") | not)))
      | .browser_download_url][0] // empty
  ')
  if [[ -z "$app_url" ]]; then
    echo "Latest stable OpenClaw release ${release_tag} is missing the required macOS zip asset" >&2
    exit 1
  fi

  selected_sha=$(resolve_release_tag_sha "$release_tag")
  if [[ -z "$selected_sha" ]]; then
    echo "Failed to resolve tag SHA for $release_tag" >&2
    exit 1
  fi

  release_version="${release_tag#v}"
  log "Selected stable release: $release_tag ($selected_sha)"
  if [[ "$current_version" == "$release_version" && "$current_rev" == "$selected_sha" ]]; then
    exit 0
  fi

  printf 'release_tag=%s\n' "$release_tag"
  printf 'release_sha=%s\n' "$selected_sha"
  printf 'app_url=%s\n' "$app_url"
  printf 'release_version=%s\n' "$release_version"
}

apply_release() {
  local release_tag="$1"
  local selected_sha="$2"
  local app_url="$3"
  local release_version source_url source_prefetch source_hash source_store_path app_prefetch app_hash
  local backup_dir success

  release_version="${release_tag#v}"
  source_url="https://github.com/openclaw/openclaw/archive/${selected_sha}.tar.gz"

  source_prefetch=$(prefetch_json "$source_url")
  source_hash=$(printf '%s' "$source_prefetch" | jq -r '.hash // empty')
  source_store_path=$(printf '%s' "$source_prefetch" | jq -r '.path // .storePath // empty')
  if [[ -z "$source_hash" || -z "$source_store_path" ]]; then
    echo "Failed to resolve source hash/path for $selected_sha" >&2
    exit 1
  fi

  app_prefetch=$(prefetch_json "$app_url")
  app_hash=$(printf '%s' "$app_prefetch" | jq -r '.hash // empty')
  if [[ -z "$app_hash" ]]; then
    echo "Failed to resolve app hash for $release_tag" >&2
    exit 1
  fi

  backup_dir=$(mktemp -d)
  success=0
  cp "$source_file" "$backup_dir/source.nix"
  cp "$app_file" "$backup_dir/app.nix"
  cp "$config_options_file" "$backup_dir/config-options.nix"

  cleanup_apply() {
    if [[ "$success" -ne 1 ]]; then
      cp "$backup_dir/source.nix" "$source_file"
      cp "$backup_dir/app.nix" "$app_file"
      cp "$backup_dir/config-options.nix" "$config_options_file"
    fi
    rm -rf "$backup_dir"
  }
  trap cleanup_apply RETURN

  perl -0pi -e "s|rev = \"[^\"]+\";|rev = \"${selected_sha}\";|" "$source_file"
  perl -0pi -e "s|hash = \"[^\"]+\";|hash = \"${source_hash}\";|" "$source_file"
  perl -0pi -e 's|pnpmDepsHash = "[^"]*";|pnpmDepsHash = "";|' "$source_file"

  perl -0pi -e "s|version = \"[^\"]+\";|version = \"${release_version}\";|" "$app_file"
  perl -0pi -e "s|url = \"[^\"]+\";|url = \"${app_url}\";|" "$app_file"
  perl -0pi -e "s|hash = \"[^\"]+\";|hash = \"${app_hash}\";|" "$app_file"

  refresh_pnpm_hash
  regenerate_config_options "$selected_sha" "$source_store_path"

  success=1
}

mode="${1:-}"
case "$mode" in
  select)
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi
    require_cmd jq
    require_cmd gh
    select_release
    ;;
  apply)
    if [[ $# -ne 4 ]]; then
      usage
      exit 1
    fi
    require_cmd jq
    require_cmd gh
    require_cmd nix
    require_cmd perl
    apply_release "$2" "$3" "$4"
    ;;
  *)
    usage
    exit 1
    ;;
esac
