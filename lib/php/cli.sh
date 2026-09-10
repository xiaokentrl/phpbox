#!/bin/bash
# shellcheck shell=bash
# php 子命令分发（搬运自 lib/php.sh，纯迁移无逻辑改动）

cmd_php() {
  case "${1:-help}" in
    install)   shift; _php_install "$@" ;;
    extension) shift; _php_extension_op "$@" ;;
    list)      _php_show_list ;;
    uninstall) shift; _php_uninstall "$@" ;;
    *) error "未知 php 操作: ${1:-help} (支持 install, extension, list, uninstall)" ;;
  esac
}
