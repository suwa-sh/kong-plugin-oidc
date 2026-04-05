#!/usr/bin/env bash
# 統合テスト共通ヘルパー関数
set -euo pipefail

KONG_PROXY="http://localhost:8000"
KONG_ADMIN="http://localhost:8001"
MOCKSERVER="http://localhost:1080"
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDIS_CLI="docker compose -f $HELPERS_DIR/../docker-compose.test.yml exec -T redis redis-cli"

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

assert_header_contains() {
  local description="$1" headers="$2" pattern="$3"
  if echo "$headers" | grep -qi "$pattern"; then
    pass "$description"
  else
    fail "$description" "pattern '$pattern' not found in headers"
  fi
}

assert_header_not_contains() {
  local description="$1" headers="$2" pattern="$3"
  if echo "$headers" | grep -qi "$pattern"; then
    fail "$description" "pattern '$pattern' found but should not be"
  else
    pass "$description"
  fi
}

assert_contains() {
  local description="$1" text="$2" pattern="$3"
  if echo "$text" | grep -q "$pattern"; then
    pass "$description"
  else
    fail "$description" "pattern '$pattern' not found"
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

report() {
  echo ""
  echo "========================================="
  echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "========================================="
  [ "$FAIL_COUNT" -eq 0 ]
}
