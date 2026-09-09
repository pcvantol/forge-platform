#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"

python3 tests/foundation/test_foundation.py
python3 tests/foundation/test_product_version_operations.py
python3 tests/foundation/test_release_composition_qualification.py
python3 tests/foundation/test_release_operation.py
python3 tests/foundation/test_production_release_workflow.py
python3 tests/component_operations/test_component_operations.py
python3 tests/component_operations/test_durable_component_operations.py
python3 tests/component_operations/test_ep_oi3_readback_decoder.py
python3 tests/installer/test_universal_installer.py
python3 tests/installer/test_component_combination_catalog.py
python3 tests/installer/test_installer_version_preparation.py
python3 tests/installer/test_installer_release_operation.py
python3 tests/installer/test_prepare_installer_release_candidate.py
python3 tests/installer/test_installer_release_identity.py
python3 tests/installer/test_installer_release_trust.py
python3 tests/installer/test_installer_release_provenance.py
python3 tests/installer/test_package_macos_installer_app.py
python3 tests/installer/test_package_macos_installer_archive.py
python3 tests/installer/test_verify_installer_release_evidence.py
python3 tests/installer/test_installer_release_workflow.py
python3 scripts/validate_installer_version.py
python3 scripts/validate_installer_release_identity.py
python3 scripts/advance_installer_version.py --check
python3 scripts/advance_product_version.py --check
python3 docs/ai-development/validate_projection.py \
  --profile forge-platform \
  --source-commit 6ec3b443c3ab3bdf76c626c2046d3778db570eb0 \
  --extension-identity FORGE_PLATFORM_DEVELOPMENT_EXTENSION
git diff --check
