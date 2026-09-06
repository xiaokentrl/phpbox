#!/bin/bash
# shellcheck shell=bash

# 把路径规整为绝对路径（消解 ../ 与符号链接）；-m 允许目标尚不存在；无 realpath 命令时退回 python3
_get_abs_path() {
  local path=$1
  if command -v realpath &>/dev/null && realpath -m "$path" &>/dev/null; then
    realpath -m "$path"
  else
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$path" 2>/dev/null || echo "$path"
  fi
}

# 停止某类服务所有运行中的容器并记录（备份/恢复期间保证数据一致性，结束后自动重启）
PHPBOX_STOPPED=()
_phpbox_stop_svc() {
  local svc=$1 f ver cname
  for f in "$EXT_DIR"/${svc}-*.yml; do
    [ -f "$f" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    ver=$(basename "$f" .yml | sed "s/${svc}-//")
    cname=$(get_container_name "$svc" "$ver")
    if docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q '^true$'; then
      docker stop "$cname" >/dev/null 2>&1 || true
      PHPBOX_STOPPED+=("$cname")
    fi
  done
}

_phpbox_start_stopped() {
  local cname
  # ${arr[@]:-}：数组可能为空，给空默认值防止旧版 bash 在 set -u 下报 unbound variable
  for cname in "${PHPBOX_STOPPED[@]:-}"; do
    [ -n "$cname" ] && docker start "$cname" >/dev/null 2>&1 || true
  done
}

cmd_backup() {
  require_docker
  local timestamp=$(date +%Y-%m-%d${BACKUP_NAME_SEPARATOR}%H-%M)
  local f="$BACKUP_DIR/backup${timestamp}.tar.gz"
  local tmpd=$(mktemp -d)
  local vol_files=()
  PHPBOX_STOPPED=()

  # 无论成功、失败还是中途打断，退出时都会清理临时目录/散落的卷 tar，并重启被暂停的服务
  trap 'rm -rf "$tmpd"; for vf in "${vol_files[@]}"; do rm -f "$BASE_DIR/$vf"; done; _phpbox_start_stopped' EXIT

  log "备份进行中..."
  log "暂停 MySQL/Redis 容器以保证数据一致性..."
  _phpbox_stop_svc mysql
  _phpbox_stop_svc redis

  # 备份 Docker 命名卷（目前只有 Redis 使用）
  # -d ''：按 NUL 字符分隔逐条读取（配合管道里 tr '\n' '\0'），卷名含空格等特殊字符也不会读错
  while IFS= read -r -d '' vol; do
    docker run --rm -v "$vol":/source:ro -v "$tmpd":/backup alpine tar czf "/backup/${vol}.tar.gz" -C /source .
  done < <(docker volume ls --filter "label=${PROJECT_NAME}.backup=true" --format '{{.Name}}' | tr '\n' '\0' || true)

  local backup_items=()
  backup_items+=("$ENV_FILE")
  backup_items+=("$CONFIG_DIR")
  # PHP 扩展清单已随 config/php/<版本>/ 一起备份，恢复后不会丢失扩展元数据
  # OFFLINE_DIR 是 pecl 源码包与 apk 依赖闭包的离线备份库，带走它换机后构建零下载
  if [ -d "$OFFLINE_DIR" ]; then
    backup_items+=("$OFFLINE_DIR")
  fi
  if [ -d "$WWW_ROOT" ]; then
    backup_items+=("$WWW_ROOT")
  fi
  # 增加 MySQL 数据目录（宿主机路径）
  if [ -d "$MYSQL_DATA_ROOT" ]; then
    backup_items+=("$MYSQL_DATA_ROOT")
  fi

  for vf in "$tmpd"/*.tar.gz; do
    [ -f "$vf" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
    cp "$vf" "$BASE_DIR/"
    vol_files+=("$(basename "$vf")")
    backup_items+=("$BASE_DIR/$(basename "$vf")")
  done

  # ${item#/} 去掉路径开头的 /：让 tar 以"相对根目录"的路径存档，恢复时配合 (cd /) 按绝对路径还原
  (cd / && tar -czf "$f" "${backup_items[@]#/}") || error "备份打包失败"

  rm -rf "$tmpd"
  for vf in "${vol_files[@]}"; do
    rm -f "$BASE_DIR/$vf"
  done
  _phpbox_start_stopped
  trap - EXIT

  success "备份完成: $f"
}

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

cmd_restore() {
  local f="$1"
  local auto_yes=false
  [ "${2:-}" == "-y" ] && auto_yes=true
  [ -f "$f" ] || error "备份文件不存在: $f"

  local content=$(tar -tzf "$f" | head -n 20)
  if ! $auto_yes; then
    echo -e "${YELLOW}恢复操作将覆盖以下路径（相对根目录）：${NC}"
    echo "$content" | sed 's/^/  /'
    if [[ -t 0 ]]; then
      read -p "确认恢复到原始绝对路径？(y/N): " ans
      [[ "$ans" != "y" && "$ans" != "Y" ]] && error "已取消恢复"
    else
      error "非交互模式，请使用 -y 参数确认"
    fi
  fi

  local vol_files=()
  mapfile -t vol_files < <(_restore_list_vol_files "$f")

  _restore_collect_invalid_paths "$f"
  if [ ${#RESTORE_INVALID_PATHS[@]} -gt 0 ]; then
    error "归档包含非法路径: ${RESTORE_INVALID_PATHS[*]}"
  fi

  # 路径校验先行（安全检查不依赖 daemon），通过后再要求 daemon 用于停服/恢复卷
  require_docker

  log "停止 MySQL/Redis 容器以便安全恢复..."
  PHPBOX_STOPPED=()
  trap '_phpbox_start_stopped' EXIT
  _phpbox_stop_svc mysql
  _phpbox_stop_svc redis

  log "恢复备份..."
  (cd / && tar -xzPf "$f" --no-same-owner --no-same-permissions)

  _restore_volumes "$auto_yes" "${vol_files[@]}"

  _phpbox_start_stopped

  # 恢复的站点配置需重载 nginx 才能生效；失败通常意味着归档中的配置有问题
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx'; then
    if docker exec nginx nginx -s reload >/dev/null 2>&1; then
      success "Nginx 已重载，站点配置生效"
    else
      log "警告：Nginx 重载失败，请执行 'phpbox nginx reload' 检查配置"
    fi
  fi
  trap - EXIT
  success "恢复完成，已自动重启被暂停的服务"
  log "提示：若恢复的 .env 中端口等配置与运行中的容器不一致，请重跑对应服务 install（或 up -d --force-recreate）使其生效"
}
