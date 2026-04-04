# テスト戦略

## 1. テストピラミッド概要

| C4 レイヤー | テストレベル | スコープ | フレームワーク |
|---|---|---|---|
| Component | ユニットテスト | 各 Lua モジュール単体 | busted + luassert |
| Container | 統合テスト | Kong + Plugin + Redis | kong-pongo or docker compose + busted |
| Context | E2E テスト | 全スタック（Kong + Keycloak + Redis + upstream） | docker compose + curl/shell |

## 2. テスト規約

### 2.1 命名規則
busted の `describe` / `it` で日本語命名:
- `describe("テスト対象関数名")` でグルーピング
- `it("XXXの場合_YYYであること")` でテストケース命名

例:
```lua
describe("shouldProcessRequest", function()
  it("フィルタ未設定の場合_trueであること", function()
    -- Arrange
    local config = { filters = {} }
    ngx.var.uri = "/any/path"

    -- Act
    local result = filter.shouldProcessRequest(config)

    -- Assert
    assert.is_true(result)
  end)
end)
```

### 2.2 AAA パターン
各テストメソッドは3セクションで構成:
- **Arrange**: テストデータ・モックの準備
- **Act**: テスト対象の実行
- **Assert**: 結果の検証

セクション間は空行とコメントで区切る。

## 3. ユニットテスト方針

### 3.1 フレームワーク・ツール
- テストランナー: busted（.luacheckrc の `std = "ngx_lua+busted"` で設定済み）
- アサーション: luassert（busted 同梱）
- モック: busted 組み込みの `mock()`, `stub()`, `spy()`
- ファイル配置: `spec/unit/`
- 命名規則: `spec/unit/<module>_spec.lua`

### 3.2 モック戦略

**原則**: プラグインの境界（ngx, kong, resty.openidc）をモックし、ライブラリ内部はテストしない。

**共有モック定義** (`spec/unit/helpers/mocks.lua`):

グローバルモック:
```
ngx.var.uri, ngx.var.request_uri
ngx.req.get_uri_args(), ngx.req.get_headers()
ngx.log(), ngx.encode_base64()
ngx.redirect()
ngx.DEBUG, ngx.INFO, ngx.WARN, ngx.ERR
ngx.HTTP_UNAUTHORIZED, ngx.HTTP_FORBIDDEN, ngx.HTTP_INTERNAL_SERVER_ERROR
ngx.header

kong.service.request.set_header(), kong.service.request.clear_header()
kong.client.authenticate(), kong.client.get_credential()
kong.ctx.shared
kong.response.error()
kong.log.err()
kong.constants.HEADERS
```

ライブラリモック（境界のみ）:
```
resty.openidc.authenticate()
resty.openidc.introspect()
resty.openidc.bearer_jwt_verify()
resty.openidc.get_discovery_doc()
resty.openidc.set_logging()
cjson.encode(), cjson.decode()
resty.jwt-validators (factory functions)  -- verify_bearer_jwt で使用。バリデータ生成関数をモックし、実際のJWT検証ロジックはテストしない
```

## 4. 統合テスト方針

### 4.1 フレームワーク・ツール
- kong-pongo（Kong プラグインテストフレームワーク）または docker compose + busted
- ファイル配置: `spec/integration/`

### 4.2 インフラ構成
Kong + Redis + MockServer（疑似 OP）。Keycloak は不要（MockServer で OP エンドポイントをモック）。

MockServer が模擬する OP エンドポイント:
- `GET /.well-known/openid-configuration` → ディスカバリドキュメント
- `GET /certs` → JWKS（事前生成 RSA 鍵ペア）
- `POST /token` → access_token + id_token（事前署名 JWT）
- `POST /token/introspect` → active/inactive レスポンス

## 5. E2E テスト方針

### 5.1 フレームワーク・ツール
- docker compose（全スタック起動）
- テストランナー: Shell スクリプト + curl
- ファイル配置: `spec/e2e/`
- Keycloak セットアップ: `keycloak-client.json` インポート + Admin REST API で自動化
- 注意: `keycloak-client.json` の `directAccessGrantsEnabled` はデフォルト `false`。Bearer JWT テスト実行前に Keycloak Admin API で有効化が必要（`keycloak-setup.sh` で自動化する）

### 5.2 インフラ構成
Kong + Keycloak + Traefik + Redis + MockServer（upstream）

## 6. テスト除外範囲

| 除外対象 | 理由 |
|---------|------|
| lua-resty-openidc 内部フロー | ライブラリの責務。呼び出しインターフェースのみテスト |
| lua-resty-session の暗号化・ストレージ実装 | ライブラリの責務 |
| Kong スキーマバリデーションエンジン | Kong フレームワークの責務 |
| Keycloak トークン生成の正当性 | OP の責務 |
| Redis データ永続性 | インフラの責務 |
| Lua 標準ライブラリ（string.find, cjson 等） | 標準ライブラリの責務 |

## 7. CI/CD パイプライン（GitHub Actions）

### 7.1 ジョブ依存関係

```
lint ─────┬──→ unit-test ──→ integration-test ──→ e2e-test
          └──→ build
```

- `lint` と `build` は並列実行可能
- `unit-test` は `lint` 通過後
- `integration-test` は `lint` + `unit-test` 通過後
- `e2e-test` は `integration-test` 通過後

### 7.2 実行時間目安

| ジョブ | 目標時間 |
|-------|---------|
| lint | < 30 秒 |
| unit-test | < 5 秒 |
| integration-test | < 60 秒 |
| e2e-test | < 5 分（Keycloak 起動含む） |
| build | < 2 分 |
