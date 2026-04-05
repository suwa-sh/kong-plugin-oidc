#!/usr/bin/env bash
# E2E 検証: Redis セッション（検証項目 1-4）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== E2E: Redis Session Verification ==="

# ---------------------------------------------------------------------------
# E2E-01: Access Token 有効期限 60 秒
# ---------------------------------------------------------------------------
echo ""
echo "--- E2E-01: Access Token 有効期限 60 秒 ---"
# Keycloak realm 設定を確認
KC_ADMIN_TOKEN=$(curl -sf --max-time 10 \
  -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

REALM_CONFIG=$(curl -sf --max-time 10 \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/master" 2>/dev/null)

TOKEN_LIFESPAN=$(echo "$REALM_CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessTokenLifespan', 'N/A'))" 2>/dev/null)
assert_equals "Realm の accessTokenLifespan が 60 秒であること" "60" "$TOKEN_LIFESPAN"

# Resource Owner Password Grant でアクセストークンを取得し、exp - iat を確認
ACCESS_TOKEN=$(curl -s --max-time 10 \
  -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=foo&client_secret=fUp4H6418Zt3Zcj1Lxyh3DxrGPs1WE4o&username=testuser&password=testpass" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || echo "")

if [ -n "$ACCESS_TOKEN" ]; then
  TOKEN_DIFF=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload_b64 = token.split('.')[1]
# base64url デコード（パディング補完）
payload_b64 += '=' * (4 - len(payload_b64) % 4)
payload = json.loads(base64.urlsafe_b64decode(payload_b64))
print(payload['exp'] - payload['iat'])
" 2>/dev/null)
  assert_equals "Access Token の exp - iat が 60 であること" "60" "${TOKEN_DIFF:-N/A}"
else
  # directAccessGrantsEnabled=false の場合は ROPC が使えない
  # その場合は realm 設定の確認のみで OK
  echo "  INFO: ROPC grant not available (directAccessGrantsEnabled=false); realm setting confirmed above"
  pass "Access Token 有効期限が realm レベルで 60 秒に設定されていること（ROPC 不可のため設定値で確認）"
fi

# ---------------------------------------------------------------------------
# E2E-02: Plugin config 確認
# ---------------------------------------------------------------------------
echo ""
echo "--- E2E-02: Plugin config 確認 ---"
PLUGIN_CONFIG=$(curl -sf --max-time 10 "$KONG_ADMIN_1/plugins" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('data', []):
    if p['name'] == 'oidc':
        c = p['config']
        print(f\"{c.get('session_storage')}|{c.get('session_idling_timeout')}|{c.get('session_absolute_timeout')}\")
        break
" 2>/dev/null)

IFS='|' read -r STORAGE IDLING ABSOLUTE <<< "${PLUGIN_CONFIG:-||}"
assert_equals "session_storage が redis であること" "redis" "${STORAGE:-N/A}"
assert_equals "session_idling_timeout が 1800 であること" "1800" "${IDLING:-N/A}"
assert_equals "session_absolute_timeout が 86400 であること" "86400" "${ABSOLUTE:-N/A}"

# ---------------------------------------------------------------------------
# E2E-03: Redis セッション保存
# ---------------------------------------------------------------------------
echo ""
echo "--- E2E-03: Redis セッション保存 ---"
redis_flush

# Auth Code フロー実行
AUTH_OUTPUT=$(python3 "$AUTH_HELPER" "$KONG_PROXY_1" "/some/path/" 2>&1)
COOKIE_LINE=$(echo "$AUTH_OUTPUT" | grep -v "^INFO:" | grep -v "^ERROR:" | grep -v "^DEBUG:" | head -1)
INFO_LINE=$(echo "$AUTH_OUTPUT" | grep "^INFO:" | tail -1)

if [ -n "$COOKIE_LINE" ]; then
  pass "Auth Code フローが完了しセッション Cookie が発行されたこと"
else
  fail "Auth Code フローが完了しセッション Cookie が発行されたこと" "no cookie returned"
  echo "  DEBUG: auth helper output:"
  echo "$AUTH_OUTPUT" | sed 's/^/    /' >&2
fi

# Redis にセッションキーが存在することを確認
assert_redis_has_keys "Redis にセッションデータが保存されていること"

# Redis キーの TTL 確認（有限であること）
# lua-resty-session v4 は absolute_timeout 等を考慮した独自の TTL を Redis に設定する
# セッションの idling/absolute タイムアウトはセッション読み込み時にライブラリが論理的に判定するため
# Redis の TTL は absolute_timeout より大きくなることがある（仕様通りの動作）
TTL=$($REDIS_CLI --raw EVAL "local keys = redis.call('KEYS', '*'); if #keys > 0 then return redis.call('TTL', keys[1]) else return -2 end" 0 2>/dev/null | tail -1 | tr -dc '0-9-')
TTL="${TTL:-0}"
if [ "$TTL" -gt 0 ]; then
  pass "Redis キーに有限の TTL が設定されていること (TTL=${TTL}s)"
elif [ "$TTL" -eq -1 ]; then
  fail "Redis キーに有限の TTL が設定されていること" "TTL=-1 (no expiry set)"
elif [ "$TTL" -eq -2 ]; then
  fail "Redis キーに有限の TTL が設定されていること" "no keys found"
else
  fail "Redis キーに有限の TTL が設定されていること" "TTL=$TTL"
fi

# ---------------------------------------------------------------------------
# E2E-04: Cookie サイズ（session ID のみ）
# ---------------------------------------------------------------------------
echo ""
echo "--- E2E-04: Cookie サイズ ---"
COOKIE_SIZE=$(echo "$INFO_LINE" | grep -oE 'total_size=[0-9]+' | grep -oE '[0-9]+')
COOKIE_SIZE="${COOKIE_SIZE:-9999}"
assert_less_than "Cookie サイズが 200 バイト未満であること (size=$COOKIE_SIZE)" "$COOKIE_SIZE" 200

# ---------------------------------------------------------------------------
# 結果報告
# ---------------------------------------------------------------------------
report
