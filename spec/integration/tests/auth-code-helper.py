#!/usr/bin/env python3
"""
Auth Code フロー シミュレーション ヘルパー。
1. Kong に初回リクエストを送り、302 リダイレクトから state/nonce を取得
2. nonce を含む id_token JWT を動的署名
3. MockServer の /token レスポンスを更新
4. コールバック URL にリクエストを送りセッションを確立

Usage:
    python3 auth-code-helper.py <kong_url> <route_path>
    # 出力: セッション Cookie（後続リクエストで使用）
"""
import json
import os
import sys
import time
from urllib.parse import parse_qs, urlparse

import jwt as pyjwt
import requests

REQUEST_TIMEOUT = (5, 10)  # (connect, read) seconds

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURES_DIR = os.path.join(SCRIPT_DIR, "..", "fixtures")
PRIVATE_KEY_PATH = os.path.join(FIXTURES_DIR, "keys", "rsa-private.pem")
MOCKSERVER_URL = os.getenv("MOCKSERVER_URL", "http://localhost:1080")
CLIENT_ID = "test-client"
ISSUER = "http://mockserver:1080"
KID = "test-key-1"


def load_private_key():
    with open(PRIVATE_KEY_PATH, "rb") as f:
        return f.read()


def create_signed_jwt(nonce, private_key, claims_override=None):
    """nonce を含む id_token JWT を署名"""
    now = int(time.time())
    payload = {
        "iss": ISSUER,
        "sub": "test-user",
        "aud": CLIENT_ID,
        "exp": now + 3600,
        "iat": now,
        "nonce": nonce,
        "preferred_username": "testuser",
        "email": "test@example.com",
        "groups": ["admin", "users"],
    }
    if claims_override:
        payload.update(claims_override)
    return pyjwt.encode(payload, private_key, algorithm="RS256", headers={"kid": KID})


def update_mockserver_token_response(access_token, id_token):
    """MockServer の /token レスポンスを動的に更新"""
    # 既存の /token expectation をクリア
    resp = requests.put(
        f"{MOCKSERVER_URL}/mockserver/clear",
        json={"path": "/token", "method": "POST"},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    # 新しい expectation を設定
    resp = requests.put(
        f"{MOCKSERVER_URL}/mockserver/expectation",
        timeout=REQUEST_TIMEOUT,
        json={
            "httpRequest": {"method": "POST", "path": "/token"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps({
                    "access_token": access_token,
                    "id_token": id_token,
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "scope": "openid",
                }),
            },
        },
    )
    resp.raise_for_status()


def simulate_auth_code_flow(kong_url, route_path):
    """Auth Code フローをシミュレートし、セッション Cookie を返す"""
    private_key = load_private_key()

    # Step 1: 初回リクエスト → 302 リダイレクト + Set-Cookie
    session = requests.Session()
    resp = session.get(f"{kong_url}{route_path}", allow_redirects=False, timeout=REQUEST_TIMEOUT)
    if resp.status_code != 302:
        print(f"ERROR: Expected 302, got {resp.status_code}", file=sys.stderr)
        sys.exit(1)

    location = resp.headers.get("Location", "")
    cookies = resp.cookies

    # Step 2: Location URL から state と nonce を抽出
    parsed = urlparse(location)
    params = parse_qs(parsed.query)
    state = params.get("state", [None])[0]
    nonce = params.get("nonce", [None])[0]

    if not state or not nonce:
        print(f"ERROR: state={state}, nonce={nonce}", file=sys.stderr)
        sys.exit(1)

    # Step 3: nonce を含む JWT を動的署名
    id_token = create_signed_jwt(nonce, private_key)
    access_token = create_signed_jwt(nonce, private_key)

    # Step 4: MockServer の /token レスポンスを更新
    update_mockserver_token_response(access_token, id_token)

    # Step 5: コールバック URL にリクエスト
    # redirect_uri は get_options() で自動計算される
    # route_path が "/test/standard/" の場合、redirect_uri は "/test/standard"
    callback_path = route_path.rstrip("/")
    callback_url = f"{kong_url}{callback_path}?code=mock-auth-code&state={state}"

    resp2 = session.get(callback_url, allow_redirects=False, timeout=REQUEST_TIMEOUT)

    # 認証成功時は 302（元のパスへリダイレクト）または 200
    if resp2.status_code not in (200, 302):
        print(f"ERROR: Callback returned {resp2.status_code}", file=sys.stderr)
        print(f"Body: {resp2.text[:500]}", file=sys.stderr)
        sys.exit(1)

    # セッション Cookie を出力
    cookie_dict = requests.utils.dict_from_cookiejar(session.cookies)
    # Cookie 文字列を構築
    cookie_str = "; ".join(f"{k}={v}" for k, v in cookie_dict.items())
    print(cookie_str)

    # メタデータを stderr に出力
    total_cookie_size = sum(len(f"{k}={v}") for k, v in cookie_dict.items())
    print(f"INFO: Cookie count={len(cookie_dict)}, total_size={total_cookie_size}", file=sys.stderr)

    return cookie_str, total_cookie_size


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <kong_url> <route_path>", file=sys.stderr)
        sys.exit(1)

    kong_url = sys.argv[1]
    route_path = sys.argv[2]
    simulate_auth_code_flow(kong_url, route_path)
