#!/bin/bash
# shellcheck shell=bash
# Nginx 安装/移除/启动/端口生命周期（搬运自 lib/nginx.sh，纯迁移无逻辑改动）

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
  # 只移除 nginx 容器本身，不走 compose down（会误删共享网络，见 common.sh 注释）
  stop_and_remove_container "nginx"
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
    echo -e "${YELLOW}Nginx 已安装 (使用 nginx:${NGINX_VERSION:-alpine})${NC}"
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

  # 镜像获取走离线事务（offline/nginx/<tag>/ 命中则零网络），在生成配置前：
  # _nginx_generate_compose 写入的 image tag 与此处取值保持一致
  _nginx_ensure_image "${NGINX_VERSION:-alpine}" "install" >/dev/null   # stdout 的镜像名无人捕获，吞掉防终端污染

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
