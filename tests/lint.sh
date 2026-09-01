#!/bin/bash
# 代码体检门禁：语法 + 嵌套深度 + 函数长度（shellcheck 若已安装则一并执行）。
# 深度规则：2 空格 = 1 层，允许到 4 层（参数解析循环的结构性深度），≥5 层失败；
# 续行符（\）的折行不算嵌套。长度规则：单个函数 > 60 行失败。
# 用法: bash tests/lint.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=("$ROOT/bin/phpbox" "$ROOT"/lib/*.sh)
DEPTH_MAX_SPACES=8   # 8 空格 = 4 层
FUNC_MAX_LINES=60
FAIL=0

for f in "${FILES[@]}"; do
  bash -n "$f" || { echo "语法错误: $f"; FAIL=1; }
done

echo "== 嵌套深度（上限 $((DEPTH_MAX_SPACES / 2)) 层）=="
for f in "${FILES[@]}"; do
  awk -v file="$(basename "$f")" -v limit="$DEPTH_MAX_SPACES" '
    /^[[:space:]]*($|#)/ {next}
    { n = match($0, /[^[:space:]]/); ind = n-1
      if (ind > max) { max = ind; line = NR; txt = substr($0, n, 44) } }
    END {
      printf "%-14s 最深 %d 层", file, max/2
      if (max > limit) { printf "  ← 超限（第 %d 行: %s）", line, txt; exit 1 }
      print ""
    }' "$f" || FAIL=1
done

echo "== 函数长度（上限 ${FUNC_MAX_LINES} 行）=="
LONG=$(awk -v limit="$FUNC_MAX_LINES" '
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { name=$0; sub(/[[:space:]]*\(\).*/,"",name); start=FNR }
  /^\}/ && name { if (FNR-start+1 > limit) printf "  %s:%d  %s  %d 行 ← 超限\n", FILENAME, start, name, FNR-start+1; name="" }
' "${FILES[@]}")
if [ -n "$LONG" ]; then
  echo "$LONG"
  FAIL=1
else
  echo "  全部 ≤ ${FUNC_MAX_LINES} 行"
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck "${FILES[@]}" || FAIL=1
else
  echo "== shellcheck 未安装，跳过（建议安装以增强静态检查）=="
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "lint 通过"
else
  echo "lint 未通过"
fi
exit "$FAIL"
