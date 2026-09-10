#!/bin/bash
# shellcheck shell=bash

# 兼容桥接层（迁移第 3/4 步）：本文件函数已全部迁至 lib/redis/ 分层结构，
# 仅保留 source 转发以维持旧加载链可用；新加载链稳定后（第 6 步）整文件删除。
# 注意：桥接期间禁止在此文件再新增函数——tests/functions.sh 的重复定义断言会拦截。
source "$(dirname "${BASH_SOURCE[0]}")/redis/common/install.sh"
source "$(dirname "${BASH_SOURCE[0]}")/redis/common/port.sh"
source "$(dirname "${BASH_SOURCE[0]}")/redis/common/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/redis/cli.sh"
