#!/bin/bash
# shellcheck shell=bash

# PostgreSQL 镜像离线事务的薄绑定层：公共实现见 lib/common/docker.sh 的
# _ensure_offline_image，本文件只绑定 pgsql 线的常量。与 redis 同款"版本≠tag"映射：
# 镜像 tag 带 -alpine 后缀（postgres:17-alpine），离线库目录用裸版本号（offline/pgsql/17/）
_pgsql_ensure_image() {
  local ver=$1 mode="${2:-install}"
  _ensure_offline_image "pgsql" "$ver" "postgres:${ver}-alpine" "$mode"
}
