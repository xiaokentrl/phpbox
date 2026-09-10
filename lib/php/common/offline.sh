#!/bin/bash
# shellcheck shell=bash

# 离线资产事务层（自原 lib/build.sh 按职责拆出，优化切片 A）：
#   pecl 备份命中/暂存/晋升、apk 闭包预取/校验/暂存/晋升、构建失败丢弃、下载代理解析。
# 提交契约见 AGENTS.md §2.1.1：暂存 ≠ 入库——内容先暂存进构建上下文
#   （config/php/<版本>/{apk,pecl}），经 Docker 构建与扩展编译全部验证后才原子晋升进
#   offline/php/<版本>/{apk,pecl}；晋升前保留旧库、失败可回滚，绝不收验证失败的包。
# 依赖方向：offline.sh → apk-fetch.sh（容器内下载器）+ lib/common 的 log/error；
#   由 build.sh 编排调用，禁止反向

# 探测构建可用的 HTTP 代理。背景：网络受限环境下 pecl.php.net 的 IPv4 被间歇性重置
# （宿主机可能仅 IPv6 可达），而构建容器没有 IPv6 出口，也无法直达宿主 loopback 上的
# 本地代理。关键教训：直连"单次探测通过"不代表构建期间稳定——一次构建会发起大量
# 连接，任一被重置即失败。因此探测策略是代理优先：本地存在能通 pecl 的代理就走代理，
# 只有探测不到代理时才直连（构建失败时由报错信息引导配置 BUILD_PROXY）。
# 探测必须用"构建容器视角"：本地代理（xray/v2rayN 等）常只监听 127.0.0.1，宿主侧直连
# 探测当然通，但容器经 docker0 网关访问不到——曾因此选中假可用代理，构建时
# connection refused。以 docker0 网桥 IP 探测（监听 0.0.0.0 才通，通即容器内可达），
# 输出即网桥地址，可直接用作构建期 http_proxy，无需再做地址换算
_php_detect_build_proxy() {
  command -v curl &>/dev/null || return 0
  local bridge attempt port
  bridge=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  bridge=${bridge:-172.17.0.1}
  for port in 10809 7890 8118 1087 1080 8888; do
    # -f：代理返回 4xx/5xx 也视为不可用（如仅 SOCKS 的端口对 HTTP 代理请求会报 400）；
    # 每端口重试一次：探测连接可能与代理上残留的连接竞争而瞬断，单次失败不足以判死
    for attempt in 1 2; do
      if curl -4 -s -f --connect-timeout 3 --max-time 6 -x "http://$bridge:$port" -o /dev/null https://pecl.php.net/channel.xml 2>/dev/null; then
        echo "http://$bridge:$port"
        return 0
      fi
    done
  done
  return 0
}

# BUILD_PROXY 取值解析的公共前段（两处调用方共用，原先各写一份 auto→探测 分支）：
# auto → 本地探测；none/空 → "none"；其余原样输出（host:port 或完整 URL）。
# 宿主侧调用方（pecl 预下载）直接拿值用——显式配置的 127.0.0.1:port 对宿主 curl
# 本就可达，不能做 docker0 改写；容器侧调用方（_php_resolve_build_proxy）在此
# 基础上再补 http:// 归一化与网关 IP 改写
_php_resolve_build_proxy_base() {
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then proxy=$(_php_detect_build_proxy); fi
  if [ -z "$proxy" ] || [ "$proxy" = "none" ]; then echo "none"; return 0; fi
  echo "$proxy"
}

# 解析 BUILD_PROXY 为容器可达的最终代理地址，stdout 输出（none 或 http://URL）。
# none=禁用；auto（默认）=探测本地常见代理端口；其余按显式值（host:port 或完整 URL）。
# 代理地址归一化：原生 docker 的构建容器里 host.docker.internal 默认不解析（Desktop VM
# 才内置该域名），换引擎后 pecl 全部死于 DNS——代理指向本机时改写为 docker0 网关 IP
# （容器内零 DNS 可达），取不到再退回域名，并由调用方的 --add-host host-gateway 兜底
_php_resolve_build_proxy() {
  local proxy
  proxy=$(_php_resolve_build_proxy_base)
  if [ "$proxy" = "none" ]; then echo "none"; return 0; fi
  case "$proxy" in
    http://*|https://*) : ;;
    *) proxy="http://${proxy}" ;;
  esac
  local proxy_gw
  proxy_gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
  if [ -n "$proxy_gw" ]; then
    proxy="${proxy//127.0.0.1/$proxy_gw}"
    proxy="${proxy//localhost/$proxy_gw}"
  else
    proxy="${proxy//127.0.0.1/host.docker.internal}"
    proxy="${proxy//localhost/host.docker.internal}"
  fi
  echo "$proxy"
}

# pecl 远端模块清单：这些扩展的源码包不在 php 源码树里，需从 pecl.php.net 下载。
# 其余扩展（gd/zip/pgsql 等）是"内置模块"，IPE 用镜像内 PHP 源码离线编译，不依赖网络
_PHP_PECL_REMOTE_EXTS="imagick xdebug redis"
_PECL_STAGED=""   # 本次构建暂存（尚未验证）的 pecl 包名，构建成功后才晋升进备份库

# pecl 源码包下载地址。新版扩展会放弃旧 PHP（imagick 3.8 起要求 PHP ≥ 8.0、
# xdebug 最新版要求 PHP ≥ 8.0——7.4 上报 "requires PHP (version >= 8.0.0)"），
# 对不兼容的组合钉住仍支持的旧版本，避免 pecl 拉到最新版后在依赖检查上直接失败
_php_pecl_tarball_url() {
  local ext=$1 ver=$2
  case "$ext" in
    imagick) case "$ver" in 7.*) echo "https://pecl.php.net/get/imagick-3.7.0.tgz"; return ;; esac ;;
    xdebug)  case "$ver" in 7.*) echo "https://pecl.php.net/get/xdebug-3.1.6.tgz"; return ;; esac ;;
  esac
  echo "https://pecl.php.net/get/$ext"
}

# 把逗号分隔的扩展列表拆成 内置/远端 两组（写入全局 _SPLIT_BUNDLED/_SPLIT_REMOTE 供调用方读取）
_php_split_ext_list() {
  local exts=$1 ext
  _SPLIT_BUNDLED="" ; _SPLIT_REMOTE=""
  local IFS=,
  for ext in $exts; do
    case " $_PHP_PECL_REMOTE_EXTS " in
      *" $ext "*) _SPLIT_REMOTE="$_SPLIT_REMOTE $ext" ;;
      *) _SPLIT_BUNDLED="${_SPLIT_BUNDLED:+$_SPLIT_BUNDLED,}$ext" ;;
    esac
  done
  _SPLIT_REMOTE="${_SPLIT_REMOTE# }"
}

# 宿主机侧暂存 pecl 源码包到构建上下文：优先命中离线备份库
# （offline/php/<版本>/pecl/，服务→版本→分类三层，人工整理不会混放），未命中才经
# 宿主代理下载并暂存。暂存 ≠ 入库：包是否可用要等构建验证（见 _php_promote_pecl_tarballs），
# 备份库里因此只会有验证成功的包。手动放入官网 tgz（按"扩展-版本.tgz"命名到对应版本目录）
# 视为用户自证可用，直接命中
# 备份优先：命中即零网络（与 APK 侧 _php_stage_apk_closure 的契约对齐——此前 PECL 侧
# 是"先下载后查备份"，offline 库全命中仍要重新下载全部 tgz，真离线环境直接构建失败）。
# 备份里的版本是"该 PHP 版本上验证过"的包，即便不是最新版也按缓存语义复用（与 APK 侧一致）。
# 备份键两种形态都认：精确名 "$ext.tgz"（旧式无跳转命名，如现存的 redis.tgz）优先，
# 再按 "$ext-*.tgz" glob 匹配任意已验证版本（如 7.4 钉住的 imagick-3.7.0.tgz）。
_php_stage_pecl_tarballs() {
  local ver=$1 remote_list=$2 build_dir=$3
  local dest="$build_dir/pecl"
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  mkdir -p "$dest"
  log "pecl 备份库: $backup_dir → 构建目录: $dest"

  _PECL_STAGED=""
  local ext url fname tmp hit
  local proxy_resolved=false curl_args=()
  for ext in $remote_list; do
    hit=""
    for cand in "$backup_dir/$ext.tgz" "$backup_dir/$ext-"*.tgz; do
      [ -f "$cand" ] || continue   # glob 无匹配时保持字面串，靠 -f 过滤掉
      hit=$(basename "$cand")
      break
    done
    if [ -n "$hit" ]; then
      log "pecl 备份命中: $backup_dir/$hit → $dest/（零网络）"
      cp "$backup_dir/$hit" "$dest/$hit"
      continue
    fi

    # 未命中才触网；代理解析也推迟到首次真要下载时——全命中时连本地代理探测都不做
    if ! $proxy_resolved; then
      local proxy=$(_php_resolve_build_proxy_base)
      if [ "$proxy" != "none" ]; then curl_args+=(-x "$proxy"); fi
      proxy_resolved=true
    fi
    url=$(_php_pecl_tarball_url "$ext" "$ver")
    tmp=$(mktemp)
    # -L 跟随 /get/<ext> 的版本跳转，url_effective 即最终带版本号的 URL，取其文件名做备份键
    if ! curl -fsSL -S --retry 2 --connect-timeout 8 -o "$tmp" -w '%{url_effective}' \
      "${curl_args[@]}" "$url" > "$tmp.url"; then
      rm -f "$tmp" "$tmp.url"
      _php_discard_staging "$build_dir"
      error "pecl 包 $ext 预下载失败（检查网络或 .env 的 BUILD_PROXY）"
    fi
    fname=$(basename "$(cat "$tmp.url")")
    rm -f "$tmp.url"
    [[ "$fname" == *.tgz ]] || fname="$ext.tgz"   # 无跳转时拿不到版本号，退回旧命名
    mv "$tmp" "$dest/$fname"
    log "pecl 已下载暂存: $dest/$fname（源: $url，构建成功后晋升备份库）"
    _PECL_STAGED="$_PECL_STAGED $fname"
  done
  _PECL_STAGED="${_PECL_STAGED# }"
}

# 构建成功 = 暂存包在本 PHP 版本上编译与启用全部通过：晋升进备份库供以后直接复用。
# 构建失败的路径不会走到这里，暂存包随构建目录清理而消失——备份库永远不收验证失败的包
_php_promote_pecl_tarballs() {
  local ver=$1 dest=$2
  [ -n "$_PECL_STAGED" ] || return 0
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  local parent tmp old fname
  parent=$(dirname "$backup_dir")
  tmp="${backup_dir}.tmp.$$"
  old="${backup_dir}.old.$$"
  mkdir -p "$parent"
  rm -rf "$tmp" "$old"
  mkdir "$tmp"
  if [ -d "$backup_dir" ]; then
    cp "$backup_dir"/*.tgz "$tmp/" 2>/dev/null || true
  fi
  for fname in $_PECL_STAGED; do
    if [ ! -s "$dest/$fname" ]; then
      rm -rf "$tmp"
      error "PECL 晋升失败：暂存包不存在或为空（暂存: $dest/$fname，目标: $backup_dir/$fname）"
    fi
    cp "$dest/$fname" "$tmp/$fname" || {
      rm -rf "$tmp"
      error "PECL 晋升失败：无法复制暂存包（暂存: $dest/$fname）"
    }
  done
  if [ -e "$backup_dir" ]; then
    mv "$backup_dir" "$old" || {
      rm -rf "$tmp"
      error "PECL 晋升失败：无法保留旧备份库（目标: $backup_dir）"
    }
  fi
  if ! mv "$tmp" "$backup_dir"; then
    [ -e "$old" ] && mv "$old" "$backup_dir"
    rm -rf "$tmp"
    error "PECL 晋升失败：无法替换备份库（目标: $backup_dir）"
  fi
  for fname in $_PECL_STAGED; do
    log "已验证入备份库: $backup_dir/$fname"
  done
  rm -rf "$old"
  _PECL_STAGED=""
}

# apk 闭包预取：向空 root 全新安装，把"必然完整"的依赖闭包拉到 $dest。
# 公共实现见 common.sh 的 _apk_ranked_fetch_run（用前测速排序 + APK_TIMEOUT 秒无响应
# 自动切换下一个源）；此处只绑定 PHP 基础镜像与递归闭包模式
_php_apk_prefetch_run() {
  local ver=$1 deps=$2 dest=$3
  _apk_ranked_fetch_run "php:${ver}-fpm-alpine" "phpbox-apkfetch-${ver//./}" 2400 recursive "$dest" $deps
}

# 基础包同步：把基础镜像的全量包按当前镜像源版本补进暂存（钉死库版本与前进的镜像源
# 之间会 breaks，作用见调用方注释）。尽力而为：失败返回 1，由调用方仅告警
_php_apk_basesync_run() {
  local ver=$1 dest=$2
  _apk_ranked_fetch_run "php:${ver}-fpm-alpine" "phpbox-basesync-${ver//./}" 1800 installed "$dest"
}

# 闭包完整性校验：phpize 工具链的关键包必须都在（按文件名前缀匹配，如 autoconf-2.73.apk）。
# 缺失即预取/备份命中了一份残缺闭包，返回 1 由调用方降级在线路径——离线构建缺它必死于
# "Cannot find autoconf"
_php_apk_closure_verify() {
  local dest=$1 need missing=""
  for need in autoconf gcc g++ make pkgconf re2c musl-dev linux-headers file dpkg; do
    ls "$dest/${need}-"*.apk >/dev/null 2>&1 || missing="$missing $need"
  done
  if [ -n "$missing" ]; then
    log "apk 闭包缺少构建依赖:${missing}"
    return 1
  fi
}

# 宿主机侧暂存 apk 依赖闭包到构建上下文：优先命中按版本隔离的备份库
# （offline/php/<版本>/apk/，整批对应一个 PHP 版本，Docker 构建成功后才入库），未命中时
# 借助与目标镜像同源的辅助容器，向一个空 root 做一次"全新安装"——apk 只下载缺失的包，
# 直接 fetch 会跳过容器里已装的基础包导致闭包不完整；--initdb 的空 root 视为全未安装，
# 拉下的 .apk 集合因此必然完整，且"能装完"本身就是对闭包的验证。预取失败仅返回 1 由
# 调用方降级为在线安装路径，不会中断安装
_php_stage_apk_closure() {
  local ver=$1 deps=$2 dest=$3
  local backup_dir="$OFFLINE_DIR/php/$ver/apk"
  # 暂存目录可能残留 chown 修复之前由容器写入的 root 属主文件，宿主用户删不动，走容器兜底清空
  _rm_rf_with_docker_fallback "$dest"
  mkdir -p "$dest"
  log "apk 闭包备份库: $backup_dir → 构建目录: $dest"
  log "apk 镜像源（先测速排序，超时 $APK_TIMEOUT 秒自动切换）: $APK_MIRRORS"
  local hit=0
  if [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
    log "apk 闭包命中: $backup_dir → $dest/（$(ls "$backup_dir" | wc -l) 个包）"
    cp "$backup_dir"/*.apk "$dest/"
    if _php_apk_closure_verify "$dest"; then
      hit=1
    else
      # 备份命中残缺集（如人工补包只补了一半）：不信任，重新预取，成功后自动覆盖备份库
      log "警告：备份库闭包残缺，忽略并重新预取"
      rm -rf "$dest"
      mkdir -p "$dest"
    fi
  fi
  if [ "$hit" = 0 ]; then
    log "apk 闭包预取: 宿主容器内 apk fetch → $dest/（$ver，$(wc -w <<<"$deps") 个包）"
    if ! _php_apk_prefetch_run "$ver" "$deps" "$dest"; then
      log "警告：apk 闭包预取失败，本次构建降级为在线安装（下次构建自动重试）"
      rm -rf "$dest"
      return 1
    fi
    if ! _php_apk_closure_verify "$dest"; then
      log "警告：预取闭包不完整，本次构建降级为在线安装"
      rm -rf "$dest"
      return 1
    fi
  fi
  # 基础包同步（重要）：基础镜像"钉死库版本"的包（openssl 等不在依赖闭包里），
  # 镜像源前进后其精确 pin 会与闭包里的新库 breaks——把基础镜像的全量包
  # 按当前镜像源版本补进暂存，离线安装时整个基础系统一起升级，版本重新对齐。
  # 离线场景此步会失败：容忍（未漂移时旧闭包仍可用；已漂移则需联网重试一次）
  if ! _php_apk_basesync_run "$ver" "$dest"; then
    log "警告：基础包同步失败（离线场景可忽略）；若构建报 breaks 版本冲突，请联网重试一次"
  fi
  # 暂存集 = 依赖闭包 + 基础镜像全量包（当前镜像源版本）= 可离线安装的一致状态。
  # 此处绝不写正式备份库，必须等 Docker 构建和扩展编译成功后再晋升。
  log "apk 闭包暂存完成: $dest/（$(find "$dest" -maxdepth 1 -name '*.apk' -type f | wc -l) 个包，构建成功后入备份库）"
  return 0
}

# Docker 构建成功后才晋升 APK 闭包。用临时目录组装完整集合，再替换正式目录，避免备份库
# 出现半套包或新旧版本混杂；构建失败路径不会调用此函数。
_php_promote_apk_closure() {
  local ver=$1 dest=$2
  local backup_dir="$OFFLINE_DIR/php/$ver/apk"
  local parent tmp old count size
  count=$(find "$dest" -maxdepth 1 -name '*.apk' -type f 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    error "APK 闭包晋升失败：暂存目录没有 .apk（暂存: $dest，目标: $backup_dir）"
  fi
  log "开始晋升已验证 APK 闭包: $dest/ → $backup_dir/（$count 个包）"
  parent=$(dirname "$backup_dir")
  tmp="${backup_dir}.tmp.$$"
  old="${backup_dir}.old.$$"
  mkdir -p "$parent"
  rm -rf "$tmp" "$old"
  mkdir "$tmp"
  if ! cp "$dest"/*.apk "$tmp/"; then
    rm -rf "$tmp"
    error "APK 闭包晋升失败：无法复制暂存包"
  fi
  if [ -e "$backup_dir" ]; then
    mv "$backup_dir" "$old" || {
      rm -rf "$tmp"
      error "APK 闭包晋升失败：无法保留旧备份库"
    }
  fi
  if ! mv "$tmp" "$backup_dir"; then
    [ -e "$old" ] && mv "$old" "$backup_dir"
    rm -rf "$tmp"
    error "APK 闭包晋升失败：无法替换备份库"
  fi
  if ! _php_apk_closure_verify "$backup_dir"; then
    rm -rf "$backup_dir"
    if [ -e "$old" ]; then
      mv "$old" "$backup_dir" || error "APK 闭包晋升失败：目标校验失败且旧备份库恢复失败"
    fi
    error "APK 闭包晋升失败：目标备份库完整性校验失败（目标: $backup_dir）"
  fi
  rm -rf "$old"
  size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
  log "已验证入备份库: $backup_dir/（$count 个包，$size）"
}

# 构建失败时彻底删除两个暂存目录（pecl 包与 apk 闭包）：未验证的内容没有备份库正本、
# 命中副本的母本在备份库不受影响，留在磁盘上只是垃圾。暂存标记同步清空，防止后续误晋升
_php_discard_staging() {
  local build_dir=$1
  rm -rf "$build_dir/pecl" "$build_dir/apk"
  _PECL_STAGED=""
}
