#!/bin/bash
# shellcheck shell=bash
# mysql 子命令分发（搬运自 lib/mysql.sh，纯迁移无逻辑改动）

cmd_mysql() {
  case "${1:-help}" in
    install)   shift; _mysql_install "$@" ;;
    port)      _mysql_port_set "${2:-}" "${3:-}" ;;
    list)      _mysql_show_list ;;
    uninstall) shift; _mysql_uninstall "$@" ;;
    *) error "未知 mysql 操作: ${1:-help} (支持 install, port, list, uninstall)" ;;
  esac
}
