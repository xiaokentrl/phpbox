#!/bin/bash
# shellcheck shell=bash
# nginx 子命令分发（搬运自 lib/nginx.sh，纯迁移无逻辑改动）

cmd_nginx() {
  case "${1:-help}" in
    install)   shift; _nginx_install "$@" ;;
    port)      _nginx_port_set "${2:-}" "${3:-}" ;;
    reload)    _nginx_reload ;;
    uninstall) log "卸载 Nginx（保留配置和站点）"; _nginx_remove; success "Nginx 已卸载，配置保留于 config/nginx/" ;;
    *) error "未知 nginx 操作: ${1:-help} (支持 install, port, reload, uninstall)" ;;
  esac
}
