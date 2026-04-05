#!/usr/bin/env bash
# E2E テスト共通ヘルパー関数
set -euo pipefail

KONG_PROXY_1="http://localhost:8000"
KONG_PROXY_2="http://localhost:8002"
KONG_ADMIN_1="http://localhost:8001"
KONG_ADMIN_2="http://localhost:8003"
KEYCLOAK_URL="http://localhost:8080"
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$HELPERS_DIR/../docker-compose.e2e.yml"
REDIS_CLI="docker compose -f $COMPOSE_FILE exec -T redis redis-cli"
AUTH_HELPER="$HELPERS_DIR/auth-code-helper-keycloak.py"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  local description="$1"
  echo "  PASS: $description"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local description="$1"
  shift
  echo "  FAIL: $description ($*)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_status() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$description"
  else
    fail "$description" "expected=$expected, actual=$actual"
  fi
}

assert_less_than() {
  local description="$1" actual="$2" limit="$3"
  if [ "$actual" -lt "$limit" ]; then
    pass "$description"
  else
    fail "$description" "actual=$actual >= limit=$limit"
  fi
}

assert_greater_than() {
  local description="$1" actual="$2" limit="$3"
  if [ "$actual" -gt "$limit" ]; then
    pass "$description"
  else
    fail "$description" "actual=$actual <= limit=$limit"
  fi
}

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$description"
  else
    fail "$description" "expected=$expected, actual=$actual"
  fi
}

assert_redis_has_keys() {
  local description="$1"
  local key_count
  key_count=$($REDIS_CLI DBSIZE 2>/dev/null | grep -oE '[0-9]+')
  if [ "${key_count:-0}" -gt 0 ]; then
    pass "$description"
  else
    fail "$description" "Redis has no keys"
  fi
}

redis_flush() {
  $REDIS_CLI FLUSHALL > /dev/null 2>&1
}

redis_dbsize() {
  $REDIS_CLI DBSIZE 2>/dev/null | grep -oE '[0-9]+'
}

report() {
  echo ""
  echo "========================================="
  echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "========================================="
  [ "$FAIL_COUNT" -eq 0 ]
}
