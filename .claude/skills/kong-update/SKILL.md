---
name: kong-update
description: |
  Kong Gateway ベースイメージの更新と GHCR 公開を自動化するスキル。
  Docker Hub から最新の Kong Gateway タグを取得し、`.kong-versions` を更新、
  全サポート版で integration / e2e テストを実施した上で、git tag で CD パイプラインを
  トリガーして GHCR に公開する。
  「Kong を最新にして」「Kong バージョン更新」「GHCR に公開」「リリース」
  「Kong の新しいバージョンが出てるか確認」「docker イメージを更新」
  「サポートする Kong バージョンを追加」
  といった指示で発動する。Kong のバージョン管理やリリースに関連する指示があれば
  積極的に使用すること。
---

# Kong Gateway バージョン更新 & GHCR 公開

Kong Gateway のベースイメージを更新し、複数バージョンのテスト検証を経て GHCR に公開するワークフロー。

## 前提

- Dockerfile: `ARG KONG_VERSION=<default>` でデフォルトベースイメージを指定（後方互換用）
- `.kong-versions`: サポートする Kong バージョン一覧（CI matrix とローカル全版テストの入力）
- compose の build args: `args.KONG_VERSION: ${KONG_VERSION:-<default>}` で外部から差し込み可能
- CD ワークフロー: `.github/workflows/cd.yml` が `v*` タグで GHCR に push（`.kong-versions` で matrix 展開）
- GHCR タグ: `latest`, `kong-<kong-version>-<plugin-version>`
- プラグインバージョン: `kong-plugin-oidc-*.rockspec` の version フィールド

## ワークフロー

### Step 1: 最新 Kong バージョンの確認

Docker Hub API で `kong/kong-gateway` の最新タグを取得する。
`-ubuntu` サフィックスのタグ（本プロジェクトのベースイメージ形式）に絞って確認する。

日付サフィックス付きタグ（例: `3.10.0.9-20260313-ubuntu`）やメジャー・マイナーのみの
短縮タグ（例: `3.11-ubuntu`）は除外し、完全なバージョン番号のタグのみを対象にする。

```bash
curl -s "https://hub.docker.com/v2/repositories/kong/kong-gateway/tags?page_size=50&ordering=last_updated" \
  | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
pattern = re.compile(r'^\d+\.\d+\.\d+\.\d+-ubuntu$')
tags = [t['name'] for t in data['results']
        if pattern.match(t['name'])
        and not any(x in t['name'] for x in ['alpha', 'beta', 'rc'])]
for tag in tags[:10]:
    print(tag)
"
```

現在サポートしている版を確認:
```bash
cat .kong-versions
```

新しいバージョンがなければここで終了。

### Step 2: ユーザーに方針を確認

Kong の差分とプラグインの状態を踏まえ、以下を必ずユーザーに確認する。

1. **どのバージョンを追加/更新するか**
   - パッチアップのみ（例: 3.11.0.8 → 3.11.0.9）→ 既存版を置き換え
   - メジャー/マイナーアップ（例: 3.11.x → 3.12.x）→ 新版を `.kong-versions` に **追加**してマルチバージョンサポート
2. **プラグインバージョンの bump 方針**
   - パッチアップ追従 → patch bump（1.7.0 → 1.7.1）
   - 新メジャー Kong サポート追加 → minor bump（1.7.x → 1.8.0）
   - 既存のプラグインタグが GHCR に公開済みなら、同じ git タグは再利用不可

### Step 3: `.kong-versions` を更新

ユーザーの方針に従い `.kong-versions` を編集する。

```text
# サポートする Kong Gateway ベースイメージタグ一覧
3.11.0.9-ubuntu
3.12.0.5-ubuntu
```

Dockerfile の `ARG KONG_VERSION=...` のデフォルト値も、最も保守的な版（最古のサポート版）に揃えるか、最新に追従するかを判断する。デフォルトは「`KONG_VERSION` 未指定でビルドされた場合に使う版」なので、後方互換重視なら据え置きが無難。

### Step 4: プラグインバージョン bump（必要に応じて）

プラグインのセマンティックバージョンを変更する場合は、以下の全ファイルを一貫して更新する（漏れがあるとビルドやリリースが壊れる）:

| ファイル | 更新箇所 |
|---------|---------|
| `kong-plugin-oidc-X.Y.Z-1.rockspec` | **ファイル名をリネーム** + `version` フィールド |
| 同 rockspec | `source.url`, `description.homepage` が正しいリポジトリを指していること |
| `kong/plugins/oidc/handler.lua` | `VERSION = "X.Y.Z"` |
| `Dockerfile` | `COPY` と `RUN luarocks make` の rockspec ファイル名参照（2箇所） |
| `CLAUDE.md` | rockspec ファイル名の記載 |
| `README.md` | GHCR タグ例（`kong-A.B.C.D-X.Y.Z`） |

rockspec リネーム:
```bash
git mv kong-plugin-oidc-OLD-1.rockspec kong-plugin-oidc-NEW-1.rockspec
```

### Step 5: 全サポート版でローカル動作確認

**ビルドが通る ≠ 動く**。`.kong-versions` の全版に対して integration / e2e テストを実施する。
これがリリース可否判断の主たる根拠になるため、必ず実行する。

```bash
# 既存の compose 環境をクリーンアップしてからランナー起動
docker compose -f spec/integration/docker-compose.test.yml down 2>/dev/null
docker compose -f spec/e2e/docker-compose.e2e.yml down 2>/dev/null

bash spec/run-all-versions.sh
```

ランナー（`spec/run-all-versions.sh`）の挙動:
- `.kong-versions` の各行を `KONG_VERSION` 環境変数として export
- compose の build args 経由で Dockerfile に注入
- 各版で `spec/integration/run-tests.sh` と `spec/e2e/run-e2e.sh` を実行
- 最後に `<version>: OK | FAILED` のサマリを出力

依存ツール（事前にインストール済みであること）:
- Docker Desktop
- Python 3 + `PyJWT`, `requests`, `beautifulsoup4`
  ```bash
  pip3 install --break-system-packages PyJWT requests beautifulsoup4
  ```

任意で動かせる単一版テスト:
```bash
KONG_VERSION=3.12.0.5-ubuntu bash spec/integration/run-tests.sh
KONG_VERSION=3.12.0.5-ubuntu bash spec/e2e/run-e2e.sh
```

テスト失敗時:
- まずポート競合や前回のコンテナ残存がないか確認（偽陽性の主因）
- Kong のリリースノートで非互換変更を確認
- プラグイン側の修正が必要ならユーザーに報告
- 修正後は Step 5 からやり直す

### Step 6: CHANGELOG.md 更新

リリース内容を `CHANGELOG.md` の先頭近く（`## [前の版]` の上）に追加する。Keep a Changelog 形式に従い、`Added` / `Changed` / `Fixed` / `BREAKING CHANGES` などのセクションで整理する。

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...
```

CHANGELOG はその後の Step 8（Release 作成）で本文として自動抽出されるため、**ここを書き忘れると Release ノートが空になる**。

### Step 7: コミット & タグ作成

全版テストパス後、変更をコミットし、リリースタグを作成する。

```bash
PLUGIN_VERSION=$(grep "^version" kong-plugin-oidc-*.rockspec | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "Plugin: $PLUGIN_VERSION"
echo "Supported Kong: $(grep -v '^#' .kong-versions | grep -v '^$' | tr '\n' ' ')"
```

git タグは既存と重複しないことを確認:
```bash
git tag -l "v${PLUGIN_VERSION}"  # 何も出ない=OK
```

コミット & タグ:
```bash
git add -A
git commit -m "build: <変更内容のサマリ>"
git tag "v${PLUGIN_VERSION}"
```

### Step 8: push して CD をトリガー

ユーザーに確認の上、push する。CD ワークフロー (`prepare → build-and-push (matrix) → tag-latest → github-release`) が走る:

```bash
git push origin main
git push origin "v${PLUGIN_VERSION}"
```

CD が自動で行うこと:
- `.kong-versions` の各版を並列ビルドし `kong-<ver>-<plugin>` タグで GHCR に push
- 最新 Kong 版を `:latest` として retag
- **CHANGELOG.md の `## [X.Y.Z]` セクションを抽出して GitHub Release を自動作成**（`github-release` ジョブ）

### Step 9: 確認

```bash
gh run list --workflow=cd.yml --limit=1
gh release view "v${PLUGIN_VERSION}"  # Release が作成されているか確認
```

CD が古く `github-release` ジョブが無い場合は手動で Release を作成する:
```bash
awk -v ver="$PLUGIN_VERSION" '
  $0 ~ "^## \\[" ver "\\]" { found=1; next }
  found && /^## \[/ { exit }
  found { print }
' CHANGELOG.md > /tmp/notes.md
gh release create "v${PLUGIN_VERSION}" --title "v${PLUGIN_VERSION}" --notes-file /tmp/notes.md
gh release edit "v${PLUGIN_VERSION}" --latest
```

## 重要なルール

- **push の前に必ずユーザー確認**: Step 8 の push は必ずユーザーの承認を得てから実行する
- **CHANGELOG を必ず更新する**: Step 6 で CHANGELOG.md を更新しないと Release ノートが空になり、後から手当てが必要になる
- **`.kong-versions` 全版で全テストパスが前提**: 1 版でも失敗したらリリースしない（ビルド成功だけでは不十分）
- **バージョンの一貫性**: rockspec ファイル名・version フィールド・handler.lua VERSION・Dockerfile 参照・CLAUDE.md・README.md のタグ例が全て一致すること
- **既存 git タグは再利用しない**: 同じ `vX.Y.Z` を使い回すと CD が動かない／履歴が壊れる
- **alpha/beta/rc は除外**: 安定版リリースのみを対象にする
- **ポート競合の事前チェック**: テスト前に既存の docker compose 環境を停止する
- **`while read` ループでは FD 3 を使う**: ループ本体で `docker compose` 等を呼ぶと stdin を消費するので `while read ... <&3; do ... done 3< file` パターンが必須（`spec/run-all-versions.sh` 参照）
- **`.kong-versions` パース時は改行を保持する**: `tr -d '[:space:]'` は改行ごと削除して全バージョンを 1 文字列に連結してしまう（過去事故あり）。行ごとに処理する `sed -e 's/#.*$//' -e 's/[[:space:]]//g' .kong-versions | grep .` パターンを使う（CD ワークフロー / `spec/run-all-versions.sh` 参照）
