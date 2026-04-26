# プロジェクトメモリ

このプロジェクトで蓄積した知見・ルール。Claude Code の作業品質を維持するために参照する。

## 開発ルール

### 不要な確認質問をしない
作業中に「次はどうしますか？」と聞かず、自分で判断して進める。本当に判断が必要な分岐点でのみ質問する。

### ドキュメント作成時はファイル分割方針を先に決める
永続するドキュメント（戦略・方針）と一時的なドキュメント（実装計画・タスク詳細）は最初から別ファイルにする。混在すると後から分割の手戻りが発生する。

### worktree エージェントへの追加修正は直接編集で行う
SendMessage による worktree エージェントへの追加指示は不安定。修正が必要な場合は main の Claude Code から worktree 内のファイルを直接 Edit する。

## 環境情報

### コンテナランタイム
- podman は未インストール。docker（Docker Desktop）を使用する

### Keycloak テスト時の注意
- `keycloak-client.json` の `directAccessGrantsEnabled` は `false`。パスワードグラント（Resource Owner Password Credentials）でテストする場合は、Keycloak Admin API で事前に有効化が必要

### ssl_verify の dev / 本番ガイド
- 本番では `ssl_verify: "yes"`（v2.0.0 以降のデフォルト）を使う
- 自己署名証明書を使う dev / ローカル環境のみ `ssl_verify: "no"` を明示指定する
- HTTP の OP（テスト用 MockServer / dev Keycloak 等）では値に関わらず TLS 検証は走らないため、挙動には影響しない

## 技術知見

### lua-resty-session v4 の Redis 設定
- `session_config` に `storage = "redis"` と `redis = { host, port, ... }` をトップレベルで渡す
- cookie モード時はこれらのキーを設定しない（lua-resty-session のデフォルトが cookie）
- `lua-resty-redis` は Kong Gateway（OpenResty）に同梱済み。rockspec への追加不要

### Lua テーブル代入の注意
- `local copy = original` は参照コピー（同一オブジェクト）。浅いコピーは `for k,v in pairs()` で行う
- `utils.lua:setCredentials()` で修正済み（元は参照コピーバグ）

### Kong back-end の Bearer トークン検証
- `bearer_jwt_auth_enable` も `introspection_endpoint` も未設定の場合、Bearer トークン付きリクエストは `make_oidc()` に到達する
- `unauth_action=deny` なら 401 を返す（リダイレクトしない）

### busted + luacov でのユニットテスト
- busted はローカルインストール: `luarocks install --local busted`（`$HOME/.luarocks/bin` にパスを通す）
- カバレッジ計測: `busted --coverage spec/unit/ && luacov kong/plugins/oidc/`
- `.luacheckrc` でテストファイルの ngx/kong 書き換え許可が必要: `files["spec/**/*_spec.lua"] = { globals = { "ngx", "kong" } }`
- handler.lua のローカル関数（handle, make_oidc, introspect, verify_bearer_jwt）は公開 API の `access(config)` 経由でテスト。resty.openidc モックの戻り値と config で各パスを制御する
- `utils.lua:set_consumer()` は常に `set_consumer(nil, credential)` で呼ばれるため、consumer 非nil パスは到達不能（カバレッジ例外）

### 統合テストのインフラ知見
- MockServer 5.15.0 は distroless イメージ（sh/curl/wget なし）。Docker ヘルスチェックは使えない。ホスト側から `curl -sf -X PUT http://localhost:1080/mockserver/status` で確認（GET は 404、PUT が正しい）
- Kong の `KONG_NGINX_HTTP_LUA_SHARED_DICT` で複数辞書を定義するには `"discovery 1m; lua_shared_dict jwks 1m"` のようにセミコロン後に `lua_shared_dict` ディレクティブを含める
- Auth Code フローのシミュレーションでは nonce が動的に生成されるため、MockServer の /token レスポンスを Python（PyJWT）で動的に署名して更新する必要がある
- MockServer の `/mockserver/reset` は全 expectation をクリアするので、テスト中に呼ぶと他のエンドポイントが消える。`/mockserver/clear` で特定パスのみクリアする
- `session_contents.user = false` の設定（デフォルト）では、Auth Code フロー後も X-USERINFO ヘッダーは注入されない。これは仕様通り（OP の userinfo エンドポイントを呼ばない設計）
- Redis 停止時、Kong はセッション生成のため Redis 接続を待ちタイムアウトする。Admin API は応答し続けるのでクラッシュではない

### E2E テスト（Keycloak 実環境）のインフラ知見
- Keycloak の `sslRequired` は realm レベル設定。新規コンテナ起動時は `EXTERNAL`（デフォルト）なので、HTTP で Admin API を使うには `kcadm.sh update realms/master -s sslRequired=NONE` が必要
- `KC_HOSTNAME_URL=http://keycloak:8080` で issuer を Docker 内部ホスト名に固定すると、Kong（Docker 内部）と Python ヘルパー（ホスト側）の両方で一貫した issuer 検証が可能。ただしブラウザからの手動テストは不可（リダイレクト先が Docker 内部ホスト名になる）
- `accessTokenLifespan` は Keycloak realm レベルの設定（クライアント単位では設定不可）。Admin REST API で `PUT /admin/realms/master` に `{"accessTokenLifespan": 60}` を送る
- lua-resty-session v4 は Redis TTL を idling_timeout/absolute_timeout とは独立に管理する。セッションの有効期限判定はセッション読み込み時にライブラリが論理的に行うため、Redis の TTL 値は absolute_timeout より大きくなることがある（仕様通り）
- Keycloak 24 の Auth Code フローでは、ブラウザ Cookie に `AUTH_SESSION_ID`, `KEYCLOAK_IDENTITY`, `KEYCLOAK_SESSION` 等が設定される。Kong の session cookie のみを抽出するには、これらのプレフィックスで除外フィルタが必要
- Docker Compose でのマルチノード Kong 検証は、同一 Redis を共有する 2 つの Kong サービス（ポート 8000/8002）で実現可能。Cookie はポート非依存（RFC 6265）のため k3d は不要
