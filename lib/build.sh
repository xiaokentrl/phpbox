#!/bin/bash
# shellcheck shell=bash

# 兼容桥接层（迁移第 3/4 步）：原 lib/build.sh 全部 17 个函数已迁至
# lib/php/common/build.sh（PHP 镜像构建属 php 线），本文件仅保留 source 转发；
# 新加载链稳定后（第 6 步）整文件删除。
source "$(dirname "${BASH_SOURCE[0]}")/php/common/build.sh"
