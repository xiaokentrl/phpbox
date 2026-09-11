#!/bin/bash
# shellcheck shell=bash

# MySQL 镜像离线事务层：安装前优先从 offline/mysql/<版本>/ 命中镜像 tar（零网络 docker load），
# 未命中时 docker pull 后回写离线库（拉取成功即视为可用——官方二进制镜像没有"编译验证"环节，
# 容器健康检查（mysqladmin ping）承担运行验证）。
# 与 PHP 线 offline/ 契约对齐（AGENTS.md §2.1.1）：offline/ 只收"验证过"的内容；
# 差异点在于 MySQL 的验证是"拉取成功 + 容器健康"，而非 PHP 的"镜像构建 + 扩展编译"。
# 依赖方向：本文件 → lib/common 的 log/error/run_compose；被 lib/mysql/common/install.sh 调用

# 离线库路径：offline/mysql/<版本>/mysql-<版本>.tar
_mysql_offline_image_path() {
  local ver=$1
  echo "$OFFLINE_DIR/mysql/$ver/mysql-$ver.tar"
}

# 镜像 tag 到 tar 的读写入口。stdout 输出镜像名（mysql:<版本>），进度走 stderr
# 返回：命中加载成功 / 拉取成功 → 0；失败 → error 退出
# 参数 $2：install=安装时拉取并回写离线库；preload=仅拉取不回写（预下载场景）
_mysql_ensure_image() {
  local ver=$1 mode="${2:-install}"
  local image="mysql:$ver"
  local tar_path; tar_path=$(_mysql_offline_image_path "$ver")

  if docker image inspect "$image" &>/dev/null; then
    log "mysql:$ver 镜像已存在，跳过获取"
    echo "$image"
    return 0
  fi

  if [ -f "$tar_path" ]; then
    log "mysql 离线命中: $tar_path（零网络 docker load）"
    if ! docker load -i "$tar_path" 2>&1 | sed 's/^/  /' >&2; then
      error "mysql 离线镜像加载失败: $tar_path（文件可能损坏，可删除后重试在线拉取）"
    fi
    # load 成功但镜像名不匹配是异常状态（tar 内容被换过/版本目录错放），必须拦下：
    # 让安装继续走下去会在 up 时按 yml 里的 image: mysql:<版本> 重新联网拉取，静默绕过离线契约
    if ! docker image inspect "$image" &>/dev/null; then
      error "mysql 离线镜像加载后未找到 $image（tar 内容与版本目录不匹配）"
    fi
    echo "$image"
    return 0
  fi

  log "mysql 离线库未命中，在线拉取 mysql:$ver ..."
  if ! timeout 600 docker pull "$image" >&2; then
    error "mysql:$ver 拉取失败（检查网络；或手动放置镜像 tar 到 $tar_path 后重试）"
  fi

  if [ "$mode" = "install" ]; then
    _mysql_save_image_to_offline "$image" "$tar_path"
  else
    log "预下载模式：不回写离线库（仅确认镜像可用）"
  fi
  echo "$image"
}

# 拉取成功后回写离线库：临时文件 + 校验 + 原子替换（对齐 offline/ 事务纪律：
# 失败绝不留下半成品 tar）
_mysql_save_image_to_offline() {
  local image=$1 tar_path=$2
  local dir; dir=$(dirname "$tar_path")
  local tmp="${tar_path}.tmp.$$"
  mkdir -p "$dir"
  log "回写 mysql 镜像到离线库: $tar_path ..."
  if ! timeout 600 docker save "$image" -o "$tmp" >&2; then
    rm -f "$tmp"
    log "警告：docker save 失败，本次不回写离线库（安装不受影响）"
    return 0
  fi
  # tar 可读性校验：save 中途被杀会留截断文件，load 时的报错信息很深，
  # 提前在这里拦下并清理
  if ! timeout 120 tar -tf "$tmp" &>/dev/null; then
    rm -f "$tmp"
    log "警告：镜像 tar 校验失败，已丢弃（安装不受影响）"
    return 0
  fi
  if ! mv "$tmp" "$tar_path"; then
    rm -f "$tmp"
    log "警告：离线库写入失败（$tar_path），已清理临时文件"
    return 0
  fi
  local size; size=$(du -h "$tar_path" | cut -f1)
  log "已验证入离线库: $tar_path（$size）"
}
