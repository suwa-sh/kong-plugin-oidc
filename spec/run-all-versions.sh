#!/usr/bin/env bash
# サポートする全 Kong バージョンに対して integration + e2e テストを実行
# 入力: .kong-versions（リポジトリルート）
# 用途: 新しい Kong バージョンを採用する前のローカル動作確認
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS_FILE="$REPO_ROOT/.kong-versions"

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: $VERSIONS_FILE not found" >&2
  exit 1
fi

declare -a RESULTS
OVERALL=0

while IFS= read -r ver <&3; do
  # コメント行と空行をスキップ
  ver="${ver%%#*}"
  ver="$(echo "$ver" | tr -d '[:space:]')"
  [ -z "$ver" ] && continue

  echo ""
  echo "============================================================"
  echo "  Kong $ver"
  echo "============================================================"

  export KONG_VERSION="$ver"

  # 既存の compose 環境をクリーンアップ（ポート競合防止）
  docker compose -f "$REPO_ROOT/spec/integration/docker-compose.test.yml" down > /dev/null 2>&1
  docker compose -f "$REPO_ROOT/spec/e2e/docker-compose.e2e.yml" down > /dev/null 2>&1

  status="OK"
  if ! bash "$REPO_ROOT/spec/integration/run-tests.sh"; then
    status="integration FAILED"
    OVERALL=1
  elif ! bash "$REPO_ROOT/spec/e2e/run-e2e.sh"; then
    status="e2e FAILED"
    OVERALL=1
  fi
  RESULTS+=("$ver: $status")
done 3< "$VERSIONS_FILE"

echo ""
echo "============================================================"
echo "  Summary"
echo "============================================================"
printf '%s\n' "${RESULTS[@]}"

exit "$OVERALL"
