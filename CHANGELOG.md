# Changelog

このプロジェクトの変更履歴。フォーマットは [Keep a Changelog](https://keepachangelog.com/) に準拠し、[Semantic Versioning](https://semver.org/) に従う。

## [1.8.0] - 2026-04-27

### Added

- **複数 Kong バージョンサポート**: `.kong-versions` でサポート対象の Kong Gateway バージョンを一元管理し、CD パイプラインが各版を並列ビルド・push する仕組みを導入
  - 新規サポート: `Kong 3.12.0.5-ubuntu`
  - 既存サポート: `Kong 3.11.0.9-ubuntu`
- ローカル全版テストランナー `spec/run-all-versions.sh`: `.kong-versions` を読んで各 Kong バージョンに対し integration / e2e テストを順次実行
- compose ファイル (`spec/integration/docker-compose.test.yml`, `spec/e2e/docker-compose.e2e.yml`) に `KONG_VERSION` build args サポート: `KONG_VERSION=<tag> docker compose ...` で任意の Kong 版をビルド可能

### Changed

- CD ワークフロー (`.github/workflows/cd.yml`) を `prepare → build-and-push (matrix) → tag-latest` の 3 ジョブ構成にリニューアル
  - GHCR タグは `kong-<kong-version>-<plugin-version>` を全サポート版に対して並列 push
  - `:latest` は `.kong-versions` の末尾に記載された最新 Kong 版を `buildx imagetools` で retag
- README の GHCR タグ表に複数バージョンを併記

## [1.7.1] - 2026-04-27

### Changed

- ベースイメージを `Kong Gateway 3.11.0.9-ubuntu` に更新（パッチアップ追従）

## [1.7.0] - 2026-04-27

### ⚠ BREAKING CHANGES

- **`ssl_verify` のデフォルト値を `"no"` から `"yes"` に変更** ([#7](https://github.com/suwa-sh/kong-plugin-oidc/issues/7) / [#14](https://github.com/suwa-sh/kong-plugin-oidc/pull/14))
  - 影響: `ssl_verify` を未指定で運用しており、かつ **HTTPS で自己署名証明書の OP** を使っている場合、Discovery / JWKS / Introspection / Token 取得リクエストで TLS 証明書検証が失敗するようになる
  - 影響なし: HTTP の OP を使用している、または既に `ssl_verify` を明示指定している場合
  - 移行手順:
    - 本番で正規の証明書 OP を使っている場合 → 対応不要（推奨される設定に揃う）
    - 自己署名証明書の OP を使っている dev 環境 → plugin config に `ssl_verify: "no"` を明示指定する
  - 動機: セキュアバイデフォルトの原則。MITM 耐性のない既定値で運用が継続するリスクを排除

### Added

- secret 系フィールド（`client_secret` / `encryption_secret` / `session_redis_password`）に `encrypted` / `referenceable` 属性を付与 ([#6](https://github.com/suwa-sh/kong-plugin-oidc/issues/6) / [#13](https://github.com/suwa-sh/kong-plugin-oidc/pull/13))
  - Kong keyring 有効環境では DB 上で暗号化保存される
  - `{vault://env/...}` 形式の Vault 参照がランタイムに解決される
  - 既存の生値設定は引き続き動作（後方互換）
- README に「シークレットの取り扱い」節を追加

### Fixed

- `X-Credential-Identifier` ヘッダーに `sub` クレームを優先設定するように修正 ([#3](https://github.com/suwa-sh/kong-plugin-oidc/issues/3) / [#9](https://github.com/suwa-sh/kong-plugin-oidc/pull/9))
  - `sub` が無い場合のみ `preferred_username` にフォールバック
  - README の説明と実装を一致させた
- `header_claims` でドット区切りパス（例: `realm_access.roles`）を解決できるように修正 ([#4](https://github.com/suwa-sh/kong-plugin-oidc/issues/4) / [#11](https://github.com/suwa-sh/kong-plugin-oidc/pull/11))
- `validate_scope=yes` で複数スコープを正しく検証できない問題を修正 ([#5](https://github.com/suwa-sh/kong-plugin-oidc/issues/5) / [#10](https://github.com/suwa-sh/kong-plugin-oidc/pull/10))
  - 設定側 `scope` とトークン側 `scope` の両方をスペース区切りで分解して比較
- `WWW-Authenticate` ヘッダに渡す `err` を sanitize するように修正 ([#8](https://github.com/suwa-sh/kong-plugin-oidc/issues/8) / [#12](https://github.com/suwa-sh/kong-plugin-oidc/pull/12))
  - CRLF / `"` の除去・エスケープと長さ制限により、ヘッダインジェクションを防止

### Changed

- `examples/kong.yml` / `kong.yml` に明示的な `ssl_verify: "no"` を追加（dev 用設定の意図を明確化）
- README の `ssl_verify` 説明を更新し、本番推奨値と dev 例外を明記
- `docs/memory.md` に dev / 本番ガイドを追加

## 過去の変更

`v1.6.1` 以前の変更履歴は [Git タグ](https://github.com/suwa-sh/kong-plugin-oidc/tags) を参照。
