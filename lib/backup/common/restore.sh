#!/bin/bash
# shellcheck shell=bash
# 恢复校验与数据卷恢复（搬运自 lib/backup.sh，纯迁移无逻辑改动）

# 扫描归档中需要恢复的 Docker 卷 tar 文件（stdout 输出 basename 列表）
_restore_list_vol_files() {
  local line
  while IFS= read -r line; do
    # 归档内条目形如 home/user/phpbox/phpbox_redis74_data.tar.gz；按项目名前缀识别卷备份
    if [[ "$line" =~ ${PROJECT_NAME}_.*\.tar\.gz$ ]]; then
      basename "$line"
    fi
  done < <(tar -tzf "$1")
}

# 校验归档成员路径：拒绝任何含 .. 的条目；只允许落在 BASE_DIR/WWW_ROOT/MYSQL_DATA_ROOT 内。
# 结果写入全局数组 RESTORE_INVALID_PATHS
_restore_collect_invalid_paths() {
  local f=$1
  RESTORE_INVALID_PATHS=()
  local path abs_path
  while IFS= read -r path; do
    # 先拒绝任何包含 .. 的路径（文件或目录），目录条目不得绕过该检查
    if [[ "$path" == *".."* ]]; then
      RESTORE_INVALID_PATHS+=("$path")
      continue
    fi
    # 再跳过目录条目（tar 归档必然包含父目录，如 home/、home/user/）
    [[ "$path" == */ ]] && continue
    if [[ "$path" == /* ]]; then
      abs_path=$(_get_abs_path "$path")
    else
      abs_path=$(_get_abs_path "/$path")
    fi
    if [[ "$abs_path" != "$BASE_DIR"/* && "$abs_path" != "$BASE_DIR" && \
        "$abs_path" != "$WWW_ROOT"/* && "$abs_path" != "$WWW_ROOT" && \
        "$abs_path" != "$MYSQL_DATA_ROOT"/* && "$abs_path" != "$MYSQL_DATA_ROOT" ]]; then
      RESTORE_INVALID_PATHS+=("$path")
    fi
  done < <(tar -tzf "$f")
}

# 恢复归档内的 Docker 卷 tar；覆盖询问仅在交互终端出现
_restore_volumes() {
  local auto_yes=$1
  shift
  local vf vname confirm
  for vf in "$@"; do
    vname=$(basename "$vf" .tar.gz)
    log "恢复卷: $vname"
    if ! $auto_yes && [[ -t 0 ]]; then   # [[ -t 0 ]]：连着终端才提问；-y 或脚本环境直接覆盖
      read -p "覆盖卷 ${vname}? (y/N): " confirm
      [[ "$confirm" != "y" ]] && { log "跳过"; continue; }
    fi
    docker volume create "$vname" &>/dev/null || true
    docker run --rm -v "$vname":/target -v "$BASE_DIR":/backup alpine tar xzPf "/backup/$vf" -C /target --no-same-owner --no-same-permissions
    rm -f "$BASE_DIR/$vf"
  done
}
