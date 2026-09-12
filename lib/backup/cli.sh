#!/bin/bash
# shellcheck shell=bash
# backup/restore 顶层命令实现（搬运自 lib/backup.sh，纯迁移无逻辑改动）
# backup 与 restore 是顶层命令（无子命令分发），故命令实现直接落在 cli.sh，
# 归属判断记录于迁移规范附录 A"树缺口判断"

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
  log "暂停 MySQL/PostgreSQL/Redis 容器以保证数据一致性..."
  _phpbox_stop_svc mysql
  _phpbox_stop_svc pgsql
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
  # 数据库数据目录（mysql/pgsql）：数据文件归容器内 uid（999/70），宿主 tar 无读权限
  # （实测 tar 退出码 2 整体失败）。与数据卷同款机制：借一次性容器以 root 只读挂载根
  # 目录打包成成员 tar（phpbox-dbdata-<服务>.tar.gz，内含相对根目录的绝对路径），
  # 随后走下方统一的收集循环进宿主归档；恢复侧同样借容器 root 解包以保留原始属主
  local db_roots=() db_entry db_src db_name
  [ -d "$MYSQL_DATA_ROOT" ] && db_roots+=("mysql:$MYSQL_DATA_ROOT")
  [ -d "$PGSQL_DATA_ROOT" ] && db_roots+=("pgsql:$PGSQL_DATA_ROOT")
  for db_entry in "${db_roots[@]:-}"; do
    [ -n "$db_entry" ] || continue
    db_src="${db_entry#*:}"
    [ -n "$(ls -A "$db_src" 2>/dev/null)" ] || continue   # 空目录无数据可备，跳过
    db_name="phpbox-dbdata-${db_entry%%:*}.tar.gz"
    log "打包 ${db_entry%%:*} 数据目录（容器内 root，保留 uid 属主）: $db_src"
    docker run --rm -v /:/host:ro -v "$tmpd":/backup alpine \
      tar czf "/backup/$db_name" -C /host "${db_src#/}"
  done

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

  log "停止 MySQL/PostgreSQL/Redis 容器以便安全恢复..."
  PHPBOX_STOPPED=()
  trap '_phpbox_start_stopped' EXIT
  _phpbox_stop_svc mysql
  _phpbox_stop_svc pgsql
  _phpbox_stop_svc redis

  log "恢复备份..."
  (cd / && tar -xzPf "$f" --no-same-owner --no-same-permissions)

  _restore_volumes "$auto_yes" "${vol_files[@]}"

  # 数据库数据目录成员 tar：宿主 tar 提取时已落回 $BASE_DIR（上面主归档解包），
  # 此处先校验成员内部路径（防越界解包），再借容器 root 解到绝对路径——root 解包
  # 保留归档内 uid（999/70），宿主解包会把数据文件变成宿主属主，服务起不来
  local db_files=() vf inner db_rel
  mapfile -t db_files < <(_restore_list_dbdata_files "$f")
  for vf in "${db_files[@]:-}"; do
    [ -n "$vf" ] || continue
    [ -f "$BASE_DIR/$vf" ] || continue
    while IFS= read -r inner; do
      [ -n "$inner" ] || continue
      if [[ "$inner" == *".."* ]]; then
        error "成员 tar $vf 含非法路径: $inner"
      fi
      if ! [[ "$inner" == "${MYSQL_DATA_ROOT#/}/"* || "$inner" == "${PGSQL_DATA_ROOT#/}/"* ]]; then
        error "成员 tar $vf 路径越界: $inner（只允许数据库数据目录内容）"
      fi
    done < <(tar -tzf "$BASE_DIR/$vf")
    log "恢复数据库数据目录: $vf（容器内 root，保留 uid 属主）"
    docker run --rm -v /:/host -v "$BASE_DIR":/backup:ro alpine \
      tar xzPf "/backup/$vf" -C /host
    rm -f "$BASE_DIR/$vf"
  done

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
