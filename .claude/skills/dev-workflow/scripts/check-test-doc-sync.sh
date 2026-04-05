#!/usr/bin/env bash
# テストケース一覧とドキュメントの同期チェック
# run-tests.sh --list の ID と README.md のテーブルの ID を比較する
# テスト名の表現差異は許容し、ID の過不足のみを検出する
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
README="$REPO_ROOT/spec/integration/README.md"
RUN_TESTS="$REPO_ROOT/spec/integration/run-tests.sh"

if [ ! -f "$README" ] || [ ! -f "$RUN_TESTS" ]; then
  echo "SKIP: 統合テストが存在しません"
  exit 0
fi

# --list から ID を抽出（例: "  A-01: ..." → "A-01"）
LIST_IDS=$(bash "$RUN_TESTS" --list 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | sort)

# README.md のテーブルから ID を抽出（例: "| A-01 | ..." → "A-01"）
README_IDS=$(grep -oE '[A-Z]+-[0-9]+' "$README" | sort -u)

# 比較
DIFF_OUTPUT=$(diff <(echo "$LIST_IDS") <(echo "$README_IDS") 2>&1) || true

if [ -z "$DIFF_OUTPUT" ]; then
  echo "OK: テストケース ID が同期しています ($(echo "$LIST_IDS" | wc -l | tr -d ' ')件)"
  exit 0
else
  # --list にあって README にない ID
  ONLY_IN_LIST=$(comm -23 <(echo "$LIST_IDS") <(echo "$README_IDS"))
  # README にあって --list にない ID
  ONLY_IN_README=$(comm -13 <(echo "$LIST_IDS") <(echo "$README_IDS"))

  echo "ERROR: テストケース ID が同期していません"
  if [ -n "$ONLY_IN_LIST" ]; then
    echo "  スクリプトにあり README にない: $ONLY_IN_LIST"
  fi
  if [ -n "$ONLY_IN_README" ]; then
    echo "  README にありスクリプトにない: $ONLY_IN_README"
  fi
  exit 1
fi
