#!/bin/bash
# shellcheck shell=bash

# 兼容桥接层（迁移第 3/4 步）：原 lib/common.sh 全部函数与常量已迁至
# lib/common/ 六件套 + lib/common/install.sh（安装事务框架）；
# APK 下载器公共层随 PHP 构建线迁至 lib/php/common/build.sh。
# 本文件仅保留 source 转发以维持旧加载链可用；新加载链稳定后（第 6 步）整文件删除。
# 加载序即需求文档 §七 的全局公共顺序：env → log → paths → ports → docker → config（→ install 事务框架）
source "$(dirname "${BASH_SOURCE[0]}")/common/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/common/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/common/paths.sh"
source "$(dirname "${BASH_SOURCE[0]}")/common/ports.sh"
source "$(dirname "${BASH_SOURCE[0]}")/common/docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/common/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/common/install.sh"
# cmd_list（全局服务清单）住在 lib/cli.sh；旧加载链必须一并桥接，否则 phpbox list 失效
source "$(dirname "${BASH_SOURCE[0]}")/cli.sh"
