#!/usr/bin/env bash
# E2E 検証: マルチノードセッション共有（検証項目 5）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== E2E: Multi-Node Session Sharing Verification ==="

# ---------------------------------------------------------------------------
# E2E-05: Kong 2 台構成でのセッション共有
# ---------------------------------------------------------------------------
echo ""
echo "--- E2E-05: Kong 2 台構成でのセッション共有 ---"
redis_flush

# Kong-1 (port 8000) で Auth Code フロー実行してセッション Cookie を取得
echo "  Kong-1 (port 8000) で認証フロー実行中..."
AUTH_OUTPUT=$(python3 "$AUTH_HELPER" "$KONG_PROXY_1" "/some/path/" 2>&1)
COOKIE_LINE=$(echo "$AUTH_OUTPUT" | grep -v "^INFO:" | grep -v "^ERROR:" | grep -v "^DEBUG:" | head -1)

if [ -z "$COOKIE_LINE" ]; then
  fail "Kong-1 で Auth Code フローが完了すること" "no cookie returned"
  echo "  DEBUG: auth helper output:"
  echo "$AUTH_OUTPUT" | sed 's/^/    /' >&2
  report
  exit 1
fi
pass "Kong-1 で Auth Code フローが完了しセッション Cookie を取得"

# Kong-1 で認証済みリクエスト確認（MockServer が 200 を返す設定済み）
STATUS_1=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_LINE" "$KONG_PROXY_1/some/path/resource")
assert_status "Kong-1 で認証済みリクエストが 200 を返すこと" "200" "$STATUS_1"

# Kong-2 (port 8002) に同じ Cookie で認証済みリクエスト
echo ""
echo "  Kong-2 (port 8002) に同じ Cookie でリクエスト送信中..."
STATUS_2=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_LINE" "$KONG_PROXY_2/some/path/resource")
assert_status "Kong-2 で同じ Cookie による認証済みリクエストが 200 を返すこと" "200" "$STATUS_2"

# Kong-2 Admin API でもプラグインが正常にロードされていることを確認
ADMIN_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_ADMIN_2/status")
assert_status "Kong-2 Admin API が応答すること" "200" "$ADMIN_STATUS"

# ---------------------------------------------------------------------------
# 結果報告
# ---------------------------------------------------------------------------
report
