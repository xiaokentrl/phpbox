#!/bin/bash
# shellcheck shell=bash
# redis 子命令分发（搬运自 lib/redis.sh，纯迁移无逻辑改动）

cmd_redis() {
  case "${1:-help}" in
    install)   shift; _redis_install "$@" ;;
    port)      _redis_port_set "${2:-}" "${3:-}" ;;
    list)      _redis_show_list ;;
    uninstall) shift; _redis_uninstall "$@" ;;
    *) error "未知 redis 操作: ${1:-help} (支持 install, port, list, uninstall)" ;;
  esac
}
