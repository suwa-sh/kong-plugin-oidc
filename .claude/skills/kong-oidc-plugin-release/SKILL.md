---
name: kong-oidc-plugin-release
description: |
  kong-plugin-oidc の新バージョンを GHCR にリリースする統合ワークフロー。
  プラグインコード変更（機能追加・バグ修正）／Kong Gateway ベースイメージの更新／
  新しい Kong バージョンサポート追加 のいずれのシナリオでも、共通の手順
  （バージョン bump → 全サポート版でローカルテスト → CHANGELOG 更新 → タグ作成 → CD 経由で GHCR & GitHub Release 公開）
  を一貫して回す。

  以下のような指示で必ず発動すること（リリース／公開／バージョン管理に関わる文脈は積極的に拾う）:
  - 「リリースして」「v1.x.x を出して」「次のバージョンをリリース」
  - 「Kong を最新にして」「Kong の新しいバージョンが出てるか確認」「Kong バージョン更新」「docker イメージを更新」
  - 「サポートする Kong バージョンを追加」「3.x 系をサポート」
  - 「機能追加してリリース」「バグ修正をリリース」
  - 「CHANGELOG 書いて」「GHCR に公開」「GitHub Release を作成」
  - 「rockspec を bump」「プラグインバージョンを上げる」

  プラグインのリリース運用に関する判断や作業を求められたら、ベースイメージ更新だけでなく
  プラグインコード起因のリリースであっても、まずこのスキルを参照すること。
---

# kong-plugin-oidc リリースワークフロー

kong-plugin-oidc の新バージョンを GHCR / GitHub Release に公開するためのワークフロー。
ベースイメージ更新・プラグインコード変更・サポート版追加のすべてを 1 本に統合している。

## 前提（リポジトリの仕組み）

- Dockerfile: `ARG KONG_VERSION=<default>` でデフォルトベースイメージを指定（`KONG_VERSION` 未指定時のフォールバック）
- `.kong-versions`: サポートする Kong バージョン一覧。CD matrix とローカル全版テスト (`spec/run-all-versions.sh`) の入力
- compose の build args: `args.KONG_VERSION: ${KONG_VERSION:-<default>}` で外部から差し込み可能
- CD ワークフロー: `.github/workflows/cd.yml` が `v*` タグで発火。`prepare → build-and-push (matrix) → tag-latest → github-release` の 4 ジョブ
- 公開タグ: `ghcr.io/suwa-sh/kong-plugin-oidc:kong-<kong-version>-<plugin-version>` を全サポート版で push、最新 Kong 版を `:latest` として retag
- GitHub Release: CD が CHANGELOG.md の `## [X.Y.Z]` セクションを抽出して自動作成
- プラグインバージョン: `kong-plugin-oidc-X.Y.Z-1.rockspec` のファイル名と `version` フィールドが Single Source of Truth

## ワークフロー全体像

```
[シナリオ判定] → (Kong 系のみ) Kong チェック / .kong-versions 編集
              ↓
              プラグインバージョン bump（必要な場合）
              ↓
              全サポート版でローカル integration / e2e
              ↓
              CHANGELOG.md 更新
              ↓
              commit & tag & push（ユーザー承認後）
              ↓
              CD が matrix ビルド + GHCR push + Release 自動作成
              ↓
              成果物確認
```

## Step 0: シナリオ判定とバージョン方針の決定

ユーザーの依頼内容から、以下の 3 シナリオのどれに該当するかを最初に判定する。
判定が曖昧なら必ずユーザーに確認する（誤判定するとテスト範囲やバンプポリシーがズレる）。

| シナリオ | 例 | Kong 系作業 (Step 1) | bump 方針の目安 |
|---|---|:-:|---|
| **A. Kong パッチ追従のみ** | 3.11.0.8 → 3.11.0.9 | ✅ 必要 | プラグインは patch bump（互換変化なし） |
| **B. 新 Kong 版のサポート追加** | 3.12 系を追加 | ✅ 必要 | プラグインは minor bump（新サポート追加） |
| **C. プラグインコード変更** | 機能追加・バグ修正 | ❌ skip | minor (機能) / patch (修正) / major (BREAKING) |
| **D. 上記の組合せ** | コード修正＋Kong バンプ | ✅ 必要 | 変更内容で最も大きい段階を採用 |

判定後、ユーザーに「シナリオ X、プラグイン X.Y.Z でリリースしようと考えています。よいですか？」と
方針を明示してから先に進む。**既存の git タグ `vX.Y.Z` と重複しないこと**を必ず確認する。

```bash
git tag -l "v${PLUGIN_VERSION}"  # 何も出力されないこと
```

## Step 1: Kong バージョン関連の更新（シナリオ A / B / D のみ）

**シナリオ C のみの場合はこの Step を skip して Step 2 に進む。**

### 1-1. 最新 Kong バージョンの確認

`-ubuntu` サフィックスかつ `X.Y.Z.W-ubuntu` 形式の安定版のみを対象にする
（日付サフィックスやメジャー・マイナーのみの短縮タグは除外）。

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

# 現状サポート版
cat .kong-versions
```

新版がなければシナリオ A / B はここで終了（C なら Step 2 へ進む）。

### 1-2. `.kong-versions` を更新

シナリオに合わせて編集する:
- A（パッチ追従）: 既存版を新版に**置き換え**
- B（新メジャー/マイナー追加）: 既存版を残したまま新版を**追記**

```text
# サポートする Kong Gateway ベースイメージタグ一覧
# `#` で始まる行と空行は無視される
3.11.0.9-ubuntu
3.12.0.5-ubuntu
```

### 1-3. Dockerfile の `ARG KONG_VERSION=` を判断

これは「`KONG_VERSION` 未指定でビルドされたときに使う既定値」。
最新版に追従するのが基本（compose / CI でも明示的に指定するため、デフォルトを最新にしてもリスクは小さい）。
後方互換重視なら最古サポート版に据え置きでも可。

## Step 2: プラグインバージョンの bump（必要な場合）

bump する場合、**以下の全ファイルを一貫して更新する**（漏れがあるとビルドかリリースが壊れる）:

| ファイル | 更新箇所 |
|---|---|
| `kong-plugin-oidc-X.Y.Z-1.rockspec` | **ファイル名をリネーム** + `version` フィールド |
| 同 rockspec | `source.url`, `description.homepage` が正しいリポジトリを指していること |
| `kong/plugins/oidc/handler.lua` | `VERSION = "X.Y.Z"` |
| `Dockerfile` | `COPY` と `RUN luarocks make` の rockspec ファイル名参照（2 箇所） |
| `CLAUDE.md` | rockspec ファイル名の記載 |
| `README.md` | GHCR タグ例（`kong-A.B.C.D-X.Y.Z`） |
| `.github/ISSUE_TEMPLATE/bug_report.yml` | バージョン placeholder |

```bash
git mv kong-plugin-oidc-OLD-1.rockspec kong-plugin-oidc-NEW-1.rockspec
```

## Step 3: 全サポート版でローカル動作確認

**ビルド成功 ≠ 動作 OK**。`.kong-versions` の全版で integration / e2e を実行することがリリース可否の主たる根拠。

```bash
# 既存の compose 環境を停止（ポート競合防止）
docker compose -f spec/integration/docker-compose.test.yml down 2>/dev/null
docker compose -f spec/e2e/docker-compose.e2e.yml down 2>/dev/null

bash spec/run-all-versions.sh
```

ランナー（`spec/run-all-versions.sh`）の挙動:
- `.kong-versions` の各行を `KONG_VERSION` として export
- compose の build args 経由で Dockerfile に注入
- 各版で `spec/integration/run-tests.sh` と `spec/e2e/run-e2e.sh` を実行
- 末尾に `<version>: OK | FAILED` のサマリを出力

依存ツール（事前にインストール済みであること）:
- Docker Desktop
- Python 3 + `PyJWT`, `requests`, `beautifulsoup4`
  ```bash
  pip3 install --break-system-packages PyJWT requests beautifulsoup4
  ```

単一版だけ動かしたいとき:
```bash
KONG_VERSION=3.12.0.5-ubuntu bash spec/integration/run-tests.sh
KONG_VERSION=3.12.0.5-ubuntu bash spec/e2e/run-e2e.sh
```

テスト失敗時の切り分け順:
1. ポート競合や前回コンテナの残存（偽陽性の主因）
2. Kong のリリースノートで非互換変更がないか
3. プラグイン側の修正が必要ならユーザーに報告し、修正後に Step 3 からやり直す

## Step 4: CHANGELOG.md 更新

**これを忘れると GitHub Release のノートが空になる**ため、tag を打つ前に必ず実施。

`CHANGELOG.md` の冒頭近く（`## [前の版]` の上）に追加。Keep a Changelog 形式 + Semantic Versioning に従い、
変更内容を `Added` / `Changed` / `Fixed` / `BREAKING CHANGES` などで整理する。

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Fixed
- ...
```

このセクションは CD の `github-release` ジョブで `awk` により抽出されるため、
**見出しを `## [X.Y.Z] - <date>` の正確な形式で書く**こと（角括弧含む）。

## Step 5: コミット & タグ作成

全版テストパス後、変更をまとめてコミットしリリースタグを作成する。

```bash
PLUGIN_VERSION=$(grep "^version" kong-plugin-oidc-*.rockspec | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "Plugin: $PLUGIN_VERSION"
echo "Supported Kong: $(grep -v '^#' .kong-versions | grep -v '^$' | tr '\n' ' ')"

# タグ重複の最終確認
git tag -l "v${PLUGIN_VERSION}"  # 何も出ない=OK

git add -A
git commit -m "<type>: <変更内容のサマリ>"   # feat / fix / build など Conventional Commits
git tag "v${PLUGIN_VERSION}"
```

## Step 6: push して CD をトリガー（ユーザー承認後）

push は不可逆な公開アクション。**必ずユーザーに確認**してから実行する。

```bash
git push origin main
git push origin "v${PLUGIN_VERSION}"
```

CD ワークフローが自動で実施すること:
- `.kong-versions` の各版を並列ビルド → `kong-<ver>-<plugin>` タグで GHCR に push
- 最新 Kong 版を `:latest` として `buildx imagetools` で retag
- CHANGELOG.md の `## [X.Y.Z]` セクションを抽出して GitHub Release を自動作成

## Step 7: 公開結果の確認

```bash
gh run watch                                # 直近 run を監視
gh run list --workflow=cd.yml --limit=1     # 完了確認
gh release view "v${PLUGIN_VERSION}"        # Release が作成されていること
```

`github-release` ジョブが存在しない古い CD で動いた場合（履歴的事情）、
Release のみ手動で作成する:

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

- **push 前に必ずユーザー確認**: Step 6 の push は承認を得てから実行する。GHCR / Release は公開アクションで巻き戻しが面倒
- **CHANGELOG を必ず更新**: Step 4 を飛ばすと Release ノートが空になり、後追いで `gh release edit` が必要になる
- **全サポート版で全テストパスが前提**: 1 版でも失敗したらリリースしない。「ビルド成功」だけでは不十分（過去の v1.8.0 初回 push で痛感）
- **バージョン整合性**: rockspec ファイル名・`version` フィールド・handler.lua `VERSION`・Dockerfile 参照（2 箇所）・CLAUDE.md・README.md・bug_report.yml すべて一致させる
- **既存 git タグの再利用は禁止**: 同じ `vX.Y.Z` を打ち直すと CD の挙動・履歴が壊れる。bump して別タグを打つこと
- **alpha / beta / rc は除外**: Kong 安定版のみを対象にする
- **テスト前にポート競合を解消**: `docker compose ... down` を先に実行（6379 / 8000 / 8080 などが残ると偽陽性で落ちる）
- **`while read` ループは FD 3 を使う**: ループ本体で `docker compose` 等を呼ぶと stdin を消費する。`while read ... <&3; do ...; done 3< file` のパターンを必ず使う（`spec/run-all-versions.sh` 参照）
- **`.kong-versions` パース時は改行を保持する**: `tr -d '[:space:]'` は改行ごと削除し、全バージョンを 1 文字列に連結してしまう（CD matrix 展開で過去事故あり）。`sed -e 's/#.*$//' -e 's/[[:space:]]//g' .kong-versions | grep .` のように行単位で処理する（CD ワークフロー / `spec/run-all-versions.sh` 参照）
