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
export TMPDIR="$HOME/tmp"
mkdir -p "$TMPDIR"

if [ -z "${CONFIG_OPTIONS_GENERATOR:-}" ]; then
  echo "CONFIG_OPTIONS_GENERATOR is not set" >&2
  exit 1
fi
if [ ! -f "$CONFIG_OPTIONS_GENERATOR" ]; then
  echo "CONFIG_OPTIONS_GENERATOR not found: $CONFIG_OPTIONS_GENERATOR" >&2
  exit 1
fi
if [ -z "${CONFIG_OPTIONS_GOLDEN:-}" ]; then
  echo "CONFIG_OPTIONS_GOLDEN is not set" >&2
  exit 1
fi
if [ ! -f "$CONFIG_OPTIONS_GOLDEN" ]; then
  echo "CONFIG_OPTIONS_GOLDEN not found: $CONFIG_OPTIONS_GOLDEN" >&2
  exit 1
fi
if [ -z "${NODE_ENGINE_CHECK:-}" ]; then
  echo "NODE_ENGINE_CHECK is not set" >&2
  exit 1
fi
if [ ! -f "$NODE_ENGINE_CHECK" ]; then
  echo "NODE_ENGINE_CHECK not found: $NODE_ENGINE_CHECK" >&2
  exit 1
fi

cp "$CONFIG_OPTIONS_GENERATOR" ./generate-config-options.ts
cp "$NODE_ENGINE_CHECK" ./check-node-engine.ts

if ! command -v node >/dev/null 2>&1; then
  echo "node not found in PATH (run gateway-tests-build.sh first)" >&2
  exit 1
fi

tsx_cli="./node_modules/tsx/dist/cli.mjs"
if [ ! -f "$tsx_cli" ]; then
  echo "tsx CLI not found at $tsx_cli (run gateway-tests-build.sh first)" >&2
  exit 1
fi

node "$tsx_cli" ./check-node-engine.ts --repo .

output_path="./generated-config-options.nix"

node "$tsx_cli" ./generate-config-options.ts --repo . --out "$output_path"

diff -u "$CONFIG_OPTIONS_GOLDEN" "$output_path"
