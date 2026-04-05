---
name: kong-update
description: |
  Kong Gateway ベースイメージの更新とGHCR公開を自動化するスキル。
  Docker Hub から最新の Kong Gateway タグを取得し、Dockerfile を更新、
  ビルド・テスト検証後、git tag で CD パイプラインをトリガーして GHCR に公開する。
  「Kong を最新にして」「Kong バージョン更新」「GHCR に公開」「リリース」
  「Kong の新しいバージョンが出てるか確認」「docker イメージを更新」
  といった指示で発動する。Kong のバージョン管理やリリースに関連する指示があれば
  積極的に使用すること。
---

# Kong Gateway バージョン更新 & GHCR 公開

Kong Gateway のベースイメージを最新に更新し、検証を経て GHCR に公開するワークフロー。

## 前提

- Dockerfile: `ARG KONG_VERSION=<current>` でベースイメージを指定
- CD ワークフロー: `.github/workflows/cd.yml` が `v*` タグで GHCR に push
- GHCR タグ: `latest`, `kong-<kong-version>-<plugin-version>`
- プラグインバージョン: `kong-plugin-oidc-*.rockspec` の version フィールド

## ワークフロー

### Step 1: 最新 Kong バージョンの確認

Docker Hub API で `kong/kong-gateway` の最新タグを取得する。
`-ubuntu` サフィックスのタグ（本プロジェクトのベースイメージ形式）に絞って確認する。

日付サフィックス付きタグ（例: `3.10.0.9-20260313-ubuntu`）やメジャー・マイナーのみの
短縮タグ（例: `3.11-ubuntu`）は除外し、完全なバージョン番号のタグのみを対象にする。

```bash
# Docker Hub API でタグ一覧を取得（ubuntu 版のみ、最新順）
curl -s "https://hub.docker.com/v2/repositories/kong/kong-gateway/tags?page_size=50&ordering=last_updated" \
  | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
# 安定版の完全バージョンのみ抽出: X.Y.Z.W-ubuntu 形式
pattern = re.compile(r'^\d+\.\d+\.\d+\.\d+-ubuntu$')
tags = [t['name'] for t in data['results']
        if pattern.match(t['name'])
        and not any(x in t['name'] for x in ['alpha', 'beta', 'rc'])]
for tag in tags[:10]:
    print(tag)
"
```

現在のバージョンと比較:
```bash
CURRENT=$(grep 'KONG_VERSION=' Dockerfile | head -1 | sed 's/.*KONG_VERSION=//')
echo "Current: $CURRENT"
```

新しいバージョンがない場合はここで終了。ユーザーに「最新です」と伝える。

### Step 2: Dockerfile 更新

新しいバージョンが見つかった場合、Dockerfile の `ARG KONG_VERSION` を更新する。

```bash
# 例: 3.9.1.2-ubuntu → 3.11.0.8-ubuntu
sed -i '' "s/KONG_VERSION=.*/KONG_VERSION=$NEW_VERSION/" Dockerfile
```

### Step 3: プラグインバージョンの判断

Kong バージョンの更新に伴い、プラグインのセマンティックバージョンを判断する。

- **Kong メジャー/マイナーバージョンアップ** → プラグイン minor バンプを検討
- **Kong パッチバージョンアップのみ** → プラグインバージョン据え置き可
- **プラグインコード変更あり** → 変更内容に応じて minor（機能追加）/ patch（修正）

バージョンを変更する場合、以下の全ファイルを一貫して更新する（漏れがあるとビルドやリリースが壊れる）:

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

### Step 4: ビルド検証

更新されたベースイメージでビルドが通ることを確認する。

```bash
docker build -t kong:kong-oidc .
```

ビルドが失敗した場合:
- Kong の破壊的変更がないか確認（Kong のリリースノートを参照）
- `luarocks make` の失敗は依存ライブラリの互換性問題の可能性
- 修正が必要ならユーザーに報告して判断を仰ぐ

### Step 5: テスト検証

テスト前に、前回の docker compose 環境がポートを占有していないか確認する。
ポート競合（6379, 8000, 8080 等）があるとテストが偽陽性で失敗する。

```bash
# 残存する docker compose 環境を停止
docker compose -f spec/integration/docker-compose.test.yml down 2>/dev/null
docker compose -f spec/e2e/docker-compose.e2e.yml down 2>/dev/null
```

全テストスイートを順に実行する。いずれかが失敗したら停止してユーザーに報告する。

```bash
# 静的解析
qlty check --all
luacheck kong/

# ユニットテスト
busted spec/unit/

# 統合テスト（Docker 環境必要）
bash spec/integration/run-tests.sh

# E2E テスト（Docker + Python 必要）
bash spec/e2e/run-e2e.sh
```

テスト失敗時:
- まずポート競合や前回のコンテナ残存がないか確認（偽陽性の主因）
- 新しい Kong バージョンでの非互換がないか Kong リリースノートを確認
- プラグイン側の修正が必要ならユーザーに報告
- 修正後は Step 4 からやり直す

### Step 6: コミット & タグ作成

全検証パス後、変更をコミットし、リリースタグを作成する。

```bash
PLUGIN_VERSION=$(grep "^version" kong-plugin-oidc-*.rockspec | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
KONG_SHORT=$(grep 'KONG_VERSION=' Dockerfile | head -1 | sed 's/.*KONG_VERSION=//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?')
echo "Plugin: $PLUGIN_VERSION / Kong: $KONG_SHORT"
echo "GHCR tag: kong-${KONG_SHORT}-${PLUGIN_VERSION}"
```

コミットとタグ:
```bash
git add -A
git commit -m "build: Kong Gateway $KONG_SHORT を採用"
git tag "v${PLUGIN_VERSION}"
```

### Step 7: push してCDをトリガー

ユーザーに確認の上、push する。push すると CD ワークフローが GHCR に公開する。

```bash
git push origin main
git push origin "v${PLUGIN_VERSION}"
```

公開されるタグ:
- `ghcr.io/suwa-sh/kong-plugin-oidc:latest`
- `ghcr.io/suwa-sh/kong-plugin-oidc:kong-<kong-short>-<plugin-version>`

### Step 8: 確認

GitHub Actions の CD ワークフローの実行状況を確認する。

```bash
gh run list --workflow=cd.yml --limit=1
```

## 重要なルール

- **push の前に必ずユーザー確認**: Step 7 の push は必ずユーザーの承認を得てから実行する
- **テスト全パスが前提**: テストが1つでも失敗したらリリースしない
- **バージョンの一貫性**: rockspec ファイル名・version フィールド・handler.lua VERSION・Dockerfile 参照・CLAUDE.md・README.md のタグ例が全て一致すること
- **alpha/beta/rc は除外**: 安定版リリースのみを対象にする
- **ポート競合の事前チェック**: テスト前に既存の docker compose 環境を停止する
