# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ドキュメント

| ドキュメント | 内容 |
|------------|------|
| [docs/architecture.md](docs/architecture.md) | C4 Model アーキテクチャ図・シーケンス図・データモデル |
| [docs/test-strategy.md](docs/test-strategy.md) | テスト戦略（テストピラミッド・規約・モック方針・CI/CD設計） |
| [docs/plan.md](docs/plan.md) | 対応タスク一覧と進捗 |
| [docs/memory.md](docs/memory.md) | 開発ルール・環境情報・技術知見 |

## プロジェクト概要

Kong API Gateway用のカスタムOIDC認証プラグイン。Nokia/revomaticoのアーカイブ済みフォークをベースに、セッション制御やuser-infoエンドポイント最適化などの独自改善を加えたもの。

## ビルド・実行コマンド

```bash
# Kongイメージのビルド（プラグイン同梱）
docker build -t kong:kong-oidc .

# 静的解析
qlty check --all
luacheck kong/

# テスト（busted セットアップ後）
busted spec/unit/
```

開発環境の詳細（コンテナ起動手順等）は [docs/memory.md](docs/memory.md) を参照。

## アーキテクチャ

> 詳細な図・シーケンス図は [docs/architecture.md](docs/architecture.md) を参照。

### プラグイン処理フロー（`handler.lua:access()`）

リクエストは以下の優先順で処理される：

1. **既認証スキップ**: `skip_already_auth_requests`有効時、上位プラグインで認証済みならスキップ
2. **フィルタ判定**: `filter.lua`でURIパターンに基づきOIDC処理をバイパス
3. **認証処理**（`handle()`内で順に試行）:
   - **Bearer JWT検証** (`bearer_jwt_auth_enable`): JWKSでJWT署名・クレーム（iss, aud, exp等）を検証。`resty.jwt-validators`で120秒のleeway設定
   - **トークンイントロスペクション** (`introspection_endpoint`設定時): OPのイントロスペクションエンドポイントで検証。`use_jwks=yes`ならJWT検証にフォールバック
   - **Authorization Codeフロー** (`make_oidc()`): `resty.openidc.authenticate()`でインタラクティブ認証。セッションは暗号化Cookie または Redis に保存

認証成功後、`utils.lua`の各関数でバックエンドへヘッダー注入：
- `X-USERINFO`: ユーザー情報（Base64エンコード）
- `X-Access-Token`: アクセストークン
- `X-ID-Token`: IDトークン（Base64エンコード）
- `kong.client.authenticate()`: Kongの認証情報（`sub`→credential ID）

### ライブラリ依存関係

```
kong-plugin-oidc (PRIORITY: 1000)
  └── lua-resty-openidc ~> 1.8.0  ← OIDC RP / Bearer検証 / イントロスペクション
       └── lua-resty-session v4.x  ← セッション暗号化・Cookie/Redis管理
```

## パッケージ管理

LuaRocksで管理。`kong-plugin-oidc-1.5.0-1.rockspec`がビルド定義。Dockerfile内で`luarocks make`実行。
