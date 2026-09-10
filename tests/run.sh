#!/bin/bash
# 测试总入口（AGENTS.md §8 约定名）：lint → 函数清单断言 → 冒烟。
# 退出码非零 = 存在失败；SKIPPED 不算失败但必须显式输出，不得声称通过。
set -uo pipefail
cd "$(dirname "$0")/.."

rc=0
echo "==== [1/3] 语法检查 (tests/lint.sh) ===="
bash tests/lint.sh || rc=1

echo "==== [2/3] 函数清单断言 (tests/functions.sh) ===="
bash tests/functions.sh || rc=1

echo "==== [3/3] CLI 冒烟 (tests/smoke.sh) ===="
bash tests/smoke.sh || rc=1

if [ $rc -eq 0 ]; then echo "==== tests/run.sh 全部通过 ===="
else echo "==== tests/run.sh 存在失败项 ====" >&2; fi
exit $rc
