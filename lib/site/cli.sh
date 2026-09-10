#!/bin/bash
# shellcheck shell=bash
# site 子命令分发（搬运自 lib/site.sh，纯迁移无逻辑改动）

cmd_site() {
  case "${1:-help}" in
    add)    shift; _site_add "$@" ;;
    switch) shift; _site_switch "$@" ;;
    list)   _site_show_list ;;
    remove) _site_remove "${2:-}" ;;
    *) error "未知 site 操作: ${1:-help}" ;;
  esac
}
