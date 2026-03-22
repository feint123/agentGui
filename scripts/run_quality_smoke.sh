#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="agentGui.xcodeproj"
SCHEME="agentGui"
DESTINATION="platform=macOS"
MODE="${1:-all}"

run_unit_and_integration() {
  echo "==> Running focused unit and integration gates"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" test \
    -only-testing:agentGuiTests/QualityFixtureBuilderTests \
    -only-testing:agentGuiTests/ReleaseScenarioTests
}

run_ui_smoke() {
  echo "==> Running focused UI smoke gates"
}

case "$MODE" in
  unit)
    run_unit_and_integration
    ;;
  ui)
    run_ui_smoke
    ;;
  all)
    run_unit_and_integration
    run_ui_smoke
    ;;
  *)
    echo "Usage: ./scripts/run_quality_smoke.sh [all|unit|ui]" >&2
    exit 1
    ;;
esac

echo "==> Quality smoke suite completed"