# Sourced by entry points after they resolve REPO_ROOT.
E2E_WORK_DIR=${E2E_WORK_DIR:-$(dirname "$REPO_ROOT")/e2e-work}
E2E_IMAGE_DIR=${E2E_IMAGE_DIR:-$E2E_WORK_DIR/images}
mkdir -p "$E2E_WORK_DIR" "$E2E_IMAGE_DIR"
E2E_WORK_DIR=$(cd "$E2E_WORK_DIR" && pwd)
E2E_IMAGE_DIR=$(cd "$E2E_IMAGE_DIR" && pwd)
