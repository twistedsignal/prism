#!/usr/bin/env bash
# Lint and run every test. Set PRISM_TEST_BLENDER to also run the Blender worker tests.
set -euo pipefail
# shellcheck source=scripts/lib.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

cd "$PROJECT_ROOT"
selene="$(find_tool selene)"
lune="$(find_tool lune)"

"$PROJECT_ROOT/scripts/write-version.bash" >/dev/null
"$selene" src
for test in tests/*.luau; do
	"$lune" run "$test"
done
python3 -m unittest discover -s tests -p 'test_*.py'
if command -v pwsh >/dev/null 2>&1; then
	pwsh -NoProfile -File tests/installers.ps1
fi
bash -n install.sh
