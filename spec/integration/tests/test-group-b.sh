#!/usr/bin/env bash
# Group B: Auth Code フロー完了テスト
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

AUTH_HELPER="$SCRIPT_DIR/auth-code-helper.py"
COMPOSE_FILE="$SCRIPT_DIR/../docker-compose.test.yml"

echo "=== Group B: Auth Code Flow Integration Tests ==="

# ---------------------------------------------------------------------------
# B-01: Redis セッション保存
# ---------------------------------------------------------------------------
echo ""
echo "--- B-01: Redis セッション保存 ---"
# Redis をフラッシュしてからテスト
redis_flush

# Auth Code フロー実行
AUTH_OUTPUT=$(python3 "$AUTH_HELPER" "$KONG_PROXY" "/test/standard/" 2>&1)
COOKIE_LINE=$(echo "$AUTH_OUTPUT" | grep -v "^INFO:" | grep -v "^ERROR:" | head -1)
INFO_LINE=$(echo "$AUTH_OUTPUT" | grep "^INFO:" | head -1)

if [ -n "$COOKIE_LINE" ]; then
  pass "Auth Code フローが完了しセッション Cookie が発行されたこと"
else
  fail "Auth Code フローが完了しセッション Cookie が発行されたこと" "no cookie returned"
fi

# Redis にセッションキーが存在することを確認
assert_redis_has_keys "Redis にセッションデータが保存されていること"

# ---------------------------------------------------------------------------
# B-02: Cookie サイズ（session ID のみ）
# ---------------------------------------------------------------------------
echo ""
echo "--- B-02: Cookie サイズ ---"
COOKIE_SIZE=$(echo "$INFO_LINE" | grep -oE 'total_size=[0-9]+' | grep -oE '[0-9]+')
COOKIE_SIZE="${COOKIE_SIZE:-9999}"
assert_less_than "Cookie サイズが200バイト未満であること" "$COOKIE_SIZE" 200

# ---------------------------------------------------------------------------
# B-03: ヘッダー注入（X-Access-Token, X-ID-Token）
# ---------------------------------------------------------------------------
echo ""
echo "--- B-03: ヘッダー注入 ---"
# セッション Cookie を使って認証済みリクエストを送信
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_LINE" "$KONG_PROXY/test/standard/resource")
assert_status "認証済みリクエストが200を返すこと" "200" "$STATUS"

# MockServer に記録されたリクエストを取得
sleep 1
RECORDED=$(curl -s -X PUT "$MOCKSERVER/mockserver/retrieve?type=REQUESTS" \
  -H "Content-Type: application/json" \
  -d '{"path":"/test/standard/resource"}' 2>/dev/null)

# session_contents.user = false のため X-USERINFO は注入されない（仕様通り）
if echo "$RECORDED" | grep -qi "x-userinfo\|X-USERINFO"; then
  fail "X-USERINFO は session_contents.user=false のため注入されないこと" "header was injected unexpectedly"
else
  pass "X-USERINFO は session_contents.user=false のため注入されないこと"
fi

if echo "$RECORDED" | grep -qi "x-access-token\|X-Access-Token"; then
  pass "X-Access-Token ヘッダーが upstream に注入されていること"
else
  fail "X-Access-Token ヘッダーが upstream に注入されていること" "header not found"
fi

if echo "$RECORDED" | grep -qi "x-id-token\|X-ID-Token"; then
  pass "X-ID-Token ヘッダーが upstream に注入されていること"
else
  fail "X-ID-Token ヘッダーが upstream に注入されていること" "header not found"
fi

# ---------------------------------------------------------------------------
# B-04: カスタムヘッダーマッピング
# ---------------------------------------------------------------------------
echo ""
echo "--- B-04: カスタムヘッダーマッピング ---"
# custom-headers ルートは bearer_jwt_auth_enable=yes + header_names/claims 設定
JWT_FILE="$SCRIPT_DIR/../fixtures/jwt/valid-bearer.jwt"
BEARER_TOKEN=$(cat "$JWT_FILE")

STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $BEARER_TOKEN" \
  "$KONG_PROXY/test/custom-headers/resource")
assert_status "カスタムヘッダールートが200を返すこと" "200" "$STATUS"

sleep 1
RECORDED=$(curl -s -X PUT "$MOCKSERVER/mockserver/retrieve?type=REQUESTS" \
  -H "Content-Type: application/json" \
  -d '{"path":"/test/custom-headers/resource"}' 2>/dev/null)

if echo "$RECORDED" | grep -qi "x-user-email\|X-User-Email"; then
  pass "X-User-Email カスタムヘッダーが注入されていること"
else
  fail "X-User-Email カスタムヘッダーが注入されていること" "header not found"
fi

if echo "$RECORDED" | grep -qi "x-user-name\|X-User-Name"; then
  pass "X-User-Name カスタムヘッダーが注入されていること"
else
  fail "X-User-Name カスタムヘッダーが注入されていること" "header not found"
fi

# ネストクレーム (realm_access.roles) のドット区切り解決を検証
if echo "$RECORDED" | grep -qi "x-user-roles.*admin.*user"; then
  pass "X-User-Roles ネストクレームヘッダーが注入されていること"
else
  fail "X-User-Roles ネストクレームヘッダーが注入されていること" "header not found or roles missing"
fi

# ---------------------------------------------------------------------------
# B-05: Cookie 改ざん -> 再認証
# ---------------------------------------------------------------------------
echo ""
echo "--- B-05: Cookie 改ざん -> 再認証 ---"
TAMPERED_COOKIE=$(echo "$COOKIE_LINE" | sed 's/=.*$/=TAMPERED_VALUE/')
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -b "$TAMPERED_COOKIE" "$KONG_PROXY/test/standard/resource")
if [ "$STATUS" = "302" ] || [ "$STATUS" = "401" ]; then
  pass "改ざん Cookie で再認証が発生すること (status=$STATUS)"
else
  fail "改ざん Cookie で再認証が発生すること" "expected 302 or 401, got=$STATUS"
fi

# ---------------------------------------------------------------------------
# B-06: skip_already_auth
# ---------------------------------------------------------------------------
echo ""
echo "--- B-06: skip_already_auth ---"
# 制限事項: skip_already_auth は上位プラグインで kong.client.authenticate() 済みの場合に
# スキップする機能。統合テストで再現するには別の認証プラグインが必要。
# ここでは credential 未設定時に skip されず通常の認証フローに入ることを確認。
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_PROXY/test/standard/")
if [ "$STATUS" = "302" ]; then
  pass "credential未設定時にskipされず認証フローが動作すること"
else
  fail "credential未設定時にskipされず認証フローが動作すること" "expected 302, got $STATUS"
fi

# ---------------------------------------------------------------------------
# 結果報告
# ---------------------------------------------------------------------------
report
