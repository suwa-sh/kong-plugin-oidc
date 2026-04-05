# kong-oidc

[![CI](https://github.com/suwa-sh/kong-plugin-oidc/actions/workflows/ci.yml/badge.svg)](https://github.com/suwa-sh/kong-plugin-oidc/actions/workflows/ci.yml)

[Kong](https://github.com/Kong/kong) 用の [OpenID Connect](http://openid.net/specs/openid-connect-core-1_0.html) Relying Party (RP) プラグイン。

[OpenID Connect Discovery](http://openid.net/specs/openid-connect-discovery-1_0.html) と Authorization Code フローにより、OpenID Connect Provider に対してユーザーを認証する。`lua-resty-openidc` を利用し、認証済みセッションを Cookie または Redis に暗号化して保存する。

ディスカバリドキュメントとアクセストークンのサーバーワイドキャッシュに対応。OAuth/OpenID Connect を終端するリバースプロキシとして、バックエンドサービス側での認証実装を不要にする。

## クイックスタート

GHCR の公開イメージで Keycloak + Redis 環境を試す:

```bash
cd examples
docker compose up -d
```

Keycloak 管理画面（`http://localhost:8080`、admin/admin）でテストユーザーとクライアントを作成後、
`http://localhost:8000/some/path` にアクセスすると OIDC 認証フローが開始される。

詳細は [examples/](examples/) を参照。

## Docker イメージ

```bash
docker pull ghcr.io/suwa-sh/kong-plugin-oidc:latest
```

| タグ | 内容 |
|------|------|
| `latest` | 最新ビルド |
| `kong-3.11.0.8-1.6.0` | Kong 3.11.0.8 + プラグイン 1.6.0 |

`KONG_PLUGINS` 環境変数に `oidc` を追加して使用する:

```yaml
environment:
  KONG_PLUGINS: bundled,oidc
```

## 開発

### ビルド

```bash
docker build -t kong:kong-oidc .
```

Dockerfile は `ARG KONG_VERSION` でベースイメージを指定可能:

```bash
docker build --build-arg KONG_VERSION=3.9.1.2-ubuntu -t kong:kong-oidc .
```

### テスト

```bash
# 静的解析
qlty check --all
luacheck kong/

# ユニットテスト
busted spec/unit/

# 統合テスト（Docker 必要）
bash spec/integration/run-tests.sh

# E2E テスト（Docker + Python 必要）
bash spec/e2e/run-e2e.sh
```

### 依存関係

- [`lua-resty-openidc`](https://github.com/zmartzone/lua-resty-openidc/) ~> 1.8.0

アーキテクチャの詳細は [docs/architecture.md](docs/architecture.md)、テスト戦略は [docs/test-strategy.md](docs/test-strategy.md) を参照。

## 設定パラメータ

必須カラムは `schema.lua` の `required` フラグに対応する。デフォルト値がある場合、ユーザーが値を指定しなくてもデフォルトが適用される。

### OIDC 基本設定

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.client_id` | | yes | OIDC クライアント ID |
| `config.client_secret` | | yes | OIDC クライアントシークレット |
| `config.discovery` | `https://.well-known/openid-configuration` | yes | OIDC ディスカバリエンドポイント |
| `config.scope` | `openid` | yes | OAuth2 トークンスコープ。OIDC では `openid` 必須 |
| `config.response_type` | `code` | yes | OAuth2 レスポンスタイプ |
| `config.ssl_verify` | `no` | yes | OIDC Provider への SSL 検証を有効化 |
| `config.token_endpoint_auth_method` | `client_secret_post` | yes | トークンエンドポイントの認証方式 |
| `config.timeout` | | no | OIDC エンドポイント呼び出しのタイムアウト |
| `config.redirect_uri` | | no | 認証成功後に OP がリダイレクトする URI |
| `config.recovery_page_path` | | no | エラー時（401 以外）のリダイレクト先 |

### 認証動作制御

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.unauth_action` | `auth` | no | 未認証時の動作。`auth`: ログインページにリダイレクト、`deny`: 401 を返す |
| `config.bearer_only` | `no` | yes | イントロスペクションのみ（リダイレクトなし） |
| `config.realm` | `kong` | yes | `WWW-Authenticate` ヘッダーの realm |
| `config.filters` | | no | 認証をバイパスするパスのパターン |
| `config.ignore_auth_filters` | | no | 認証をバイパスするエンドポイントのカンマ区切りリスト |
| `config.skip_already_auth_requests` | `no` | no | 上位プラグインで認証済みのリクエストをスキップ |

### イントロスペクション

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.introspection_endpoint` | | no | トークンイントロスペクションエンドポイント |
| `config.introspection_endpoint_auth_method` | | no | イントロスペクション認証方式。`client_secret_basic` / `client_secret_post` |
| `config.introspection_cache_ignore` | `no` | yes | イントロスペクション結果のキャッシュを無視 |
| `config.use_jwks` | `no` | yes | イントロスペクション時に JWKS による JWT 検証を使用 |
| `config.validate_scope` | `no` | yes | スコープ検証を有効化 |

### Bearer JWT 認証

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.bearer_jwt_auth_enable` | `no` | no | Authorization ヘッダーの Bearer JWT を JWKS で検証。iss, sub, aud, exp, iat を検証 |
| `config.bearer_jwt_auth_allowed_auds` | | no | JWT の `aud` 許可値リスト。未指定時は `client_id` を使用 |
| `config.bearer_jwt_auth_signing_algs` | `["RS256"]` | yes | 許可する署名アルゴリズムのリスト |

### セッション設定

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.cookie_name` | | no | セッション Cookie 名 |
| `config.encryption_secret` | | yes | セッション暗号化の鍵導出に使用するシークレット |
| `config.session_idling_timeout` | `0` | no | アイドルタイムアウト（秒）。`0` で無効 |
| `config.session_rolling_timeout` | `0` | no | ローリングタイムアウト（秒）。`0` で無効 |
| `config.session_absolute_timeout` | `0` | no | 絶対タイムアウト（秒）。`0` で無効 |
| `config.session_remember_rolling_timeout` | `0` | no | 永続セッションのローリングタイムアウト（秒） |
| `config.session_remember_absolute_timeout` | `0` | no | 永続セッションの絶対タイムアウト（秒） |
| `config.session_storage` | `cookie` | yes | セッションストレージ。`cookie` または `redis` |
| `config.session_redis_host` | `127.0.0.1` | no | Redis ホスト |
| `config.session_redis_port` | `6379` | no | Redis ポート |
| `config.session_redis_password` | | no | Redis パスワード |
| `config.session_redis_database` | `0` | no | Redis データベース番号 |
| `config.session_redis_ssl` | `no` | no | Redis への SSL 接続 |

### ログアウト設定

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.logout_path` | `/logout` | no | ログアウトパス |
| `config.redirect_after_logout_uri` | `/` | no | ログアウト後のリダイレクト先 |
| `config.redirect_after_logout_with_id_token_hint` | `no` | no | ログアウト時に `id_token_hint` パラメータを送信 |
| `config.post_logout_redirect_uri` | | no | OP のログアウト後リダイレクト先 |
| `config.revoke_tokens_on_logout` | `no` | no | ログアウト時にトークンを失効させる |

### ヘッダー注入設定

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.userinfo_header_name` | `X-USERINFO` | no | ユーザー情報ヘッダー名 |
| `config.id_token_header_name` | `X-ID-Token` | no | ID トークンヘッダー名 |
| `config.access_token_header_name` | `X-Access-Token` | no | アクセストークンヘッダー名 |
| `config.access_token_as_bearer` | `no` | no | アクセストークンを Bearer 形式で送信 |
| `config.disable_userinfo_header` | `no` | no | ユーザー情報ヘッダーを無効化 |
| `config.disable_id_token_header` | `no` | no | ID トークンヘッダーを無効化 |
| `config.disable_access_token_header` | `no` | no | アクセストークンヘッダーを無効化 |
| `config.groups_claim` | `groups` | no | トークンからグループ情報を取得するクレーム名 |
| `config.header_names` | `[]` | yes | カスタムヘッダー名リスト。`header_claims` と同数の要素が必要 |
| `config.header_claims` | `[]` | yes | カスタムヘッダーのソースとなるクレーム名リスト |

### プロキシ・デバッグ設定

| パラメータ | デフォルト | 必須 | 説明 |
|-----------|----------|------|------|
| `config.http_proxy` | | no | HTTP プロキシ URL |
| `config.https_proxy` | | no | HTTPS プロキシ URL（`http://proxy` 形式のみ対応） |
| `config.openidc_debug_log_level` | `ngx.DEBUG` | no | lua-resty-openidc のログレベル。`ngx.DEBUG` / `ngx.INFO` / `ngx.WARN` / `ngx.ERR` |

---

## 上流リクエストへのヘッダー注入

認証成功時、プラグインは以下のヘッダーをバックエンドに注入する:

- `X-USERINFO`: ユーザー情報（Base64 エンコード JSON）
- `X-Access-Token`: アクセストークン（生トークン文字列、または `access_token_as_bearer=yes` で `Bearer <token>` 形式）
- `X-ID-Token`: ID トークン（Base64 エンコード JSON）
- `X-Credential-Identifier`: ユーザーの `sub` クレーム

Kong の認証情報として `kong.client.authenticate()` が呼ばれ、以下が設定される:

```lua
credential = {
    id = "sub クレームの値",
    username = "preferred_username クレームの値"
}
```

グループ情報はトークンの `groups` クレーム（設定変更可能）から取得し、`kong.ctx.shared.authenticated_groups` に設定される。Kong の認可プラグインで利用可能。

### JWT クレームをカスタムヘッダーにマッピング

`header_names` と `header_claims` を使い、トークン内の任意のクレームをバックエンド向けヘッダーとして注入できる。両パラメータは同数の要素が必要で、位置で対応付けられる。

設定例（`kong.yml` 抜粋）:

```yaml
# kong.yml
services:
- host: upstream-service
  plugins:
  - name: oidc
    config:
      client_id: foo
      client_secret: secret
      discovery: http://keycloak/realms/master/.well-known/openid-configuration
      header_claims: ["email",        "name",        "realm_access.roles"]
      header_names:  ["x-oidc-email", "x-oidc-name", "x-oidc-roles"     ]
```

Keycloak が発行する JWT ペイロードの例:

```json
{
  "sub": "a6a78d91-5494-4ce3-9555-878a185ca4b9",
  "email": "alice@example.com",
  "name": "Alice Smith",
  "preferred_username": "alice",
  "realm_access": {
    "roles": ["admin", "user"]
  }
}
```

バックエンドが受け取るリクエストヘッダー:

```
x-oidc-email: alice@example.com
x-oidc-name: Alice Smith
x-oidc-roles: admin, user
```

テーブル型のクレーム値（`roles` 等）はカンマ区切り文字列に自動変換される。クレームのソースは認証方式により異なる（Authorization Code: `user` / `id_token`、Bearer JWT / Introspection: トークンクレーム直接）。

### アクセストークンを Bearer トークンとして転送

バックエンドにアクセストークンを標準の Bearer トークンとして転送する場合:

| パラメータ | 値 |
|-----------|---|
| `config.access_token_header_name` | `Authorization` |
| `config.access_token_as_bearer` | `yes` |

---

## セッションのカスタマイズ

### セッションタイムアウトの振る舞い

lua-resty-session v4 の3種のタイムアウトは独立して評価され、いずれか1つでも超過するとセッションが無効になる。

| タイムアウト | 起点 | リクエスト時のリセット | 用途 |
|------------|------|---------------------|------|
| idling | 最後のリクエスト | リセットされる | 一定時間操作がないユーザーをログアウト |
| rolling | セッション作成 | リセットされる（上限あり） | セッションの定期的な更新を強制 |
| absolute | セッション作成 | リセットされない | セッションの最大寿命を制限 |

`remember_*` は「ログイン状態を保持する」永続セッション（ブラウザを閉じても維持）に適用される。通常セッションには `idling` / `rolling` / `absolute` が適用される。

設定の組み合わせ例（`kong.yml` 抜粋）:

```yaml
# kong.yml
services:
- plugins:
  - name: oidc
    config:
      # 例1: 30分アイドル + 24時間上限
      #   操作し続ければ24時間有効、30分放置で期限切れ
      session_idling_timeout: 1800
      session_absolute_timeout: 86400

      # 例2: 1時間ローリング + 8時間上限
      #   1時間ごとにセッションが更新され、最長8時間で強制終了
      # session_rolling_timeout: 3600
      # session_absolute_timeout: 28800

      # 例3: 全て無効（デフォルト）
      #   セッションは無期限（ブラウザを閉じるまで有効）
      # session_idling_timeout: 0
      # session_rolling_timeout: 0
      # session_absolute_timeout: 0
```

動作シナリオ（例1: idling=1800, absolute=86400）:

| 時刻 | イベント | idling 残り | absolute 残り | 結果 |
|------|---------|-----------|-------------|------|
| 0:00 | ログイン | 30分 | 24時間 | セッション開始 |
| 0:10 | リクエスト | 30分（リセット） | 23時間50分 | 有効 |
| 0:50 | （操作なし） | 0分 | 23時間10分 | **idling で期限切れ → 再認証** |
| | | | | |
| 0:00 | ログイン | 30分 | 24時間 | セッション開始 |
| ... | 30分以内にリクエストが継続 | 30分（都度リセット） | 減少し続ける | 有効 |
| 23:50 | リクエスト | 30分（リセット） | 10分 | 有効 |
| 24:00 | リクエスト | 20分 | 0分 | **absolute で期限切れ → 再認証** |

---

## フォーク独自の改善点

**来歴**: [Nokia/kong-oidc](https://github.com/nokia/kong-oidc)（2019年サポート終了）→ [revomatico/kong-oidc](https://github.com/revomatico/kong-oidc)（2024年アーカイブ）→ [julien-sarik/kong-oidc](https://github.com/julien-sarik/kong-oidc) → [suwa-sh/kong-plugin-oidc](https://github.com/suwa-sh/kong-plugin-oidc)（本リポジトリ）

### julien-sarik/kong-oidc

- Kong 3.9 / lua-resty-openidc 1.8.0 / lua-resty-session 4.0.5 への移行
- セッションタイムアウト5種の設定対応（idling / rolling / absolute / remember rolling / remember absolute）。デフォルト `0`（無効）で、resty-session の 15 分アイドルタイムアウト問題を回避
- `session_contents` 制御による user-info エンドポイント呼び出しの無効化（ID トークンに必要な情報が含まれているため）
- `openidc_debug_log_level` パラメータによる lua-resty-openidc のログレベル制御
- Podman による Kong + Keycloak + Traefik + MockServer のコンテナ構成整備

### suwa-sh/kong-plugin-oidc

- Redis セッションストレージ対応（Cookie の ~4KB 制限回避、マルチノードでのセッション共有）
- `setCredentials` の変異バグ修正（参照コピー → 浅いコピー）
- 静的解析、テスト、ドキュメントの拡充

## OpenID Connect スコープとクレーム

| スコープ | クレーム |
|---------|---------|
| `openid` | `sub`。ID トークンには `iss`, `aud`, `exp`, `iat` も含まれる |
| `profile` | `name`, `family_name`, `given_name`, `middle_name`, `preferred_username`, `nickname`, `picture`, `updated_at` |
| `email` | `email`, `email_verified` |

`openid` スコープは必須。

## トラブルシューティング

### `request to the redirect_uri path, but there's no session state found`

Cookie からセッションを取得できない場合に発生する。主な原因:

- **redirect URI の設定誤り**: Kong が公開するルートと同じ URI を設定すると、認可サーバーへのリダイレクト前にこのエンドポイントに直接アクセスしてしまう
- **スキーム不一致**: HTTP でフローを開始し、redirect URI が HTTPS の場合、Cookie が送信されない
- **セッションシークレットの不一致**: `encryption_secret` は必須パラメータだが、マルチノード構成で各ノードに異なる値を設定すると、他のノードが暗号化したセッションを復号できない。全ノードで同一の値を設定すること
- **SameSite Cookie 属性**: `Lax` または `None` に設定すべき（`Strict` ではリンクからのアクセス時に Cookie が送信されない）
- **ヘッダーサイズ制限**（Cookie モード時のみ）: Cookie にトークンが含まれるため、Kong の前段にリバースプロキシがある場合に切り詰められる可能性がある。Redis ストレージ使用時は Cookie にセッション ID のみ格納されるため該当しない
- **セッションタイムアウト**: 本フォークではデフォルト `0`（無効）だが、`session_idling_timeout` / `session_rolling_timeout` / `session_absolute_timeout` を明示的に設定している場合、認証フロー中（OP でのログイン操作中）にいずれかのタイムアウトを超過するとセッションが無効になり発生する
- **ブックマーク**: OP のログインページをブックマークしている場合、次回ログイン時にセッションが認識されない可能性がある（[schema.lua](kong/plugins/oidc/schema.lua) のタイムアウト設定を参照）

### `state from argument: xxx does not match state restored from session: yyy`

- **並行認証の競合**: 同一ブラウザの複数タブで同時に認証すると、state の競合が発生する
  - tab1 が保護エンドポイントにアクセスし、state `s1` を含む Cookie を受け取る
  - tab2 が同じエンドポイントにアクセスし、Cookie が state `s2` で上書きされる
  - tab1 が OP で認証後、state パラメータ `s1` で Kong にリダイレクトされるが、Cookie には `s2` が格納されている
  - 参照: [lua-resty-openidc#482](https://github.com/zmartzone/lua-resty-openidc/issues/482#issuecomment-1582584374)
- **ブックマーク**: OP のログインページをブックマークしている場合、次回ログイン時にセッションが認識されない可能性がある
