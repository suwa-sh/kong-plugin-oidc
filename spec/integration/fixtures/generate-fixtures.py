#!/usr/bin/env python3
"""
RSA鍵ペア・JWKS・静的JWT・MockServer設定を生成するスクリプト。
一度実行してフィクスチャをコミットする。CIでは実行しない。

Usage:
    python3 spec/integration/fixtures/generate-fixtures.py
"""
import base64
import json
import os
import time

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

FIXTURES_DIR = os.path.dirname(os.path.abspath(__file__))
KEYS_DIR = os.path.join(FIXTURES_DIR, "keys")
MOCKSERVER_DIR = os.path.join(FIXTURES_DIR, "mockserver")

# MockServer の issuer URL（Docker Compose ネットワーク内）
ISSUER = "http://mockserver:1080"
CLIENT_ID = "test-client"
KID = "test-key-1"


def generate_rsa_keys():
    """RSA 2048bit 鍵ペアを生成"""
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key = private_key.public_key()

    # PEM 形式で保存
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    os.makedirs(KEYS_DIR, exist_ok=True)
    with open(os.path.join(KEYS_DIR, "rsa-private.pem"), "wb") as f:
        f.write(private_pem)
    with open(os.path.join(KEYS_DIR, "rsa-public.pem"), "wb") as f:
        f.write(public_pem)

    return private_key, public_key


def public_key_to_jwks(public_key):
    """公開鍵を JWKS 形式に変換"""
    pub_numbers = public_key.public_numbers()

    def _int_to_base64url(n, length=None):
        b = n.to_bytes(length or ((n.bit_length() + 7) // 8), byteorder="big")
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")

    return {
        "keys": [
            {
                "kty": "RSA",
                "alg": "RS256",
                "use": "sig",
                "kid": KID,
                "n": _int_to_base64url(pub_numbers.n),
                "e": _int_to_base64url(pub_numbers.e),
            }
        ]
    }


def generate_static_jwt(private_key):
    """Bearer JWT テスト用の静的 JWT を生成（有効期限10年）"""
    now = int(time.time())
    payload = {
        "iss": ISSUER,
        "sub": "test-user",
        "aud": CLIENT_ID,
        "exp": now + 10 * 365 * 24 * 3600,  # 10年後
        "iat": now,
        "preferred_username": "testuser",
        "email": "test@example.com",
        "groups": ["admin", "users"],
    }
    token = jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": KID})

    jwt_dir = os.path.join(FIXTURES_DIR, "jwt")
    os.makedirs(jwt_dir, exist_ok=True)
    with open(os.path.join(jwt_dir, "valid-bearer.jwt"), "w") as f:
        f.write(token)

    return token


def generate_mockserver_init(jwks_json, static_jwt):
    """MockServer 初期化 JSON を生成"""
    discovery = {
        "issuer": ISSUER,
        "authorization_endpoint": ISSUER + "/authorize",
        "token_endpoint": ISSUER + "/token",
        "userinfo_endpoint": ISSUER + "/userinfo",
        "jwks_uri": ISSUER + "/certs",
        "introspection_endpoint": ISSUER + "/token/introspect",
        "end_session_endpoint": ISSUER + "/logout",
        "response_types_supported": ["code"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["RS256"],
        "scopes_supported": ["openid", "profile", "email"],
        "token_endpoint_auth_methods_supported": [
            "client_secret_post",
            "client_secret_basic",
        ],
        "claims_supported": [
            "sub", "iss", "aud", "exp", "iat",
            "preferred_username", "email", "groups",
        ],
    }

    expectations = [
        # Discovery endpoint
        {
            "httpRequest": {"method": "GET", "path": "/.well-known/openid-configuration"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps(discovery),
            },
        },
        # JWKS endpoint
        {
            "httpRequest": {"method": "GET", "path": "/certs"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps(jwks_json),
            },
        },
        # Token endpoint（静的レスポンス、Group B テスト時に動的に上書きされる）
        {
            "httpRequest": {"method": "POST", "path": "/token"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps({
                    "access_token": static_jwt,
                    "id_token": static_jwt,
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "scope": "openid",
                }),
            },
        },
        # Introspection endpoint
        {
            "httpRequest": {"method": "POST", "path": "/token/introspect"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps({
                    "active": True,
                    "sub": "test-user",
                    "client_id": CLIENT_ID,
                    "scope": "openid",
                    "preferred_username": "testuser",
                    "email": "test@example.com",
                }),
            },
        },
        # Authorize endpoint（302 は Kong がリダイレクトするので、ここでは単純な200を返す）
        {
            "httpRequest": {"method": "GET", "path": "/authorize"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["text/html"]},
                "body": "Mock Authorization Page",
            },
        },
        # Userinfo endpoint
        {
            "httpRequest": {"method": "GET", "path": "/userinfo"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps({
                    "sub": "test-user",
                    "preferred_username": "testuser",
                    "email": "test@example.com",
                    "groups": ["admin", "users"],
                }),
            },
        },
        # Upstream mock（Kong がプロキシするバックエンド）
        {
            "httpRequest": {"method": "GET", "path": "/upstream/.*"},
            "httpResponse": {
                "statusCode": 200,
                "headers": {"Content-Type": ["application/json"]},
                "body": json.dumps({"status": "ok", "upstream": True}),
            },
        },
    ]

    os.makedirs(MOCKSERVER_DIR, exist_ok=True)
    with open(os.path.join(MOCKSERVER_DIR, "initializerJson.json"), "w") as f:
        json.dump(expectations, f, indent=2)


def main():
    print("Generating RSA key pair...")
    private_key, public_key = generate_rsa_keys()
    print(f"  -> {KEYS_DIR}/rsa-private.pem")
    print(f"  -> {KEYS_DIR}/rsa-public.pem")

    print("Generating JWKS...")
    jwks_json = public_key_to_jwks(public_key)

    print("Generating static Bearer JWT...")
    static_jwt = generate_static_jwt(private_key)
    print(f"  -> {FIXTURES_DIR}/jwt/valid-bearer.jwt")

    print("Generating MockServer initializer...")
    generate_mockserver_init(jwks_json, static_jwt)
    print(f"  -> {MOCKSERVER_DIR}/initializerJson.json")

    print("Done!")


if __name__ == "__main__":
    main()
