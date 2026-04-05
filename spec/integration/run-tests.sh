#!/usr/bin/env bash
# 統合テストランナー: Docker Compose 起動 → テスト実行 → 停止
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.test.yml"

# --list: テストスクリプトからテストケース一覧を動的生成して表示
if [ "${1:-}" = "--list" ]; then
  echo "Integration Test Cases"
  echo ""
  for script in "$SCRIPT_DIR"/tests/test-group-*.sh; do
    group_name=$(head -2 "$script" | grep "^# " | sed 's/^# //')
    echo "$group_name"
    grep -E '^echo "--- [A-Z]+-[0-9]+:' "$script" | sed 's/echo "--- /  /; s/ ---"//'
    echo ""
  done
  exit 0
fi

echo "============================================"
echo "  Integration Test Runner"
echo "============================================"

# クリーンアップ trap
cleanup() {
  echo ">>> Stopping services..."
  docker compose -f "$COMPOSE_FILE" down > /dev/null 2>&1
}
trap cleanup EXIT

# サービス起動
echo ""
echo ">>> Starting services..."
docker compose -f "$COMPOSE_FILE" down > /dev/null 2>&1
docker compose -f "$COMPOSE_FILE" up -d --build 2>&1 | grep -E "Started|Created|Built|Error"

# Kong ヘルスチェック待ち
echo ""
echo ">>> Waiting for Kong to be ready..."
if ! timeout 60 bash -c "until curl -sf http://localhost:8001/status > /dev/null 2>&1; do sleep 2; done"; then
  echo "ERROR: Kong failed to start within 60 seconds"
  docker compose -f "$COMPOSE_FILE" logs kong 2>&1 | tail -20
  docker compose -f "$COMPOSE_FILE" down > /dev/null 2>&1
  exit 1
fi

# MockServer ヘルスチェック待ち
echo ">>> Waiting for MockServer to be ready..."
if ! timeout 60 bash -c "until curl -sf -X PUT http://localhost:1080/mockserver/status > /dev/null 2>&1; do sleep 3; done"; then
  echo "ERROR: MockServer failed to start within 60 seconds"
  docker compose -f "$COMPOSE_FILE" down > /dev/null 2>&1
  exit 1
fi

echo ">>> All services ready."

# テスト実行
echo ""
echo ">>> Running Group A tests..."
bash "$SCRIPT_DIR/tests/test-group-a.sh"
GROUP_A_RESULT=$?

echo ""
echo ">>> Running Group B tests..."
bash "$SCRIPT_DIR/tests/test-group-b.sh"
GROUP_B_RESULT=$?

# 結果判定（サービス停止は trap で自動実行）
echo ""
if [ "$GROUP_A_RESULT" -eq 0 ] && [ "$GROUP_B_RESULT" -eq 0 ]; then
  echo ">>> ALL INTEGRATION TESTS PASSED"
  exit 0
else
  echo ">>> SOME INTEGRATION TESTS FAILED"
  exit 1
fi
