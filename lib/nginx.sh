#!/bin/bash
# shellcheck shell=bash

# 兼容桥接层（迁移第 3/4 步）：本文件函数已全部迁至 lib/nginx/ 分层结构，
# 仅保留 source 转发以维持旧加载链可用；新加载链稳定后（第 6 步）整文件删除。
# 注意：桥接期间禁止在此文件再新增函数——tests/functions.sh 的重复定义断言会拦截。
source "$(dirname "${BASH_SOURCE[0]}")/nginx/common/install.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nginx/common/reload.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nginx/common/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nginx/cli.sh"

# 【迁移暂留，php 切片时迁往 lib/php/common/config.sh】
# 此函数物理上一直定义在 nginx.sh，但语义属 php 线；它留在桥文件（而非 nginx 线
# 新结构文件）是为保证新结构文件从诞生起就不含他线逻辑，桥文件本身第 6 步会删除。
_init_php_config() {
  local dir=$1 ver=$2
  docker run --rm -v "$dir":/out "php:${ver}-fpm-alpine" \
    sh -c "cp /usr/local/etc/php/php.ini-production /out/php.ini" || {
    rm -rf "$dir"; error "PHP 配置提取失败"
  }
}
