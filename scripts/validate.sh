#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"

python3 tests/foundation/test_foundation.py
python3 docs/ai-development/validate_projection.py \
  --profile forge-platform \
  --source-commit 4a39841a0c85b0e9962c85a74a3fd49d9803c13d \
  --extension-identity FORGE_PLATFORM_DEVELOPMENT_EXTENSION
git diff --check
