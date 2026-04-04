# プロジェクトメモリ

このプロジェクトで蓄積した知見・ルール。Claude Code の作業品質を維持するために参照する。

## 標準作業フロー

タスクごとに以下のフローを必ず実行する。各品質ゲートは問題が 0 になるまでループする。

1. **計画**: `docs/plan.md` に従い、対象タスクの完了条件を整理する
2. **環境チェック**: 必要なツール（docker, qlty, luacheck 等）と設定ファイルの内容を事前に確認する
3. **git worktree 作成**: `isolation: "worktree"` でブランチを分離。main を直接変更しない。作成後、最初に `git merge main` で最新コードと同期する
4. **作業実施**: コード変更・ドキュメント作成等
5. **静的解析ゲート**: `qlty check --all` と `luacheck kong/` を実行 → 問題 0 になるまで修正ループ
6. **テストゲート**: テストを実行 → 問題 0 になるまで修正ループ
7. **完了条件ゲート**: ステップ1で整理した完了条件を満たすまで修正ループ
8. **codex レビューゲート**: codex によるレビュー → 指摘 0 になるまで修正ループ
9. **ユーザー確認（必須・スキップ不可）**: 動作確認できる環境を準備し、確認手順を提示する。ドキュメントのみの変更でもプレビュー確認手順を提示し、ユーザーの承認を得る
10. **ユーザー指摘対応**: 変更が発生した場合、ステップ5（静的解析）からやり直す
11. **マージ**: 全ゲート通過後、worktree 内のコミットを squash してから main へマージする（`git merge --squash`）。タスク1つにつきコミット1つを原則とする
12. **ふりかえり**: KPT（Keep / Problem / Try）形式で振り返り、結果を反映する
    - `docs/memory.md`: 開発ルール・技術知見の追加・更新
    - `docs/plan.md`: タスクや方針の見直し
    - `CLAUDE.md`: アーキテクチャや手順の更新（必要に応じて）

## 開発ルール

### 不要な確認質問をしない
作業中に「次はどうしますか？」と聞かず、自分で判断して進める。本当に判断が必要な分岐点でのみ質問する。

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
