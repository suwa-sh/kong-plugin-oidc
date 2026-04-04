# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクトメモリ

開発ルール・環境情報・技術知見は [docs/memory.md](docs/memory.md) を参照。

## プロジェクト概要

Kong API Gateway用のカスタムOIDC認証プラグイン。Nokia/revomaticoのアーカイブ済みフォークをベースに、セッション制御やuser-infoエンドポイント最適化などの独自改善を加えたもの。Podman上でKong + Keycloak + HTTPモックをコンテナとして動作させる。

## ビルド・実行コマンド

```bash
# Kongイメージのビルド（プラグイン同梱）
podman build -t kong:kong-oidc .

# ネットワーク作成（初回のみ）
podman network create foo

# 全サービス起動（Kong, Keycloak, HTTPモック, Traefik）
podman play kube pods.yml --net foo

# 停止
podman play kube pods.yml --down

# HTTPモックの設定（Kong経由のヘッダーを返すよう設定）
curl -v -X PUT "http://localhost:1080/mockserver/expectation" -d '{
    "httpRequest": { "path": "/" },
    "httpResponseTemplate": {
        "template": "{ \"statusCode\": 200, \"body\": \"$!request.headers\" }",
        "templateType": "VELOCITY"
    }
}'
```

起動後、`keycloak-client.json`をKeycloak管理画面（`http://localhost:8080/admin/master/console/#/master/clients`）からインポートする。

## アーキテクチャ

### プラグイン処理フロー（`handler.lua:access()`）

リクエストは以下の優先順で処理される：

1. **既認証スキップ**: `skip_already_auth_requests`有効時、上位プラグインで認証済みならスキップ
2. **フィルタ判定**: `filter.lua`でURIパターンに基づきOIDC処理をバイパス
3. **認証処理**（`handle()`内で順に試行）:
   - **Bearer JWT検証** (`bearer_jwt_auth_enable`): JWKSでJWT署名・クレーム（iss, aud, exp等）を検証。`resty.jwt-validators`で120秒のleeway設定
   - **トークンイントロスペクション** (`introspection_endpoint`設定時): OPのイントロスペクションエンドポイントで検証。`use_jwks=yes`ならJWT検証にフォールバック
   - **Authorization Codeフロー** (`make_oidc()`): `resty.openidc.authenticate()`でインタラクティブ認証。セッションは暗号化Cookieに保存

認証成功後、`utils.lua`の各関数でバックエンドへヘッダー注入：
- `X-USERINFO`: ユーザー情報（Base64エンコード）
- `X-Access-Token`: アクセストークン
- `X-ID-Token`: IDトークン（Base64エンコード）
- `kong.client.authenticate()`: Kongの認証情報（`sub`→credential ID）

### ライブラリ依存関係

```
kong-plugin-oidc (PRIORITY: 1000)
  └── lua-resty-openidc ~> 1.8.0  ← OIDC RP / Bearer検証 / イントロスペクション
       └── lua-resty-session v4.x  ← セッション暗号化・Cookie管理
```

### フォーク独自の改善点

- **session_contents制御** (`utils.lua:get_options()`): `user=false`でOPのuser-infoエンドポイント呼び出しを無効化（IDトークンに必要な情報が含まれているため）
- **openidc_debug_log_level** (`handler.lua:configure()`): 複数プラグインインスタンス間で最も抑制的なログレベルを選択
- **bearer_jwt_auth** (`handler.lua:verify_bearer_jwt()`): 独自のJWT検証ロジック（aud検証のカスタマイズ、claim_spec指定）

### コンテナ構成（`pods.yml`）

単一Pod内に4コンテナ：
- **Kong** (`:8000`/`:8001`): DBレスモード、宣言的設定（`kong.yml`マウント）。`KONG_NGINX_HTTP_LUA_SHARED_DICT`でOIDCディスカバリとJWKSをキャッシュ
- **Keycloak** (`:8080`): OIDC Provider（dev mode）
- **Traefik** (`:8888`): Keycloakへのリバースプロキシ（`/realms`パスをルーティング）。Kong→Keycloak間の通信はTraefik経由
- **MockServer** (`:1080`): バックエンドサービスのモック

### 宣言的設定（`kong.yml`）

- **front-end**: Authorization Codeフローで認証（`unauth_action`デフォルト=`auth`でリダイレクト）
- **back-end** (`/resource_server`): `unauth_action=deny`でBearer Token専用（401応答）
- グローバルプラグイン: `file-log`（機密ヘッダー除去、ユーザーID注入）、`prometheus`

## パッケージ管理

LuaRocksで管理。`kong-plugin-oidc-1.5.0-1.rockspec`がビルド定義。Dockerfile内で`luarocks make`実行。

## トラブルシューティング

### `request to the redirect_uri path, but there's no session state found`

主な原因：
- redirect URIがルートパスと重複（コールバック専用パスを設定すべき）
- HTTP/HTTPSスキーム不一致でCookieが送信されない
- `encryption_secret`未設定時、Kongワーカー間で異なるシークレットが生成される
- セッションCookieの`SameSite`属性が`Strict`（`Lax`または`None`が必要）
- リバースプロキシのヘッダーサイズ制限でCookieが切り詰められる
- セッションタイムアウト（デフォルト15分のアイドルタイムアウト。`schema.lua`のタイムアウト設定で`0`=無効化可能）

### `state from argument does not match state restored from session`

- 同一ブラウザの複数タブで同時認証するとstateの競合が発生（tab1のstate≠Cookieに上書きされたtab2のstate）
- ユーザーがOPのログインページをブックマークしている場合
