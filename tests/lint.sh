#!/bin/bash
# 语法与结构静态检查：所有 shell 源码过 bash -n；lib 内不允许出现 Bash 保留字误用
# 导致的解析错误；迁移期间同时覆盖 lib/*.sh（旧平铺）与 lib/**/*.sh（新分层）。
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
# 全部 shell 文件：入口、安装器、lib（新旧两种形态）、tests 自身
mapfile -t files < <({ find lib install.sh bin tests -name '*.sh' -type f; echo bin/phpbox; } | sort -u)
for f in "${files[@]}"; do
  if bash -n "$f" 2>/tmp/phpbox-lint-err; then
    echo "PASS: bash -n $f"
  else
    echo "FAIL: bash -n $f" >&2
    sed 's/^/    /' /tmp/phpbox-lint-err >&2
    fail=$((fail+1))
  fi
done
rm -f /tmp/phpbox-lint-err

[ $fail -eq 0 ] && echo "lint 通过（${#files[@]} 个文件）" || { echo "lint 失败: $fail 个文件" >&2; exit 1; }
