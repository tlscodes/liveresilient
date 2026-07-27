#!/bin/bash
# Replaces metaphor-flavoured identifiers with names that state what the
# code actually does. Longest names first so a shorter prefix does not
# eat a longer identifier.
set -euo pipefail
cd "$(dirname "$0")/.."

git mv packages/call_core/lib/src/survival_ladder.dart \
       packages/call_core/lib/src/operating_ladder.dart
git mv packages/call_core/test/survival_ladder_test.dart \
       packages/call_core/test/operating_ladder_test.dart
git mv apps/reference_app/lib/src/survival_mode_driver.dart \
       apps/reference_app/lib/src/degraded_mode_driver.dart
git mv apps/reference_app/test/survival_mode_driver_test.dart \
       apps/reference_app/test/degraded_mode_driver_test.dart
git mv apps/reference_app/test/call_session_survival_store_test.dart \
       apps/reference_app/test/call_session_store_and_forward_test.dart
git mv packages/connection_orchestrator/lib/src/trend_sentinel.dart \
       packages/connection_orchestrator/lib/src/trend_monitor.dart
git mv packages/connection_orchestrator/test/trend_sentinel_test.dart \
       packages/connection_orchestrator/test/trend_monitor_test.dart 2>/dev/null || true
git mv packages/connection_orchestrator/test/doomsday_audit_test.dart \
       packages/connection_orchestrator/test/silent_corruption_audit_test.dart

files=$(find . -name '*.dart' -not -path '*/.dart_tool/*' -not -path './.backups/*')

apply() {
  # shellcheck disable=SC2086
  perl -pi -e "s/\\b$1\\b/$2/g" $files
}

apply 'survivalMessengerFactory' 'storeAndForwardMessengerFactory'
apply '_defaultSurvivalStorageDir' '_defaultStoreAndForwardDir'
apply 'survivalFallbackQueue' 'dtnFallbackQueue'
apply 'survivalMessenger' 'storeAndForwardMessenger'
apply 'survivalRungMinBps' 'operatingRungMinBps'
apply 'SurvivalModeDriver' 'DegradedModeDriver'
apply 'survivalDriver' 'degradedModeDriver'
apply 'SurvivalLadder' 'OperatingLadder'
apply 'SurvivalRung' 'OperatingRung'
apply 'TrendSentinel' 'TrendMonitor'

# Import paths and part directives that name the moved files.
apply 'survival_ladder' 'operating_ladder'
apply 'survival_mode_driver' 'degraded_mode_driver'
apply 'trend_sentinel' 'trend_monitor'

echo "rename pass complete"
