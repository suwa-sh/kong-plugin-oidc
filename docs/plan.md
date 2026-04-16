
# Kong OIDC プラグイン Redis セッション対応

## 背景

- 想定する環境でのKeycloakは外部提供で設定を変更できない。
  - OIDC トークンは 60s で expire する仕様
- RP側で再認証タイミングをコントロールする必要がある
  - OIDC 認証後に HTTP セッションを発行し、30分スライディングウィンドウ / 24h 強制終了を想定
- JWT payload のサイズを考慮すると Cookie のみ（~4KB制限）では不十分 → Redis セッションが必須

## 採用プラグイン

**julien-sarik/kong-plugin-oidc** (fork of revomatico/kong-oidc)

- lua-resty-session v4 対応でセッションタイムアウト5種を設定可能
- lua-resty-openidc 1.8.0（最新系）
- Issue/PR管理あり、CLAUDE.md あり（Claude Code で開発）
- Token Introspection 対応

### 選定理由（他候補との比較）

| 候補 | 不採用理由 |
|------|-----------|
| armeldemarsac92/kong-oidc-keycloak-plugin | 機能拡張が少ない、kong.log.inspect で秘密情報露出バグあり |
| S44-Automotive/kong-oidc | 活動停止（2024-01以降コミットなし）、依存が古い |
| hanlaur/oidcify (Go) | Token Introspection 非対応、セッションが Cookie のみ（Redis 不可） |
| Kong Enterprise OIDC | 有償ライセンス |

## 対応タスク

### 1. フォークと開発環境構築

- [x] julien-sarik/kong-plugin-oidc をフォーク
- [x] ローカル開発環境構築（Kong + Keycloak + Redis の docker-compose）
- [x] 既存コードの動作確認

### 2. Redis セッションストレージ対応（schema.lua + utils.lua）

- [x] `schema.lua` にセッションストレージ関連パラメータを追加
  - `session_storage`: `"cookie"` | `"redis"`（デフォルト: `"cookie"`）
  - `session_redis_host`: string（デフォルト: `"127.0.0.1"`）
  - `session_redis_port`: number（デフォルト: 6379）
  - `session_redis_password`: string（optional）
  - `session_redis_database`: number（デフォルト: 0）
  - `session_redis_ssl`: `"yes"` | `"no"`（デフォルト: `"no"`）
- [x] `utils.lua` の `get_options()` で lua-resty-session に storage 設定を渡す
- [x] `handler.lua` の `make_oidc()` で Redis 時のみ `session_config.storage` / `session_config.redis` を設定

### 3. 上流バグの修正

- [x] `setCredentials` の変異バグ修正（`tmp_user = user` → 浅いコピーに変更）
- [x] handler.lua / rockspec のバージョン不整合修正（1.3.0 → 1.5.0）

### 4. 開発ツールのセットアップ

- [x] qlty 初期化（`qlty init`）と Lua 用 linter（luacheck）の設定
- [x] qlty による静的解析の実行と指摘事項の修正（luacheck 29件 + hadolint/radarlint 2件 → 全件解消）
- [x] docker での運用確認済み（podman は未インストール、docker run で代替）

### 5. C4 Model でアーキテクチャ整理

- [x] Context図: システム全体の境界と外部アクター（ユーザー、Keycloak、upstream サービス、Redis）
- [x] Container図: Kong / OIDC Plugin / Traefik / Keycloak / MockServer / Redis の関係と通信フロー
- [x] Component図: プラグイン内部の構成（handler / utils / filter / schema / lua-resty-openidc / lua-resty-session / jwt-validators）
- [x] コンテナ間シーケンス図（4フロー、`docs/architecture.md` section 2.1）
- [x] データモデル: 概念・論理（classDiagram）・データフロー（`docs/architecture.md` section 5）
- [x] コンポーネント粒度シーケンス図（5フロー、`docs/architecture.md` section 4）
  - 4a: 初回認証フロー（Authorization Code Flow → セッション発行 → Redis 保存）
  - 4b: 認証済みリクエスト（セッション有効 → タイムアウト検証 → upstream 転送）
  - 4c: セッション期限切れ（無効判定 → Keycloak 再認証リダイレクト）
  - 4d: Bearer JWT 認証フロー（JWKS でのJWT検証）
  - 4e: エラーフロー（401/403/500 の分岐）

### 6. テスト方針策定

- [x] C4 Model の各レイヤーに対応するテスト戦略を定義
  - Component レベル: ユニットテスト（各 Lua モジュール単体）
  - Container レベル: 統合テスト（Kong + Plugin + Redis）
  - Context レベル: E2E テスト（Kong + Keycloak + Redis + upstream）
- [x] テスト観点の洗い出し
  - 正常系: OIDC 認証→セッション発行、スライディングウィンドウ、絶対タイムアウト
  - 異常系: Redis 接続断、不正 Cookie、セッション改ざん、token 検証失敗
  - 非機能: Cookie サイズ（session ID のみであること）、マルチノードでのセッション共有

### 7. テスト整備

- [x] ユニットテストの追加（上流 fork にはテストなし）
  - filter_spec 7件、utils_spec 31件、handler_spec 27件（計65件）
  - カバレッジ 98.81%（閾値 95% を設定済み）
- [x] 統合テスト（Kong + MockServer + Redis）
  - Group A: ステートレステスト 9件（プラグインロード、フィルタ、302リダイレクト、Bearer JWT、bearer_only、deny、ログレベル、Redis停止）
  - Group B: Auth Code フロー完了テスト 6件（Redis セッション保存、Cookie サイズ、ヘッダー注入、カスタムヘッダー、Cookie 改ざん、skip_already_auth）
  - テストケース一覧: [spec/integration/README.md](../spec/integration/README.md)

### 8. 動作確認

- [x] Cookie モード後方互換性（既存 kong.yml で動作確認済み）
  - OIDC Authorization Code リダイレクト: ✅
  - セッション Cookie 発行: ✅
  - 無効/なしトークン拒否 (401): ✅
  - 新スキーマフィールドのデフォルト値: ✅
- [x] Keycloak で OIDC token 60s expire 設定（E2E-01: realm accessTokenLifespan=60 確認済み）
- [x] セッション設定: idling=1800, absolute=86400（E2E-02: Kong Admin API で確認済み）
- [x] Redis にセッションデータが保存されることを確認（E2E-03: DBSIZE > 0, TTL 有限）
- [x] Cookie には session ID のみ格納されることを確認（E2E-04: 114 bytes < 200 bytes）
- [x] マルチノード構成でのセッション共有確認（E2E-05: Docker Compose 2台構成で Kong-1 ログイン → Kong-2 セッション有効）
  - テストケース一覧: [spec/e2e/README.md](../spec/e2e/README.md)

### 9. バグフィックス v1.6.1

- [x] [issue #1](https://github.com/suwa-sh/kong-plugin-oidc/issues/1) 対応: `response.user = nil` で `injectHeaders` が 500 でクラッシュする
  - `handler.lua` に `non_nil_sources` ヘルパーを追加し、nil を除外したテーブルを `injectHeaders` に渡す
  - `utils.lua` の `injectHeaders` に `if source then` ガードを追加（防御的ガード）
  - ユニットテスト追加: `response.user = nil` の Auth Code フローで id_token からクレーム解決されること

## 設定例（完成イメージ）

```yaml
plugins:
  - name: oidc
    config:
      client_id: "your-client-id"
      client_secret: "your-client-secret"
      discovery: "https://keycloak.example.com/realms/your-realm/.well-known/openid-configuration"
      encryption_secret: "共通の暗号化キー"

      # セッションタイムアウト
      session_idling_timeout: 1800
      session_absolute_timeout: 86400

      # Redis ストレージ（新規追加パラメータ）
      session_storage: redis
      session_redis_host: redis-host
      session_redis_port: 6379
```
