#!/usr/bin/env bash
# collate-changelog.sh — 把 changelog.d/*.org 收攏成 CHANGELOG.org 頂端
# 一個新的 "* vX.Y.Z" 段落，然後刪掉那些 fragment。
#
# 用法：
#   scripts/collate-changelog.sh <version>        # 例：0.40.1
#
# 設計見 docs/versioning-policy.md。本腳本是「merge 進 main 時由整合者
# 執行」的 release 動作之一；另兩個是：對 merge commit 打 annotated tag
# vX.Y.Z、更新根目錄 VERSION。
#
# 注意：本腳本只改 working tree（CHANGELOG.org + 刪 fragment），不自己
# git add / commit / tag —— 留給整合者檢查後再決定怎麼進版控。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER="${1:-}"
if [ -z "$VER" ]; then
  echo "用法: scripts/collate-changelog.sh <version>   例：0.40.1" >&2
  exit 1
fi

FRAGDIR="changelog.d"
CHANGELOG="CHANGELOG.org"
DATE="$(date +%F)"

if [ ! -f "$CHANGELOG" ]; then
  echo "✗ 找不到 $CHANGELOG" >&2
  exit 1
fi

# 收集 fragment（排除 README.org），依檔名排序求 deterministic 輸出。
shopt -s nullglob
frags=()
for f in "$FRAGDIR"/*.org; do
  [ "$(basename "$f")" = "README.org" ] && continue
  frags+=("$f")
done
if [ "${#frags[@]}" -eq 0 ]; then
  echo "✗ $FRAGDIR/ 內沒有 fragment，沒東西可收攏" >&2
  exit 1
fi
IFS=$'\n' frags=($(printf '%s\n' "${frags[@]}" | sort)); unset IFS

echo "→ 收攏 ${#frags[@]} 個 fragment 成 * v${VER} (${DATE})："
printf '   - %s\n' "${frags[@]}"

# 組出新段落到暫存檔。
SECTION="$(mktemp)"
trap 'rm -f "$SECTION" "$OUT"' EXIT
{
  echo "* v${VER} — release ${DATE}"
  echo ":PROPERTIES:"
  echo ":DATE: ${DATE}"
  echo ":END:"
  echo
  for f in "${frags[@]}"; do
    cat "$f"
    # 確保 fragment 之間有空行分隔
    echo
  done
} > "$SECTION"

# 把新段落插在第一個欄位 0 的 "* " release 標題之前；若沒有任何 "* "
# 標題（空 CHANGELOG）則附在檔尾。
OUT="$(mktemp)"
awk -v insfile="$SECTION" '
  function dump(   line) { while ((getline line < insfile) > 0) print line; close(insfile) }
  !done && /^\* / { dump(); done=1 }
  { print }
  END { if (!done) { print ""; dump() } }
' "$CHANGELOG" > "$OUT"
mv "$OUT" "$CHANGELOG"
trap 'rm -f "$SECTION"' EXIT

# 刪掉已收攏的 fragment。
for f in "${frags[@]}"; do
  rm -f "$f"
done

echo "✓ 已寫入 $CHANGELOG 頂端、刪掉 ${#frags[@]} 個 fragment。"
echo "  下一步（整合者手動）：更新 VERSION=${VER}、git add、打 tag v${VER}。"
