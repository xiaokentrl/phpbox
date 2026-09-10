#!/bin/bash
# shellcheck shell=bash

# 兼容桥接层（迁移第 3/4 步）：原 lib/build.sh 全部 20 个函数已按职责分布于
# lib/php/common/{apk-fetch.sh,offline.sh,build.sh} 三文件（优化切片 A，PHP 镜像构建
# 属 php 线），本文件仅保留 source 转发；新加载链稳定后（第 6 步）整文件删除。
source "$(dirname "${BASH_SOURCE[0]}")/php/common/apk-fetch.sh"
source "$(dirname "${BASH_SOURCE[0]}")/php/common/offline.sh"
source "$(dirname "${BASH_SOURCE[0]}")/php/common/build.sh"
