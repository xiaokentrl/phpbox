#!/bin/bash
# shellcheck shell=bash
# Go 镜像安装/卸载（搬运自 lib/go.sh，纯迁移无逻辑改动）

_go_install() {
  local requested="${1:-alpine}" image
  [ $# -le 1 ] || error "用法: phpbox go install [版本]"
  _go_resolve_version "$requested"
  image="golang:${GO_IMAGE_TAG}"
  log "开始准备 Go 镜像：${image}（超时 120s）..."
  if ! timeout 120 docker pull "$image"; then
    error "Go 镜像拉取失败：${image}，默认版本未修改"
  fi
  env_set "GO_DEFAULT_VERSION" "$requested"
  GO_DEFAULT_VERSION="$requested"
  success "Go 镜像已安装：${image}；默认版本已设为 ${requested}"
}

_go_uninstall() {
  local requested=${1:-} image container_names
  local purge=false
  [ -n "$requested" ] || error "用法: phpbox go uninstall <版本> [--purge]（最新稳定版使用 latest）"
  shift
  [ $# -le 1 ] || error "用法: phpbox go uninstall <版本> [--purge]"
  if [ "${1:-}" = "--purge" ]; then
    purge=true
  elif [ -n "${1:-}" ]; then
    error "未知选项: $1"
  fi

  _go_resolve_version "$requested"
  image="golang:${GO_IMAGE_TAG}"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    error "Go 镜像不存在: $image"
  fi

  container_names=$(docker ps -a --filter "ancestor=$image" --format '{{.Names}}' 2>/dev/null || true)
  if [ -n "$container_names" ]; then
    echo "Go 镜像 ${image} 仍被以下容器使用：" >&2
    printf '  %s\n' "$container_names" >&2
    error "请先执行 'phpbox go stop <项目>'，再卸载镜像"
  fi

  log "卸载 Go 镜像 ${image}..."
  if ! timeout 60 docker image rm "$image"; then
    error "Go 镜像卸载失败: $image"
  fi
  if $purge; then
    rm -rf "$GO_CACHE_ROOT/$GO_CACHE_VERSION"
    success "Go 镜像 ${image} 和缓存已卸载"
  else
    success "Go 镜像 ${image} 已卸载，缓存保留"
  fi
}
