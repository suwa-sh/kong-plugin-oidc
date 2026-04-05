#!/usr/bin/env bash
# E2E テストランナー: Docker Compose 起動 → Keycloak セットアップ → テスト実行 → 停止
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.e2e.yml"

# --list: テストケース一覧を表示
if [ "${1:-}" = "--list" ]; then
  echo "E2E Test Cases"
  echo ""
  for script in "$SCRIPT_DIR"/tests/verify-*.sh; do
    group_name=$(head -2 "$script" | grep "^# " | sed 's/^# //')
    echo "$group_name"
    grep -E '^echo "--- E2E-[0-9]+:' "$script" | sed 's/echo "--- /  /; s/ ---"//'
    echo ""
  done
  exit 0
fi

echo "============================================"
echo "  E2E Test Runner"
echo "============================================"

# クリーンアップ trap
cleanup() {
  echo ""
  echo ">>> Stopping services..."
  docker compose -f "$COMPOSE_FILE" down > /dev/null 2>&1
}
trap cleanup EXIT

# サービス起動
echo ""
echo ">>> Starting services..."
docker compose -f "$COMPOSE_FILE" down > /dev/null 2>&1
docker compose -f "$COMPOSE_FILE" up -d --build 2>&1 | grep -E "Started|Created|Built|Error"

# Kong-1 ヘルスチェック待ち
echo ""
echo ">>> Waiting for Kong-1 to be ready..."
if ! timeout 120 bash -c "until curl -sf http://localhost:8001/status > /dev/null 2>&1; do sleep 2; done"; then
  echo "ERROR: Kong-1 failed to start within 120 seconds"
  docker compose -f "$COMPOSE_FILE" logs kong-1 2>&1 | tail -30
  exit 1
fi

# Kong-2 ヘルスチェック待ち
echo ">>> Waiting for Kong-2 to be ready..."
if ! timeout 120 bash -c "until curl -sf http://localhost:8003/status > /dev/null 2>&1; do sleep 2; done"; then
  echo "ERROR: Kong-2 failed to start within 120 seconds"
  docker compose -f "$COMPOSE_FILE" logs kong-2 2>&1 | tail -30
  exit 1
fi

# Keycloak ヘルスチェック（docker compose healthcheck とは別に再確認）
echo ">>> Waiting for Keycloak to be ready..."
if ! timeout 120 bash -c "until curl -sf http://localhost:8080/health/ready > /dev/null 2>&1; do sleep 3; done"; then
  echo "ERROR: Keycloak failed to start within 120 seconds"
  docker compose -f "$COMPOSE_FILE" logs keycloak 2>&1 | tail -30
  exit 1
fi

echo ">>> All services ready."

# Keycloak セットアップ（sslRequired=NONE を設定してから OIDC discovery を使用可能にする）
echo ""
echo ">>> Running Keycloak setup..."
bash "$SCRIPT_DIR/keycloak-setup.sh"
SETUP_RESULT=$?
if [ "$SETUP_RESULT" -ne 0 ]; then
  echo "ERROR: Keycloak setup failed"
  exit 1
fi

# Keycloak OIDC discovery 疎通確認（セットアップ後に確認）
echo ""
echo ">>> Verifying Keycloak OIDC discovery..."
if ! timeout 30 bash -c "until curl -sf http://localhost:8080/realms/master/.well-known/openid-configuration > /dev/null 2>&1; do sleep 2; done"; then
  echo "ERROR: Keycloak OIDC discovery endpoint not responding"
  docker compose -f "$COMPOSE_FILE" logs keycloak 2>&1 | tail -20
  exit 1
fi

# MockServer に upstream expectation を設定（任意パスに 200 を返す）
echo ""
echo ">>> Setting up MockServer expectations..."
curl -sf -X PUT http://localhost:1080/mockserver/expectation \
  -H "Content-Type: application/json" \
  -d '{"httpRequest":{"method":"GET"},"httpResponse":{"statusCode":200,"body":"{\"status\":\"ok\"}"}}' > /dev/null 2>&1

# テスト実行
echo ""
echo ">>> Running Redis session verification..."
bash "$SCRIPT_DIR/tests/verify-redis-session.sh"
REDIS_RESULT=$?

echo ""
echo ">>> Running multi-node verification..."
bash "$SCRIPT_DIR/tests/verify-multi-node.sh"
MULTI_RESULT=$?

# 結果判定（サービス停止は trap で自動実行）
echo ""
if [ "$REDIS_RESULT" -eq 0 ] && [ "$MULTI_RESULT" -eq 0 ]; then
  echo ">>> ALL E2E TESTS PASSED"
  exit 0
else
  echo ">>> SOME E2E TESTS FAILED"
  exit 1
fi
