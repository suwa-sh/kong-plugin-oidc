# Changelog

このプロジェクトの変更履歴。フォーマットは [Keep a Changelog](https://keepachangelog.com/) に準拠し、[Semantic Versioning](https://semver.org/) に従う。

## [Unreleased]

### ⚠ BREAKING CHANGES

- **`ssl_verify` のデフォルト値を `"no"` から `"yes"` に変更** ([#7](https://github.com/suwa-sh/kong-plugin-oidc/issues/7))
  - 影響: `ssl_verify` を未指定で運用しており、かつ **HTTPS で自己署名証明書の OP** を使っている場合、Discovery / JWKS / Introspection / Token 取得リクエストで TLS 証明書検証が失敗するようになる
  - 影響なし: HTTP の OP を使用している、または既に `ssl_verify` を明示指定している場合
  - 移行手順:
    - 本番で正規の証明書 OP を使っている場合 → 対応不要（推奨される設定に揃う）
    - 自己署名証明書の OP を使っている dev 環境 → plugin config に `ssl_verify: "no"` を明示指定する
  - 動機: セキュアバイデフォルトの原則。MITM 耐性のない既定値で運用が継続するリスクを排除

### Changed

- `examples/kong.yml` / `kong.yml` に明示的な `ssl_verify: "no"` を追加（dev 用設定の意図を明確化）
- README の `ssl_verify` 説明を更新し、本番推奨値と dev 例外を明記
- `docs/memory.md` に dev / 本番ガイドを追加

## 過去の変更

`v1.6.1` 以前の変更履歴は [Git タグ](https://github.com/suwa-sh/kong-plugin-oidc/tags) と [Releases](https://github.com/suwa-sh/kong-plugin-oidc/releases) を参照。
