#!/bin/bash
# CLI 冒烟测试：每完成一个迁移切片后运行，验证 phpbox 入口可用、命令路由正常、
# 环境加载不报错。分两档，环境不足自动降级并明确输出 SKIPPED：
#   档 1 纯本地（不需要 Docker）：help / hosts list / site list
#   档 2 真实 Docker（daemon 在运行时）：list / php list / mysql list / redis list
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0; skip=0
ok()   { echo "PASS: $*"; pass=$((pass+1)); }
bad()  { echo "FAIL: $*" >&2; fail=$((fail+1)); }
skip() { echo "SKIPPED: $*" >&2; skip=$((skip+1)); }

# 档 1：不依赖 Docker 的命令
run() {  # run <描述> <期望含于输出的标记> <命令...>
  local desc=$1 marker=$2; shift 2
  local out
  out=$(bin/phpbox "$@" 2>&1) || { bad "$desc（退出码非零）: $out"; return; }
  grep -q "$marker" <<<"$out" || { bad "$desc（输出缺少标记 '$marker'）: $out"; return; }
  ok "$desc"
}

run_err() {  # run_err <描述> <期望含于输出的标记> <命令...>：期望失败且输出含标记
  local desc=$1 marker=$2; shift 2
  local out rc=0
  out=$(bin/phpbox "$@" 2>&1) || rc=$?
  [ $rc -ne 0 ] || { bad "$desc（应失败但退出码为 0）: $out"; return; }
  grep -q "$marker" <<<"$out" || { bad "$desc（输出缺少标记 '$marker'）: $out"; return; }
  ok "$desc"
}

run "help 命令"          "多版本 Docker 开发环境管理"  help
run "hosts list 命令"    "hosts 状态"                  hosts list
run "site list 命令"     "站点列表"                    site list
run_err "未知命令报错"   "未知命令"                    definitely-not-a-command

# 档 2：依赖 Docker daemon 的命令
if command -v docker &>/dev/null && docker info &>/dev/null; then
  run "list 命令"         "phpbox"      list
  run "php list 命令"     "已安装 PHP 版本"   php list
  run "mysql list 命令"   "已安装 MySQL 版本" mysql list
  run "redis list 命令"   "已安装 Redis 版本" redis list
  run "pgsql list 命令"   "已安装 PostgreSQL 版本" pgsql list
  # APK 下载器脚本（优化切片 B 实体化）：用其实际运行解释器 busybox sh 做语法门禁——
  # bash -n 与 busybox 语法面不完全重合，且顺带验证只读挂载路径成立
  if timeout 60 docker run --rm \
      -v "$PWD/lib/php/common/apk-fetch.container.sh":/apk-fetch.sh:ro \
      alpine sh -n /apk-fetch.sh >/dev/null 2>&1; then
    ok "APK 下载器脚本 busybox sh -n"
  else
    bad "APK 下载器脚本 busybox sh -n（挂载或语法失败）"
  fi
else
  skip "Docker daemon 不在运行，list 系列命令未验证"
fi

echo "----------------------------------------"
echo "冒烟结果: PASS=$pass FAIL=$fail SKIPPED=$skip"
[ $fail -eq 0 ] || exit 1
