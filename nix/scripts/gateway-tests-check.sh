#!/bin/sh
set -e

store_path_file="${PNPM_STORE_PATH_FILE:-.pnpm-store-path}"
if [ -f "$store_path_file" ]; then
  store_path="$(cat "$store_path_file")"
  export PNPM_STORE_DIR="$store_path"
  export PNPM_STORE_PATH="$store_path"
  export NPM_CONFIG_STORE_DIR="$store_path"
  export NPM_CONFIG_STORE_PATH="$store_path"
fi
export HOME="$(mktemp -d)"
export TMPDIR="${HOME}/tmp"
mkdir -p "$TMPDIR"
export OPENCLAW_LOG_DIR="${TMPDIR}/openclaw-logs"
mkdir -p "$OPENCLAW_LOG_DIR"
mkdir -p /tmp/openclaw || true
chmod 700 /tmp/openclaw || true
unset OPENCLAW_BUNDLED_PLUGINS_DIR
export VITEST_POOL="forks"
export VITEST_MIN_WORKERS="2"
export VITEST_MAX_WORKERS="2"

PATH="$PWD/node_modules/.bin:$PATH"

vitest_config="vitest.gateway.config.ts"
if [ ! -f "$vitest_config" ] && [ -f "test/vitest/vitest.gateway.config.ts" ]; then
  vitest_config="test/vitest/vitest.gateway.config.ts"
fi

vitest_cli="$PWD/node_modules/vitest/vitest.mjs"
if [ ! -f "$vitest_cli" ]; then
  vitest_cli="$(find "$PWD/node_modules" -path '*/vitest/vitest.mjs' -type f | head -n 1)"
fi

if [ -z "${vitest_cli:-}" ] || [ ! -f "$vitest_cli" ]; then
  echo "vitest CLI not found under $PWD/node_modules" >&2
  exit 1
fi

# Bound every hook and test individually so a hung suite can't stall the whole run.
exec node "$vitest_cli" run \
  --config "$vitest_config" \
  --testTimeout=20000 \
  --hookTimeout=60000 \
  --teardownTimeout=20000
