#!/bin/bash
# shellcheck shell=bash

# 尽力重载 nginx（未运行则静默跳过）；用于 PHP 等后端容器重建后刷新配置/连接
nginx_try_reload() {
  # -qx：整行精确匹配容器名，避免误中 "nginx-proxy" 之类的前缀相似名
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx' || return 0
  docker exec nginx nginx -s reload >/dev/null 2>&1 || true
}

# 用一次性容器校验 nginx 配置（sites 目录一并挂入）；输出/返回码由调用方处理
_nginx_validate() {
  # 三个平级挂载，与 _nginx_generate_compose 的服务挂载一致。不能把整个 alpine 目录
  # 挂成 /etc/nginx:ro 再嵌套挂 sites：父挂载只读时 Docker 无法 mkdirat 嵌套挂载点
  # （报 read-only file system），且 sites/ 在提取出的配置里本就不存在
  # 不加 --user：与 compose 里的真实服务一致以 root 运行。nginx -t 会尝试打开
  # pid 文件（/run/nginx.pid）验证可写，非 root 在该路径必因权限失败导致误报
  docker run --rm \
    -v "$CONFIG_DIR/nginx/alpine/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$CONFIG_DIR/nginx/alpine/conf.d":/etc/nginx/conf.d:ro \
    -v "$CONFIG_DIR/nginx/sites":/etc/nginx/sites:ro \
    nginx:alpine nginx -t
}

_nginx_generate_compose() {
  local ver="alpine"
  local yml="$EXT_DIR/nginx-default.yml"

  init_config_files "nginx" "$ver"

  cat > "$yml" <<YEOF
services:
  nginx:
    image: nginx:${ver}
    container_name: nginx
    ports:
      - "\${NGINX_PORT}:80"
    volumes:
      - \${WWW_ROOT}:/var/www:ro
      - ./config/nginx/${ver}/conf.d:/etc/nginx/conf.d:ro
      - ./config/nginx/${ver}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/sites:/etc/nginx/sites:ro
      - ./logs/nginx:/var/log/nginx:rw
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=nginx"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${ver}"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/"]
      interval: 10s
      timeout: 5s
      retries: 5
YEOF
}

_nginx_ensure_running() {
  _nginx_validate || error "Nginx 配置验证失败"

  run_compose "nginx" "default" up -d "nginx"
  # up 之后只读端口，不走 get_or_set_port 的占用检查：宿主机上该端口已被刚启动的
  # nginx 自己监听（Docker 发布端口），重查会被误判为"被占"而改写 .env 并让健康检查打错端口
  local port=$(read_env_value "NGINX_PORT" "80")
  local timeout=20
  while [ $timeout -gt 0 ]; do
    if http_probe_ok "$port"; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  error "Nginx 启动或可用性检查失败"
}

_nginx_remove() {
  run_compose "nginx" "default" down 2>/dev/null || true
  docker rm -f nginx 2>/dev/null || true
  rm -f "$EXT_DIR/nginx-default.yml"
}

# 流程：解析 --port → 已装则确认重装 → 定端口 → 生成配置 → 启动 → 报告
_nginx_install() {
  local port=""
  while [[ $# -gt 0 ]]; do   # 参数解析样板：全函数唯一的语法噪音，往下全是业务步骤
    case "$1" in
      --port)
        [ $# -ge 2 ] || error "--port 需要指定端口号"
        port="${2}"; shift 2 ;;
      *) error "未知选项: $1" ;;
    esac
  done

  if [ -f "$EXT_DIR/nginx-default.yml" ]; then
    echo -e "${YELLOW}Nginx 已安装 (使用 nginx:alpine)${NC}"
    if ! confirm_yes "是否安全重装（保留配置和站点）？"; then
      [[ -t 0 ]] && { log "取消重装"; return; }   # 终端里答 n → 取消；脚本环境 → 报错
      error "非交互模式，取消重装"
    fi
    _nginx_remove
  fi

  if [ -n "$port" ]; then
    check_and_report_port "$port" || error "端口 ${port} 不可用"
    env_set "NGINX_PORT" "$port"
  else
    get_or_set_port "nginx" "default" "80" > /dev/null   # 未指定端口：自动挑空闲端口并记录
  fi

  _nginx_generate_compose
  _nginx_ensure_running
  success "Nginx 安装完成，端口: $(read_env_value "NGINX_PORT" "")"
}

_nginx_port_set() {
  local sub="${1:-}"
  local new_port="${2:-}"
  [ "$sub" != "set" ] && error "用法: phpbox nginx port set <新端口>"
  [ -z "$new_port" ] && error "请指定新端口"
  if ! check_and_report_port "$new_port"; then
    error "端口 ${new_port} 不可用"
  fi
  local old_port; old_port=$(read_env_value "NGINX_PORT" "")
  [ -z "$old_port" ] && error "Nginx 端口未记录"

  # 流程：备份 .env → 写入新端口 → 重建容器 → 轮询验证 → 任一步失败则回滚
  local temp_env; temp_env=$(mktemp)
  cp "$ENV_FILE" "$temp_env"
  env_set "NGINX_PORT" "$new_port"

  if ! run_compose "nginx" "default" up -d --force-recreate nginx 2>&1; then
    cp "$temp_env" "$ENV_FILE"
    rm -f "$temp_env"
    error "端口变更失败，已回滚"
  fi

  local timeout=20
  while [ $timeout -gt 0 ]; do
    if http_probe_ok "$new_port"; then
      rm -f "$temp_env"
      success "Nginx 端口已改为 ${new_port}"
      return
    fi
    sleep 2
    timeout=$((timeout - 2))
  done

  cp "$temp_env" "$ENV_FILE" 2>/dev/null || true
  run_compose "nginx" "default" up -d --force-recreate nginx >/dev/null
  rm -f "$temp_env"
  error "新端口验证失败，已回滚"
}

_nginx_reload() {
  _nginx_validate || error "配置验证失败"
  if docker exec nginx nginx -s reload 2>/dev/null; then
    success "Nginx 重载成功"
  else
    error "Nginx 重载失败，请检查日志"
  fi
}

# 仅做分发，实现见各 _nginx_* 函数
cmd_nginx() {
  case "${1:-help}" in
    install)   shift; _nginx_install "$@" ;;
    port)      _nginx_port_set "${2:-}" "${3:-}" ;;
    reload)    _nginx_reload ;;
    uninstall) log "卸载 Nginx（保留配置和站点）"; _nginx_remove; success "Nginx 已卸载，配置保留于 config/nginx/" ;;
    *) error "未知 nginx 操作: ${1:-help} (支持 install, port, reload, uninstall)" ;;
  esac
}
