#!/usr/bin/env bash
# Usage: ./create-scratch-org.sh <alias> [dev-hub-alias]
set -euo pipefail

alias_name="${1:?usage: $0 <alias> [dev-hub-alias]}"
dev_hub="${2:-}"

cd "$(dirname "$0")"

args=(org create scratch
      --definition-file config/project-scratch-def.json
      --alias "$alias_name"
      --duration-days 30
      --wait 10)
if [[ -n "$dev_hub" ]]; then
  args+=(--target-dev-hub "$dev_hub")
fi

sf "${args[@]}"
