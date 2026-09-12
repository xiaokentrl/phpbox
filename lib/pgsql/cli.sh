#!/bin/bash
# shellcheck shell=bash
# pgsql 子命令分发

cmd_pgsql() {
  case "${1:-help}" in
    install)   shift; _pgsql_install "$@" ;;
    port)      _pgsql_port_set "${2:-}" "${3:-}" ;;
    list)      _pgsql_show_list ;;
    uninstall) shift; _pgsql_uninstall "$@" ;;
    *) error "未知 pgsql 操作: ${1:-help} (支持 install, port, list, uninstall)" ;;
  esac
}
