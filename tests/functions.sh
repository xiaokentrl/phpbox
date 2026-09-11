#!/bin/bash
# 函数清单断言：lib/（含子目录，迁移后形态）+ bin/phpbox 中定义的函数全集必须与
# tests/functions.baseline 完全一致。这是结构迁移"搬运不丢函数"的核对闸门——
# 纯搬运切片前后此脚本必须绿；新增/删除真实函数时先改基线再动代码，并在提交说明里写明。
# 基线由脚本生成（勿手写）：
#   { find lib -name '*.sh' -type f | sort; echo bin/phpbox; } | xargs grep -hoE \
#     '^[_a-zA-Z][_a-zA-Z0-9]*[[:space:]]*\(\)' | sed -E 's/[[:space:]]*\(\)$//' | sort -u
set -uo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }

# 收集当前函数定义（lib/ 全部 shell 文件；迁移第 6 步后已无平铺桥，仅剩分层文件与 cli.sh）
current_file=$(mktemp)
{ find lib -name '*.sh' -type f | sort; echo bin/phpbox; } |
  xargs grep -hoE '^[_a-zA-Z][_a-zA-Z0-9]*[[:space:]]*\(\)' |
  sed -E 's/[[:space:]]*\(\)$//' | LC_ALL=C sort -u > "$current_file"
current=$(cat "$current_file")

# 双向核对：基线有而代码丢 = 搬运丢函数（更危险，曾真实发生）；代码有而基线无 = 未登记的新增
missing=$(comm -13 "$current_file" <(LC_ALL=C sort tests/functions.baseline) | head -20)
[ -z "$missing" ] || { rm -f "$current_file"; fail "以下函数已丢失（搬运遗漏或误删，请对照 .github/prompts/lib-restructure.prompt.md 附录 A 找回）:
$missing"; }
added=$(comm -23 "$current_file" <(LC_ALL=C sort tests/functions.baseline) | head -20)
[ -z "$added" ] || { rm -f "$current_file"; fail "以下函数不在基线中（若为真实新增，请按脚本头注释更新基线并在提交说明写明）:
$added"; }

# 重复定义 = 兼容桥期间最危险的隐患：同名函数静默覆盖，调用到旧实现
dupes=$(uniq -d < "$current_file")
rm -f "$current_file"
[ -z "$dupes" ] || fail "重复定义的函数（新旧结构同名共存，先删旧再切新）:
$dupes"

echo "OK: 函数清单与基线一致（$(echo "$current" | wc -l) 个函数）"
