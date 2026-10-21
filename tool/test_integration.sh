#!/usr/bin/env bash
# Runs the integration test suite against the local Supabase stack:
#   supabase start            (once)
#   tool/test_integration.sh  (resets the DB, applies the SQL, runs tests)
# Pass --no-reset to keep the current database. Any other argument is
# forwarded to `flutter test`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RESET=1
ARGS=()
for a in "$@"; do
    if [[ "$a" == "--no-reset" ]]; then RESET=0; else ARGS+=("$a"); fi
done

if [[ $RESET == 1 ]]; then tool/local_db.sh; fi

eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"
export CHAT_TEST_SUPABASE_URL="$API_URL"
export CHAT_TEST_ANON_KEY="$ANON_KEY"
export CHAT_TEST_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"

flutter test test/integration --tags integration --concurrency=1 "${ARGS[@]}"
