#!/bin/bash
# shellcheck shell=bash

# APK 下载器宿主层（自原 lib/build.sh 按职责拆出，优化切片 A；仅 PHP 构建线使用）。
# 函数无 _php_ 前缀：这是 alpine/apk 的通用下载能力，当前只被 PHP 离线构建调用——
# 未来其他服务线需要 apk 下载时应把本文件上移 lib/common/，不得复制实现。
# 容器内执行脚本实体为同目录 apk-fetch.container.sh（只读挂载为 /apk-fetch.sh）。
# 依赖方向：本文件 → lib/common 的 log/error；被 offline.sh 的预取/基础包同步薄封装调用

# ---- APK 下载器公共层（搬运自 lib/common.sh，纯迁移无逻辑改动；仅 PHP 构建线使用）----
# 容器内 apk 下载器脚本（自原 _APK_FETCH_SCRIPT 单引号字符串实体化而来，切片 B）：
# 1) 用前测速：逐源下载 main 索引计时（APK_TIMEOUT 秒上限，超时/失败剔除），按最快优先排序；
# 2) 按测速顺序逐源整批下载：索引获取 APK_TIMEOUT 秒超时；下载期间以 /pkgs 增量 + 容器网卡
#    流量为进度双指标，APK_TIMEOUT 秒无增长 = 无响应，杀掉当前下载自动切换下一个源。
# 闭包必须出自同一源：切换源即清空 /pkgs 重来，避免两个源的版本混装。
# 实体化动机：原 114 行内联字符串不在 bash -n 的 lint 覆盖内（单引号字面量），语法错误
# 要到容器运行时才暴露；抽成真实文件后 tests/lint.sh 自动覆盖，且可被编辑器高亮。

# 把镜像源域名按预解析 IP 输出为 --add-host 参数（两行：标志与值；解析失败输出空）。
# 容器内 DNS 对国内域名间歇性失败（DNS: transient error）且 apk 连接挂死无重试，跳过 DNS 可根治；
# /etc/hosts 在 buildkit 中只读，必须用 --add-host 而非 RUN echo
_apk_mirror_host_args() {
  local apk_mirror=$1
  local host="${apk_mirror#*://}"; host="${host%%/*}"
  local ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  if [ -n "$ip" ]; then echo "--add-host"; echo "$host:$ip"; fi
}

# 在 alpine 系容器内测速下载 apk 包（公共入口，预取/基础包同步等调用方只做薄封装）。
# 参数: $1=基础镜像(如 php:8.4-fpm-alpine)  $2=容器名（固定名：宿主侧 timeout 杀掉客户端
#       时容器会残留并挂住构建目录，按名强制清理，绝不留孤儿）
#       $3=宿主侧总超时秒  $4=模式(recursive|installed)  $5=包落地目录(挂到 /pkgs)
#       $6+=包列表（仅 recursive 模式）
# 返回: 任一源下载成功 → 0；全部失败 → 1（降级策略由调用方决定）
# 容器内脚本以只读方式挂载为 /apk-fetch.sh 执行（宿主源文件：lib/php/common/apk-fetch.container.sh）；
# 全部输出 >&2 重定向到 stderr——下载进度不得混入 stdout，避免污染调用方的命令替换捕获
_apk_ranked_fetch_run() {
  local image=$1 cname=$2 host_timeout=$3 mode=$4 dest=$5
  shift 5
  local addhost=()
  local fetch_script="${PHP_APK_FETCH_SCRIPT:-$LIB_DIR/php/common/apk-fetch.container.sh}"
  mapfile -t addhost < <(_apk_mirror_host_args "${APK_MIRRORS%% *}")   # 主源 DNS 预解析
  docker rm -f "$cname" 2>/dev/null || true   # 上次残留的同名容器会让 run 直接失败，先清
  [ -f "$fetch_script" ] || error "apk 下载器脚本缺失: $fetch_script"
  log "apk 下载器启动：镜像 $image，容器 $cname，宿主超时 ${host_timeout}s，模式 $mode"
  if ! timeout "$host_timeout" docker run --rm --name "$cname" "${addhost[@]}" \
      -e APK_MIRRORS="$APK_MIRRORS" -e APK_TIMEOUT="$APK_TIMEOUT" -e HOST_UID="${CURRENT_UID:-}" \
      -v "$dest":/pkgs -v "$fetch_script":/apk-fetch.sh:ro \
      "$image" sh /apk-fetch.sh "$mode" "$@" >&2; then
    docker rm -f "$cname" 2>/dev/null || true
    return 1
  fi
}
