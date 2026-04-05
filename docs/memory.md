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
- `pods.yml` は Kubernetes Pod spec（podman play kube 用）。docker 環境では `docker run` で個別にコンテナを起動する

### Keycloak テスト時の注意
- `keycloak-client.json` の `directAccessGrantsEnabled` は `false`。パスワードグラント（Resource Owner Password Credentials）でテストする場合は、Keycloak Admin API で事前に有効化が必要

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
