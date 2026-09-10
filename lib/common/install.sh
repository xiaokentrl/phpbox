#!/bin/bash
# shellcheck shell=bash
# 安装事务生命周期与回滚框架（搬运自 lib/common.sh，纯迁移无逻辑改动）

get_or_set_password() {
  local svc=$1 ver=$2
  # 键名形如 MYSQL_84_ROOT_PASSWORD（服务名_去点版本_ROOT_PASSWORD 转大写）
  local key; key=$(echo "${svc}_${ver//./}_ROOT_PASSWORD" | tr '[:lower:]' '[:upper:]')
  local val; val=$(read_env_value "$key" "")
  if [ -z "$val" ]; then
    command -v openssl &>/dev/null || error "需要 openssl 生成密码，请先安装 openssl"
    val=$(openssl rand -hex 8)
    env_set "$key" "$val"
    success "已生成 ${svc} ${ver} 密码，保存于 .env"
  fi
  echo "$val"
}

# 安装类命令：_install_rollback_begin → 写配置/起容器 → 成功 _install_rollback_commit。
# 中途任何一步 error() 退出都会触发 EXIT trap，由 _install_rollback_run 清掉"本次新增"的
# yml/配置目录/数据目录/扩展状态文件与 .env 键——只清理本次新增的（先快照存在性），不碰历史残留
_ROLLBACK_PENDING=false
_ROLLBACK_SVC="" ; _ROLLBACK_VER=""
_ROLLBACK_CONFIG_EXISTED=false ; _ROLLBACK_DATA_EXISTED=false ; _ROLLBACK_STATE_EXISTED=false
_ROLLBACK_PORT_EXISTED=false ; _ROLLBACK_PASS_EXISTED=false

_install_rollback_begin() {
  local svc=$1 ver=$2 key
  _ROLLBACK_PENDING=true ; _ROLLBACK_SVC=$svc ; _ROLLBACK_VER=$ver
  if [ -d "$CONFIG_DIR/$svc/$ver" ]; then _ROLLBACK_CONFIG_EXISTED=true; fi
  if [ -d "$MYSQL_DATA_ROOT/$ver" ]; then _ROLLBACK_DATA_EXISTED=true; fi
  if [ -f "$PHP_CONFIG_DIR/$ver/extensions.env" ]; then _ROLLBACK_STATE_EXISTED=true; fi
  key=$(port_key "$svc" "$ver")
  if [ -n "$(read_env_value "$key" "")" ]; then _ROLLBACK_PORT_EXISTED=true; fi
  key="${svc^^}_${ver//./}_ROOT_PASSWORD"
  if [ -n "$(read_env_value "$key" "")" ]; then _ROLLBACK_PASS_EXISTED=true; fi
}

_install_rollback_commit() { _ROLLBACK_PENDING=false; }

_install_rollback_run() {
  $_ROLLBACK_PENDING || return 0
  local svc=$_ROLLBACK_SVC ver=$_ROLLBACK_VER key
  log "安装失败，自动清理 ${svc} ${ver} 的半安装状态..."
  rm -f "$EXT_DIR/${svc}-${ver}.yml"
  if ! $_ROLLBACK_CONFIG_EXISTED; then rm -rf "$CONFIG_DIR/$svc/$ver"; fi
  case "$svc" in
    mysql)
      if ! $_ROLLBACK_DATA_EXISTED; then _rm_rf_with_docker_fallback "$MYSQL_DATA_ROOT/$ver"; fi ;;
    redis)
      docker volume rm -f "$(get_volume_name redis "$ver")" &>/dev/null || true ;;
    php)
      if ! $_ROLLBACK_STATE_EXISTED; then rm -f "$PHP_CONFIG_DIR/$ver/extensions.env"; fi
      _php_cleanup_images "$ver" ;;
  esac
  if ! $_ROLLBACK_PORT_EXISTED; then
    key=$(port_key "$svc" "$ver"); env_unset "$key"
  fi
  if ! $_ROLLBACK_PASS_EXISTED; then
    env_unset "${svc^^}_${ver//./}_ROOT_PASSWORD"
  fi
  _ROLLBACK_PENDING=false
}
trap '_install_rollback_run' EXIT

# 初始化服务配置：目录非空且含检查文件则跳过；否则清空重建并按服务类型生成
init_config_files() {
  local svc=$1 ver=$2
  local dir="$CONFIG_DIR/$svc/$ver"
  local check_file=""

  case $svc in
    nginx) check_file="$dir/nginx.conf" ;;
    php)   check_file="$dir/php.ini" ;;
    mysql) check_file="$dir/my.cnf" ;;
    redis) check_file="$dir/redis.conf" ;;
  esac

  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] && [ -f "$check_file" ]; then
    return
  fi

  [ -d "$dir" ] && rm -rf "$dir"
  log "初始化 $svc $ver 配置..."
  mkdir -p "$dir"

  case $svc in
    nginx) _init_nginx_config "$dir" "$ver" ;;
    php)   _init_php_config "$dir" "$ver" ;;
    mysql) _init_mysql_config "$dir" "$ver" ;;
    redis) _init_redis_config "$dir" ;;
  esac

  chown -R "$CURRENT_UID:$CURRENT_GID" "$dir" 2>/dev/null || true
  success "$svc $ver 配置就绪"
}

# 各服务的配置模板生成器（_init_nginx/php/mysql_config）已归位各服务模块，
# init_config_files 统一分发调用。nginx 的站点挂载常量 SITES_* 亦随迁 nginx.sh

_generic_service_install() {
  local svc=$1 ver=$2 default_port=$3
  shift 3
  validate_version "$ver"
  # 版本线守门：官方镜像没有的大版本直接拒绝（MySQL 5.7 之后没有 6.x/7.x）。
  # 不拦的话要走到拉取阶段才报一句 "denied"，前面的配置/属主设置全白做
  case "$svc" in
    mysql) [[ "$ver" == 5.* || "$ver" == 8.* || "$ver" == 9.* ]] || error "MySQL 不存在 ${ver%%.*}.x 版本（5.7 之后直接是 8.0），可用版本线: 5.7 / 8.0 / 8.4 / 9.x" ;;
    redis) [[ "$ver" == [4-9] || "$ver" == [4-9].* ]] || error "Redis 可用版本线: 4.x / 5.x / 6.x / 7.x / 8.x" ;;
  esac
  if [ -f "$EXT_DIR/${svc}-${ver}.yml" ]; then
    error "${svc} ${ver} 已安装"
  fi
  _install_rollback_begin "$svc" "$ver"

  local port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [ $# -ge 2 ] || error "--port 需要指定端口号"
        port="${2}"
        shift 2 ;;
      *)
        error "未知选项: $1" ;;
    esac
  done

  require_docker

  if [ -n "$port" ]; then
    if ! check_and_report_port "$port"; then
      error "端口 $port 不可用"
    fi
    env_set "$(port_key "$svc" "$ver")" "$port"   # 用户显式指定的端口直接写入 .env
  else
    get_or_set_port "$svc" "$ver" "$default_port" > /dev/null
  fi

  init_config_files "$svc" "$ver"
  case "$svc" in
    mysql) _mysql_generate_compose "$ver"; _mysql_ensure_running "$ver" ;;
    redis)
      get_or_set_password "redis" "$ver" > /dev/null
      _redis_generate_compose "$ver"
      _redis_ensure_running "$ver"
      ;;
  esac
  # up 之后端口已定（用户指定或自动挑选时均已写入 .env），只读不再复查：
  # 此时宿主机端口已被刚启动的容器自己监听，复查会被误判为"被占"而改写 .env、报错端口
  local final_port; final_port=$(read_env_value "$(port_key "$svc" "$ver")" "$default_port")
  _install_rollback_commit
  success "${svc} ${ver} 安装完成，端口 ${final_port}"
}

# 通用端口修改（仅用于 MySQL/Redis）
_generic_db_port_set() {
  local svc=$1 ver=$2 new_port=$3 default_port=$4
  local key; key=$(port_key "$svc" "$ver")
  local old_port; old_port=$(read_env_value "$key" "")
  [ -z "$old_port" ] && error "${svc} ${ver} 未安装或端口未记录"

  require_docker

  if ! check_and_report_port "$new_port"; then
    error "端口 ${new_port} 不可用"
  fi

  # 流程：备份 .env → 写入新端口 → 重建容器 → 轮询验证 → 任一步失败则回滚 .env 并按旧端口重建
  local temp_env; temp_env=$(mktemp)
  cp "$ENV_FILE" "$temp_env"
  env_set "$key" "$new_port"

  local cname=$(get_container_name "$svc" "$ver")
  if ! run_compose "$svc" "$ver" up -d --force-recreate "$cname"; then
    cp "$temp_env" "$ENV_FILE"; rm -f "$temp_env"
    error "端口变更失败，已回滚"
  fi

  # 容器重建后服务需要数秒就绪（MySQL 尤其慢），轮询验证避免误判回滚
  local verify_timeout=30
  while [ "$verify_timeout" -gt 0 ]; do
    if verify_service "$svc" "$ver" "$new_port"; then
      rm -f "$temp_env"
      success "${svc} ${ver} 端口已改为 ${new_port}"
      return
    fi
    sleep 2
    verify_timeout=$((verify_timeout - 2))
  done

  cp "$temp_env" "$ENV_FILE" 2>/dev/null || true
  run_compose "$svc" "$ver" up -d --force-recreate "$cname" >/dev/null
  rm -f "$temp_env"
  error "新端口验证失败，已回滚"
}

verify_service() {
  local svc=$1 ver=$2 port=$3
  local cname=$(get_container_name "$svc" "$ver")
  case "$svc" in
    mysql)
      local pass=$(get_or_set_password "$svc" "$ver")
      docker exec -e MYSQL_PWD="$pass" "$cname" mysqladmin ping -h localhost -u root &>/dev/null
      ;;
    redis)
      docker exec "$cname" redis-cli ping | grep -q PONG
      ;;
    nginx)
      http_probe_ok "$port"
      ;;
    *) return 1 ;;
  esac
}
