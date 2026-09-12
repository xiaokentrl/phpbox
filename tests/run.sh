#!/bin/bash
# 测试总入口（AGENTS.md §8 约定名）：lint → 函数清单断言 → 冒烟 → offline-first 行为验证
# → install 顺序回归 → 镜像离线行为验证 → backup/restore 行为验证。
# 退出码非零 = 存在失败；SKIPPED 不算失败但必须显式输出，不得声称通过。
set -uo pipefail
cd "$(dirname "$0")/.."

rc=0
echo "==== [1/7] 语法检查 (tests/lint.sh) ===="
bash tests/lint.sh || rc=1

echo "==== [2/7] 函数清单断言 (tests/functions.sh) ===="
bash tests/functions.sh || rc=1

echo "==== [3/7] CLI 冒烟 (tests/smoke.sh) ===="
bash tests/smoke.sh || rc=1

echo "==== [4/7] offline-first 行为验证 (tests/offline-first.sh) ===="
bash tests/offline-first.sh || rc=1

echo "==== [5/7] install 顺序回归 (tests/install-order.sh) ===="
bash tests/install-order.sh || rc=1

echo "==== [6/7] 镜像离线行为验证 (tests/image-offline.sh) ===="
bash tests/image-offline.sh || rc=1

echo "==== [7/7] backup/restore 行为验证 (tests/backup.sh) ===="
bash tests/backup.sh || rc=1

if [ $rc -eq 0 ]; then echo "==== tests/run.sh 全部通过 ===="
else echo "==== tests/run.sh 存在失败项 ====" >&2; fi
exit $rc
