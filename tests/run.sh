#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"
. "$REPO_ROOT/tools/lib/isotovideo.sh"
for script in run.sh tools/*.sh tools/lib/*.sh tools/host/*.sh assets/*.sh tests/*.sh; do
    bash -n "$script"
done
python3 -m unittest discover -s tests -v
resolve_isotovideo
docker run --rm -v "$REPO_ROOT:/repo:ro" -v "$REPO_ROOT/assets:/tests/assets:ro" \
    -w /repo --entrypoint bash "$ISOTOVIDEO_IMAGE" -c '
    set -e
    for module in casedir/main.pm casedir/tests/*.pm diag/*/main.pm diag/*/tests/*.pm; do
        perl -I /usr/lib/os-autoinst -I /repo/casedir/tests -c "$module"
    done
    perl tests/guest.t
    '
