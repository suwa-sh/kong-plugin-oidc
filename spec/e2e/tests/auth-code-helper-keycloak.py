#!/usr/bin/env python3
"""
Keycloak Auth Code フロー シミュレーション ヘルパー。
1. Kong に初回リクエストを送り、302 リダイレクトから Keycloak ログイン URL を取得
2. Keycloak ログインフォームに POST してログイン
3. Keycloak からのコールバックを Kong に送りセッションを確立

Usage:
    python3 auth-code-helper-keycloak.py <kong_url> <route_path> [username] [password]
    # 出力: セッション Cookie（後続リクエストで使用）

Requirements:
    pip install requests beautifulsoup4
"""
import sys
import os
from urllib.parse import urljoin, urlparse, urlunparse

import requests
from bs4 import BeautifulSoup

REQUEST_TIMEOUT = (5, 30)  # (connect, read) seconds

KONG_URL = os.getenv("KONG_URL", "http://localhost:8000")
USERNAME = os.getenv("KC_USERNAME", "testuser")
PASSWORD = os.getenv("KC_PASSWORD", "testpass")

# Docker 内部ホスト名 → localhost マッピング（ホストからアクセスするため）
# netloc (host:port) の完全一致でのみ置換する
DOCKER_NETLOC_MAP = {
    "keycloak:8080": "localhost:8080",
}

# リダイレクト先として許可するホスト（scheme://netloc）
ALLOWED_HOSTS = {"localhost:8080", "localhost:8000", "localhost:8002"}


def rewrite_docker_url(url):
    """Docker 内部ホスト名を localhost に置換（netloc の完全一致のみ）"""
    parsed = urlparse(url)
    if parsed.netloc in DOCKER_NETLOC_MAP:
        new_netloc = DOCKER_NETLOC_MAP[parsed.netloc]
        return urlunparse(parsed._replace(netloc=new_netloc))
    return url


def validate_redirect_url(url, context=""):
    """リダイレクト先が許可されたホストかを検証"""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        print(f"ERROR: Unexpected scheme '{parsed.scheme}' in {context}: {url}", file=sys.stderr)
        sys.exit(1)
    if parsed.netloc not in ALLOWED_HOSTS:
        print(f"ERROR: Unexpected host '{parsed.netloc}' in {context}: {url}", file=sys.stderr)
        sys.exit(1)


def simulate_auth_code_flow(kong_url, route_path, username, password):
    """Keycloak Auth Code フローをシミュレートし、セッション Cookie を返す"""
    session = requests.Session()

    # Step 1: Kong に初回リクエスト -> 302 to Keycloak login
    print("INFO: Step 1 - Initial request to Kong...", file=sys.stderr)
    resp = session.get(
        f"{kong_url}{route_path}",
        allow_redirects=False,
        timeout=REQUEST_TIMEOUT,
    )
    if resp.status_code != 302:
        print(f"ERROR: Expected 302, got {resp.status_code}", file=sys.stderr)
        sys.exit(1)

    keycloak_login_url = rewrite_docker_url(resp.headers.get("Location", ""))
    validate_redirect_url(keycloak_login_url, "OIDC authorize redirect")
    print(f"INFO: Redirect to: {keycloak_login_url[:100]}...", file=sys.stderr)

    # Step 2: Keycloak ログインページを GET
    print("INFO: Step 2 - Fetching Keycloak login page...", file=sys.stderr)
    resp2 = session.get(keycloak_login_url, timeout=REQUEST_TIMEOUT)
    if resp2.status_code != 200:
        print(f"ERROR: Keycloak login page returned {resp2.status_code}", file=sys.stderr)
        sys.exit(1)

    # HTML からログインフォームの action URL を抽出
    soup = BeautifulSoup(resp2.text, "html.parser")
    form = soup.find("form", id="kc-form-login")
    if not form:
        print("ERROR: Login form not found in Keycloak page", file=sys.stderr)
        print(f"DEBUG: Page content (first 500 chars): {resp2.text[:500]}", file=sys.stderr)
        sys.exit(1)

    action_url = form.get("action")
    if not action_url:
        print("ERROR: Form action URL not found", file=sys.stderr)
        sys.exit(1)

    # 相対 URL の場合は解決
    if not action_url.startswith("http"):
        action_url = urljoin(resp2.url, action_url)
    action_url = rewrite_docker_url(action_url)
    validate_redirect_url(action_url, "login form action")

    # Step 3: ログインフォームに POST
    print("INFO: Step 3 - Submitting login form...", file=sys.stderr)
    resp3 = session.post(
        action_url,
        data={"username": username, "password": password},
        allow_redirects=False,
        timeout=REQUEST_TIMEOUT,
    )

    # Keycloak はログイン成功後、Kong のコールバック URL に 302 リダイレクト
    if resp3.status_code != 302:
        print(f"ERROR: Login POST returned {resp3.status_code} (expected 302)", file=sys.stderr)
        if resp3.status_code == 200:
            soup2 = BeautifulSoup(resp3.text, "html.parser")
            error = soup2.find(class_="alert-error") or soup2.find(id="input-error")
            if error:
                print(f"ERROR: Login error: {error.get_text(strip=True)}", file=sys.stderr)
        sys.exit(1)

    callback_url = rewrite_docker_url(resp3.headers.get("Location", ""))
    validate_redirect_url(callback_url, "auth callback")
    print(f"INFO: Callback URL: {callback_url[:100]}...", file=sys.stderr)

    # Step 4: Kong コールバック URL にリクエスト
    print("INFO: Step 4 - Following callback to Kong...", file=sys.stderr)
    resp4 = session.get(callback_url, allow_redirects=False, timeout=REQUEST_TIMEOUT)

    # 認証成功時は 302（元のパスへリダイレクト）または 200
    if resp4.status_code not in (200, 302):
        print(f"ERROR: Callback returned {resp4.status_code}", file=sys.stderr)
        print(f"Body: {resp4.text[:500]}", file=sys.stderr)
        sys.exit(1)

    # 302 の場合は最終リダイレクト先まで追跡
    if resp4.status_code == 302:
        final_url = resp4.headers.get("Location", "")
        if final_url:
            if not final_url.startswith("http"):
                final_url = f"{kong_url}{final_url}"
            print(f"INFO: Final redirect to: {final_url}", file=sys.stderr)
            resp5 = session.get(final_url, allow_redirects=False, timeout=REQUEST_TIMEOUT)
            print(f"INFO: Final response status: {resp5.status_code}", file=sys.stderr)

    # Kong セッション Cookie のみ出力（Keycloak の Cookie を除外）
    cookie_dict = requests.utils.dict_from_cookiejar(session.cookies)
    kong_cookies = {k: v for k, v in cookie_dict.items()
                    if not k.startswith(("AUTH_SESSION", "KEYCLOAK_", "KC_"))}
    cookie_str = "; ".join(f"{k}={v}" for k, v in kong_cookies.items())
    print(cookie_str)

    # メタデータを stderr に出力
    total_cookie_size = sum(len(f"{k}={v}") for k, v in kong_cookies.items())
    print(f"INFO: Cookie count={len(kong_cookies)}, total_size={total_cookie_size}", file=sys.stderr)

    return cookie_str, total_cookie_size


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <kong_url> <route_path> [username] [password]", file=sys.stderr)
        sys.exit(1)

    kong_url = sys.argv[1]
    route_path = sys.argv[2]
    username = sys.argv[3] if len(sys.argv) > 3 else USERNAME
    password = sys.argv[4] if len(sys.argv) > 4 else PASSWORD
    simulate_auth_code_flow(kong_url, route_path, username, password)
