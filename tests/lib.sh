#!/bin/bash
# tests/lib.sh — 行为测试共享脚手架（供 tests/*.sh source，自身不可执行）
# 约定（见各行为测试头部）：
#   test_init_sandbox   创建沙箱 + fakebin 并注入 PATH，登记退出清理，初始化计数器
#   ok / bad            断言计数（全局 pass/fail 由本库维护）
#   test_summary <标签> 输出结果行并按失败数决定退出码
# 克制边界：只共享脚手架，不合并各测试假替身的行为差异——假 docker/curl 的场景语义
#   （状态记忆、挂载解析）各测试保留自建，强行统一会让测试更难读

# 防呆：本文件被直接执行时拒绝（应为 source）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "tests/lib.sh 是共享库，请 source 使用，不要直接执行" >&2
  exit 1
fi

pass=0
fail=0

ok() {
  echo "PASS: $*"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL: $*" >&2
  fail=$((fail + 1))
}

# 沙箱：$TEST_BOX 根目录 + fakebin 已注入 PATH 前列；清理统一挂 EXIT trap。
# 调用方若需追加清理逻辑，把函数名追加进 TEST_EXTRA_CLEANUP 数组即可
TEST_BOX=""
TEST_EXTRA_CLEANUP=()

test_init_sandbox() {
  TEST_BOX=$(mktemp -d)
  mkdir -p "$TEST_BOX/fakebin"
  export PATH="$TEST_BOX/fakebin:$PATH"
  trap 'test_cleanup_sandbox' EXIT
}

test_cleanup_sandbox() {
  local fn
  for fn in "${TEST_EXTRA_CLEANUP[@]:-}"; do
    [ -n "$fn" ] && "$fn" >/dev/null 2>&1
  done
  [ -n "$TEST_BOX" ] && rm -rf "$TEST_BOX"
}

test_summary() {
  echo "----------------------------------------"
  echo "$1: PASS=$pass FAIL=$fail"
  [ $fail -eq 0 ] || exit 1
}
