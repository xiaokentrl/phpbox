#!/bin/bash
# shellcheck shell=bash

# MySQL 镜像离线事务的薄绑定层：公共实现已上移 lib/common/docker.sh 的
# _ensure_offline_image（官方二进制镜像服务共用），本文件只绑定 mysql 线的常量。
# 保留本文件（而非直接在 install.sh 里调公共函数）是为了版本目录结构对称：
# 每条服务线的离线事务都住 common/offline.sh，公共层演化时各线只改绑定
_mysql_ensure_image() {
  local ver=$1 mode="${2:-install}"
  _ensure_offline_image "mysql" "$ver" "mysql:$ver" "$mode"
}
