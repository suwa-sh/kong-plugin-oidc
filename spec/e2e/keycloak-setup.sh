#!/usr/bin/env bash
# Keycloak 初期セットアップ: クライアント登録・トークン有効期限設定・テストユーザー作成
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="master"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_JSON="$SCRIPT_DIR/../../keycloak-client.json"

REQUEST_TIMEOUT=10

echo ">>> Keycloak セットアップ開始"

# --- 1. Keycloak 起動待ち ---
echo ">>> Keycloak の起動を待機中..."
RETRY=0
MAX_RETRY=60
until curl -sf --max-time "$REQUEST_TIMEOUT" "$KEYCLOAK_URL/health/ready" > /dev/null 2>&1; do
  RETRY=$((RETRY + 1))
  if [ "$RETRY" -ge "$MAX_RETRY" ]; then
    echo "ERROR: Keycloak が ${MAX_RETRY} 回のリトライ後も起動しませんでした"
    exit 1
  fi
  sleep 2
done
echo ">>> Keycloak が起動しました"

# --- 1.5. SSL required を無効化 ---
echo ">>> master realm の sslRequired を NONE に設定中..."
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.e2e.yml"
docker compose -f "$COMPOSE_FILE" exec -T keycloak \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_ADMIN" \
    --password "$KEYCLOAK_ADMIN_PASSWORD" 2>/dev/null
docker compose -f "$COMPOSE_FILE" exec -T keycloak \
  /opt/keycloak/bin/kcadm.sh update realms/master \
    -s sslRequired=NONE 2>/dev/null
echo ">>> sslRequired を NONE に設定しました"

# --- 2. Admin トークン取得 ---
echo ">>> Admin トークンを取得中..."
ADMIN_TOKEN=$(curl -sf --max-time "$REQUEST_TIMEOUT" \
  -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=$KEYCLOAK_ADMIN&password=$KEYCLOAK_ADMIN_PASSWORD" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$ADMIN_TOKEN" ]; then
  echo "ERROR: Admin トークンの取得に失敗しました"
  exit 1
fi
echo ">>> Admin トークンを取得しました"

# --- 3. クライアント登録 ---
echo ">>> クライアント 'foo' を登録中..."
# 既存チェック
EXISTING=$(curl -sf --max-time "$REQUEST_TIMEOUT" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=foo" 2>/dev/null || echo "[]")

CLIENT_COUNT=$(echo "$EXISTING" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$CLIENT_COUNT" -gt 0 ]; then
  # 既存クライアントを更新（冪等性: secret や redirect_uri の変更に対応）
  CLIENT_ID_UUID=$(echo "$EXISTING" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$REQUEST_TIMEOUT" \
    -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_ID_UUID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$CLIENT_JSON")
  if [ "$HTTP_CODE" = "204" ]; then
    echo ">>> クライアント 'foo' を更新しました（既存）"
  else
    echo "ERROR: クライアント更新に失敗しました (HTTP $HTTP_CODE)"
    exit 1
  fi
else
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$REQUEST_TIMEOUT" \
    -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$CLIENT_JSON")

  if [ "$HTTP_CODE" = "201" ]; then
    echo ">>> クライアント 'foo' を登録しました"
  else
    echo "ERROR: クライアント登録に失敗しました (HTTP $HTTP_CODE)"
    exit 1
  fi
fi

# --- 4. トー���ン有効期限を 60 秒に設定 ---
echo ">>> Access Token 有効期限を 60 秒に設定中..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$REQUEST_TIMEOUT" \
  -X PUT "$KEYCLOAK_URL/admin/realms/$REALM" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"accessTokenLifespan": 60}')

if [ "$HTTP_CODE" = "204" ]; then
  echo ">>> Access Token 有効期限を 60 秒に設定しました"
else
  echo "ERROR: トークン有効期限の設定に失敗しました (HTTP $HTTP_CODE)"
  exit 1
fi

# --- 5. テ���トユーザー作成 ---
echo ">>> テストユーザー 'testuser' を作成中..."
EXISTING_USERS=$(curl -sf --max-time "$REQUEST_TIMEOUT" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?username=testuser&exact=true" 2>/dev/null || echo "[]")

USER_COUNT=$(echo "$EXISTING_USERS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$USER_COUNT" -eq 0 ]; then
  # ユーザー作成
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$REQUEST_TIMEOUT" \
    -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "username": "testuser",
      "email": "testuser@example.com",
      "firstName": "Test",
      "lastName": "User",
      "enabled": true,
      "emailVerified": true
    }')

  if [ "$HTTP_CODE" != "201" ]; then
    echo "ERROR: テストユーザーの作成に失敗しました (HTTP $HTTP_CODE)"
    exit 1
  fi
  echo ">>> テストユーザー 'testuser' を作成しました"
else
  echo ">>> テストユーザー 'testuser' は既に存在します"
fi

# パスワードを常にリセット（冪等性: パスワード変更に対応）
USER_ID=$(curl -sf --max-time "$REQUEST_TIMEOUT" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?username=testuser&exact=true" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$REQUEST_TIMEOUT" \
  -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "password", "value": "testpass", "temporary": false}')

if [ "$HTTP_CODE" = "204" ]; then
  echo ">>> テストユーザーのパスワードを設定しました (password: testpass)"
else
  echo "ERROR: テストユーザーのパスワード設定に失敗しました (HTTP $HTTP_CODE)"
  exit 1
fi

echo ""
echo ">>> Keycloak セットアップ完了"
echo "    - クライアント: foo (secret: fUp4H6418Zt3Zcj1Lxyh3DxrGPs1WE4o)"
echo "    - Access Token 有効期限: 60 秒"
echo "    - テストユーザー: testuser / testpass"
