#!/usr/bin/env bash
# Group A: ステートレス統合テスト
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

JWT_FILE="$SCRIPT_DIR/../fixtures/jwt/valid-bearer.jwt"
BEARER_TOKEN=$(cat "$JWT_FILE")
COMPOSE_FILE="$SCRIPT_DIR/../docker-compose.test.yml"

echo "=== Group A: Stateless Integration Tests ==="

# ---------------------------------------------------------------------------
# A-01: プラグイン正常ロード
# ---------------------------------------------------------------------------
echo ""
echo "--- A-01: プラグイン正常ロード ---"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_ADMIN/status")
assert_status "Kong Admin APIが応答すること" "200" "$STATUS"

PLUGINS=$(curl -s "$KONG_ADMIN/plugins" 2>/dev/null)
OIDC_COUNT=$(echo "$PLUGINS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for p in d.get('data',[]) if p['name']=='oidc'))" 2>/dev/null || echo "0")
if [ "$OIDC_COUNT" -gt 0 ]; then
  pass "OIDCプラグインが${OIDC_COUNT}件ロードされていること"
else
  fail "OIDCプラグインが${OIDC_COUNT}件ロードされていること" "count=0"
fi

# ---------------------------------------------------------------------------
# A-02: 必須フィールド欠落で拒否
# ---------------------------------------------------------------------------
echo ""
echo "--- A-02: 必須フィールド欠落で拒否 ---"
INVALID_CONFIG=$(mktemp)
cat > "$INVALID_CONFIG" << 'YAML'
_format_version: "3.0"
services:
  - name: invalid
    host: mockserver
    port: 1080
    protocol: http
    routes:
      - name: invalid-route
        paths: ["/invalid"]
    plugins:
      - name: oidc
        config:
          discovery: http://mockserver:1080/.well-known/openid-configuration
YAML
# compose ビルドイメージを使って kong config parse を実行
PARSE_EXIT=0
RESULT=$(docker compose -f "$COMPOSE_FILE" run --rm -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/test.yml \
  -v "$INVALID_CONFIG:/test.yml:ro" \
  kong kong config parse /test.yml 2>&1) || PARSE_EXIT=$?
rm -f "$INVALID_CONFIG"

if [ "$PARSE_EXIT" -ne 0 ] && echo "$RESULT" | grep -qi "client_id\|client_secret\|required"; then
  pass "必須フィールド欠落でスキーマエラーが返されること"
else
  fail "必須フィールド欠落でスキーマエラーが返されること" "exit=$PARSE_EXIT, output may not contain expected error"
fi

# ---------------------------------------------------------------------------
# A-03: フィルタパスで認証バイパス
# ---------------------------------------------------------------------------
echo ""
echo "--- A-03: フィルタパスで認証バイパス ---"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_PROXY/test/filtered/health")
assert_status "フィルタパスが200を返すこと" "200" "$STATUS"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_PROXY/test/filtered/other")
assert_status "フィルタ対象外パスが302を返すこと" "302" "$STATUS"

# ---------------------------------------------------------------------------
# A-04: セッションなし -> 302 リダイレクト
# ---------------------------------------------------------------------------
echo ""
echo "--- A-04: セッションなし -> 302 リダイレクト ---"
RESPONSE=$(curl -s -D - -o /dev/null "$KONG_PROXY/test/standard/")
STATUS=$(echo "$RESPONSE" | head -1 | grep -oE '[0-9]{3}')
assert_status "未認証リクエストが302を返すこと" "302" "$STATUS"
assert_header_contains "Locationにauthorizeが含まれること" "$RESPONSE" "authorize"

# ---------------------------------------------------------------------------
# A-05: Bearer JWT -> ヘッダー付きプロキシ
# ---------------------------------------------------------------------------
echo ""
echo "--- A-05: Bearer JWT -> ヘッダー付きプロキシ ---"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $BEARER_TOKEN" \
  "$KONG_PROXY/test/bearer-jwt/resource")
assert_status "有効なBearer JWTで200が返されること" "200" "$STATUS"

# ---------------------------------------------------------------------------
# A-06: bearer_only + 未認証 -> 401
# ---------------------------------------------------------------------------
echo ""
echo "--- A-06: bearer_only + 未認証 -> 401 ---"
RESPONSE=$(curl -s -D - -o /dev/null "$KONG_PROXY/test/bearer-only/resource")
STATUS=$(echo "$RESPONSE" | head -1 | grep -oE '[0-9]{3}')
assert_status "bearer_only未認証で401が返されること" "401" "$STATUS"
assert_header_contains "WWW-Authenticateヘッダーが返されること" "$RESPONSE" "WWW-Authenticate"

# ---------------------------------------------------------------------------
# A-07: unauth_action=deny -> 401
# ---------------------------------------------------------------------------
echo ""
echo "--- A-07: unauth_action=deny -> 401 ---"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_PROXY/test/deny/resource")
assert_status "unauth_action=denyで401が返されること" "401" "$STATUS"

# ---------------------------------------------------------------------------
# A-08: 複数インスタンス -> 最も抑制的なログレベル
# ---------------------------------------------------------------------------
echo ""
echo "--- A-08: 複数インスタンス -> 最も抑制的なログレベル ---"
KONG_LOG_FILE=$(mktemp)
docker compose -f "$COMPOSE_FILE" logs kong > "$KONG_LOG_FILE" 2>&1
if grep -q "openidc debug log level to: ngx.WARN" "$KONG_LOG_FILE"; then
  pass "ログにngx.WARNレベル設定が記録されていること"
else
  fail "ログにngx.WARNレベル設定が記録されていること" "specific log line not found"
fi
rm -f "$KONG_LOG_FILE"

# ---------------------------------------------------------------------------
# A-09: Redis 停止 -> エラーハンドリング（最後に実行: 他テストに影響しないよう）
# ---------------------------------------------------------------------------
echo ""
echo "--- A-09: Redis 停止 -> エラーハンドリング ---"
docker compose -f "$COMPOSE_FILE" stop redis > /dev/null 2>&1
sleep 2

# standard ルート (session_storage=redis) へリクエスト
# 302 リダイレクト時にセッション Cookie 生成を試みるが Redis 不可で失敗する可能性あり
TMPFILE=$(mktemp)
curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$KONG_PROXY/test/standard/" > "$TMPFILE" 2>/dev/null || true
A09_STATUS=$(cat "$TMPFILE")
rm -f "$TMPFILE"
A09_STATUS="${A09_STATUS:-000}"
if [ "$A09_STATUS" = "302" ] || [ "$A09_STATUS" = "500" ] || [ "$A09_STATUS" = "000" ]; then
  # 000 は Kong がセッション生成のため Redis 接続を試みてタイムアウトした場合
  pass "Redis停止時にKongがクラッシュしないこと (status=$A09_STATUS)"
else
  fail "Redis停止時にKongがクラッシュしないこと" "unexpected status=$A09_STATUS"
fi

# Kong 自体は稼働中であることを確認
ADMIN_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$KONG_ADMIN/status" 2>/dev/null || echo "000")
assert_status "Redis停止時もKong Admin APIが応答すること" "200" "$ADMIN_STATUS"

# Redis を再開
docker compose -f "$COMPOSE_FILE" start redis > /dev/null 2>&1
sleep 3

# ---------------------------------------------------------------------------
# 結果報告
# ---------------------------------------------------------------------------
report
