#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"

python3 tests/foundation/test_foundation.py
python3 docs/ai-development/validate_projection.py \
  --profile forge-platform \
  --source-commit dc58a5351b69074f445e0e81499bff816dbca738 \
  --extension-identity FORGE_PLATFORM_DEVELOPMENT_EXTENSION
git diff --check
