#!/bin/bash
# shellcheck shell=bash

# PHP 镜像构建管线：离线资产暂存/闭包预取/Dockerfile 渲染/构建验证/晋升。
# 本模块只被 php.sh 的生命周期函数调用（_php_generate_compose → _php_build_image），
# 不直接对接 CLI；依赖方向：build.sh → common.sh 的通用工具，禁止反向。
# 函数保留 _php_ 前缀：这是"PHP 镜像"的构建，迁移到其他语言不适用

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

# 宿主机侧暂存 pecl 源码包到构建上下文：优先命中离线备份库
# （offline/php/<版本>/pecl/，服务→版本→分类三层，人工整理不会混放），未命中才经
# 宿主代理下载并暂存。暂存 ≠ 入库：包是否可用要等构建验证（见 _php_promote_pecl_tarballs），
# 备份库里因此只会有验证成功的包。手动放入官网 tgz（按"扩展-版本.tgz"命名到对应版本目录）
# 视为用户自证可用，直接命中
_php_stage_pecl_tarballs() {
  local ver=$1 remote_list=$2 build_dir=$3
  local dest="$build_dir/pecl"
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  mkdir -p "$backup_dir" "$dest"
  log "pecl 备份库: $backup_dir → 构建目录: $dest"
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then proxy=$(_php_detect_build_proxy); fi
  local curl_args=()
  if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then curl_args+=(-x "$proxy"); fi

  _PECL_STAGED=""
  local ext url fname tmp
  for ext in $remote_list; do
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
    if [ -f "$backup_dir/$fname" ]; then
      log "pecl 备份命中: $backup_dir/$fname → $dest/"
      rm -f "$tmp"
      cp "$backup_dir/$fname" "$dest/$fname"
    else
      mv "$tmp" "$dest/$fname"
      log "pecl 已下载暂存: $dest/$fname（源: $url，构建成功后晋升备份库）"
      _PECL_STAGED="$_PECL_STAGED $fname"
    fi
  done
  _PECL_STAGED="${_PECL_STAGED# }"
}

# 构建成功 = 暂存包在本 PHP 版本上编译与启用全部通过：晋升进备份库供以后直接复用。
# 构建失败的路径不会走到这里，暂存包随构建目录清理而消失——备份库永远不收验证失败的包
_php_promote_pecl_tarballs() {
  local ver=$1 dest=$2
  [ -n "$_PECL_STAGED" ] || return 0
  local backup_dir="$OFFLINE_DIR/php/$ver/pecl"
  mkdir -p "$backup_dir"
  local fname
  for fname in $_PECL_STAGED; do
    cp "$dest/$fname" "$backup_dir/$fname"
    log "已验证入备份库: $backup_dir/$fname"
  done
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

# 渲染 Dockerfile（独立成函数便于测试断言）。参数分工：
#   bundled  内置模块名列表（逗号分隔，IPE 离线编译）
#   remote   预下载的本地 tarball 文件名列表（空格分隔，可能为空）
# heredoc 内的 $ 分工：
#   $bundled / ${bundled//,/ }  生成时展开：逗号换空格变成多个参数
#   \$APK_MIRRORS / \${UID}     写入字面量，真正取值发生在 docker build 时（ARG）
# 各扩展的 apk 编译期依赖映射（"扩展:包,包"，空格分隔多个映射；包名跨 alpine 版本稳定）。
# 全部扩展的依赖一次性装进独立 RUN 层并缓存：失败重试/重建不再重复下载数百 MiB；
# 映射未覆盖的依赖由 IPE 按名自行安装（网络路径照旧），此处缺失只会变慢不会失败
_PHP_BUILD_BASE_APK_DEPS="musl-dev linux-headers pkgconf re2c"
_PHP_EXT_APK_DEPS="gd:libpng-dev,libjpeg-turbo-dev,freetype-dev,libwebp-dev,zlib-dev,zlib-dev,libxpm-dev intl:icu-dev zip:libzip-dev pgsql:libpq-dev pdo_pgsql:libpq-dev soap:libxml2-dev imagick:imagemagick-dev"

_php_ext_apk_deps() {
  local names=${1//,/ } ext pair out="$_PHP_BUILD_BASE_APK_DEPS"
  for ext in $names; do
    for pair in $_PHP_EXT_APK_DEPS; do
      case "$pair" in "$ext:"*) out="$out ${pair#*:}" ;; esac
    done
  done
  echo "$out" | tr ',' ' ' | tr -s ' '
}

_php_render_dockerfile() {
  local ver=$1 bundled=$2 remote_files=$3 offline=$4
  # COPY pecl 与 pecl 循环拆开维护：COPY 必须在依赖安装层之前，循环必须在之后
  local copy_exts="" pecl_loop=""
  if [ -n "$remote_files" ]; then
    copy_exts="COPY pecl/ /tmp/pecl/"
    # 零网络 pecl 安装：pecl install 对本地 tgz 仍会走 pear 的联网环节（实测 imagick
    # 编译完成后卡在拉 PHP-Parser，两次构建同点挂死），所以绕开 pecl 命令，直接
    # phpize/configure/make/make install——编译与安装（make install 仅拷 .so）均不触网，
    # docker-php-ext-enable 只写 ini 同样离线。三态等价于 pecl install 的最终产物
    pecl_loop="RUN set -e; for t in /tmp/pecl/*.tgz; do [ -e \"\$t\" ] || { echo \"ERROR: /tmp/pecl/ 下没有 .tgz 包\"; exit 1; }; d=\"/tmp/src/\$(basename \"\$t\" .tgz)\"; mkdir -p \"\$d\"; tar xzf \"\$t\" -C \"\$d\" --strip-components=1; (cd \"\$d\" && phpize && ./configure && make -j\"\$(nproc)\" && make install); docker-php-ext-enable \"\$(basename \"\$t\" .tgz | sed 's/-[0-9][0-9.]*\$//')\"; done"
  fi
  local apk_deps; apk_deps=$(_php_ext_apk_deps "$bundled,${remote_files//.tgz/}")
  local body=""
  if [ "$offline" = "1" ]; then
    # 离线：apk 依赖闭包 + 官方 docker-php-ext-install，全程零网络（连 IPE 二进制都不拉取）。
    # 顺序即正确性：工具链与系统依赖（apk add --no-network）先于一切编译。
    # gd 需要 freetype/jpeg/webp 支持时官方默认配置不带，显式传参补齐
    local configure_gd=""
    case ",$bundled," in *,gd,*) configure_gd="docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-xpm && " ;; esac
    local bundled_install=""
    if [ -n "$bundled" ]; then
      bundled_install="RUN $configure_gd docker-php-ext-install -j\"\$(nproc)\" ${bundled//,/ }"
    fi
    body="COPY apk/ /tmp/apk/
$copy_exts
RUN apk add --no-network /tmp/apk/*.apk
$pecl_loop
$bundled_install"
  else
    body="RUN apk add --no-cache shadow curl
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN apk add --no-cache \$PHPIZE_DEPS $apk_deps
$copy_exts
$pecl_loop
# 重试一次兜底：受限网络下连接被重置是随机的，IPE 幂等可安全重跑（已装扩展会跳过）
RUN if [ -n \"$bundled\" ]; then install-php-extensions ${bundled//,/ } || install-php-extensions ${bundled//,/ }; fi"
  fi
  cat <<DEOF
FROM php:${ver}-fpm-alpine
ARG UID=1000
ARG GID=1000
# APK_MIRRORS：Alpine 镜像源列表（空格分隔，按序故障转移），值截取到 /alpine 含
ARG APK_MIRRORS="https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine"
RUN cp /etc/apk/repositories /tmp/repos.orig && : > /etc/apk/repositories && \
  for m in \$APK_MIRRORS; do case "\$m" in */alpine) : ;; *) m="\$m/alpine" ;; esac; sed "s|https://dl-cdn.alpinelinux.org/alpine|\$m|g" /tmp/repos.orig >> /etc/apk/repositories; done
# 依赖与源码包全部来自宿主机侧本地备份（offline/apk、offline/pecl），构建不依赖容器内网络
$body
RUN usermod -u \${UID} www-data && groupmod -g \${GID} www-data
DEOF
}

# 解析 BUILD_PROXY 为容器可达的最终代理地址，stdout 输出（none 或 http://URL）。
# none=禁用；auto（默认）=探测本地常见代理端口；其余按显式值（host:port 或完整 URL）。
# 代理地址归一化：原生 docker 的构建容器里 host.docker.internal 默认不解析（Desktop VM
# 才内置该域名），换引擎后 pecl 全部死于 DNS——代理指向本机时改写为 docker0 网关 IP
# （容器内零 DNS 可达），取不到再退回域名，并由调用方的 --add-host host-gateway 兜底
_php_resolve_build_proxy() {
  local proxy="${BUILD_PROXY:-auto}"
  if [ "$proxy" = "auto" ]; then proxy=$(_php_detect_build_proxy); fi
  if [ -z "$proxy" ] || [ "$proxy" = "none" ]; then echo "none"; return 0; fi
  case "$proxy" in
    http://*|https://*) : ;;
    *) proxy="http://${proxy}" ;;
  esac
  local proxy_gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  if [ -n "$proxy_gw" ]; then
    proxy="${proxy//127.0.0.1/$proxy_gw}"
    proxy="${proxy//localhost/$proxy_gw}"
  else
    proxy="${proxy//127.0.0.1/host.docker.internal}"
    proxy="${proxy//localhost/host.docker.internal}"
  fi
  echo "$proxy"
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

# 构建失败时彻底删除两个暂存目录（pecl 包与 apk 闭包）：未验证的内容没有备份库正本、
# 命中副本的母本在备份库不受影响，留在磁盘上只是垃圾。暂存标记同步清空，防止后续误晋升
_php_discard_staging() {
  local build_dir=$1
  rm -rf "$build_dir/pecl" "$build_dir/apk"
  _PECL_STAGED=""
}

# 执行镜像构建并收尾：成功→暂存包验证晋升入备份库（pecl + apk 闭包）；
# 失败→彻底删除全部暂存目录后报错退出。
# 二选一是刻意的：失败路径绝不晋升，保证备份库里只有对本 PHP 版本验证可用的内容
_php_docker_build_verified() {
  local img=$1 build_dir=$2 ver=$3 offline=$4
  shift 4
  local build_rc=0
  docker build -t "$img" "$@" "$build_dir" || build_rc=$?
  if [ $build_rc -ne 0 ]; then
    _php_discard_staging "$build_dir"
    error "PHP 镜像构建失败（网络受限时可在 .env 配置 BUILD_PROXY 指向本地 HTTP 代理）"
  fi
  log "PHP ${ver} 镜像构建成功，开始晋升已验证的离线依赖..."
  if [ "$offline" = "1" ]; then
    _php_promote_apk_closure "$ver" "$build_dir/apk"
  else
    log "PHP ${ver} 未使用 APK 离线闭包，跳过 APK 备份库晋升"
  fi
  _php_promote_pecl_tarballs "$ver" "$build_dir/pecl"
  # 晋升完成后清空两个暂存目录：正本在备份库（offline/php/<版本>/），残留只是垃圾，
  # 且 config/php/<版本>/{pecl,apk} 会被 phpbox backup 经 CONFIG_DIR 卷入造成双份冗余。
  # 下次构建会从备份库重新复制，零损失
  rm -rf "$build_dir/pecl" "$build_dir/apk"
}

# 在线路径的 docker build 参数（镜像源预解析注入、代理、no_proxy），stdout 每行一个参数。
# 代理缺省为 none（直连）；镜像源未配置时不注入，apk 走官方源
_php_online_build_args() {
  local proxy=$1 apk_mirror=$2
  if [ -n "$apk_mirror" ]; then
    local apk_mirror_host="${apk_mirror#*://}"; apk_mirror_host="${apk_mirror_host%%/*}"
    local apk_mirror_ip=$(getent ahostsv4 "$apk_mirror_host" 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "$apk_mirror_ip" ]; then echo "--add-host"; echo "$apk_mirror_host:$apk_mirror_ip"; fi
  fi
  if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then
    local no_proxy_host="${apk_mirror#*://}"; no_proxy_host="${no_proxy_host%%/*}"
    echo "--build-arg"; echo "http_proxy=$proxy"
    echo "--build-arg"; echo "https_proxy=$proxy"
    echo "--build-arg"; echo "no_proxy=127.0.0.1,localhost${no_proxy_host:+,$no_proxy_host}"
  fi
  # 兜底：让 host.docker.internal 在原生 docker 的构建容器内也能解析到宿主
  echo "--add-host"; echo "host.docker.internal:host-gateway"
}

_php_build_image() {
  local ver=$1 exts=$2
  local img="${IMAGE_PREFIX}php${ver//./}"
  local build_dir="$CONFIG_DIR/php/$ver"
  mkdir -p "$build_dir"

  _php_split_ext_list "$exts"
  local bundled=$_SPLIT_BUNDLED remote=$_SPLIT_REMOTE
  local deps_union; deps_union=$(_php_ext_apk_deps "$bundled,${remote//.tgz/}")

  local remote_files=""
  if [ -n "$remote" ]; then
    rm -rf "$build_dir/pecl"
    mkdir -p "$build_dir/pecl"
    _php_stage_pecl_tarballs "$ver" "$remote" "$build_dir"
    local tgz
    for tgz in "$build_dir"/pecl/*.tgz; do
      remote_files="$remote_files $(basename "$tgz")"
    done
    remote_files="${remote_files# }"
  fi

  # apk 离线闭包：备份命中或预取成功 → 离线路径；预取失败 → 在线路径兜底。
  # apk 先清空重建：预取容器以 root 写入的历史残留会让宿主 cp 覆盖时权限不足
  local build_args=() offline=0
  rm -rf "$build_dir/apk"
  mkdir -p "$build_dir/apk"
  if _php_stage_apk_closure "$ver" "$deps_union" "$build_dir/apk"; then offline=1; fi
  _php_render_dockerfile "$ver" "$bundled" "$remote_files" $offline > "$build_dir/Dockerfile"

  if [ "$offline" = "1" ]; then
    log "离线构建 PHP $ver：apk 闭包 $(ls "$build_dir/apk" | wc -l) 个包，pecl 包全部本地"
  else
    local proxy; proxy=$(_php_resolve_build_proxy)
    mapfile -t build_args < <(_php_online_build_args "$proxy" "${APK_MIRRORS%% *}")
    if [ "$proxy" != "none" ]; then log "在线构建 PHP $ver（流量经代理: $proxy）"; else log "在线构建 PHP $ver（直连）"; fi
  fi

  log "构建 PHP ${ver} 自定义镜像（扩展: ${exts:-无}）..."
  _php_docker_build_verified "$img" "$build_dir" "$ver" "$offline" \
    --build-arg UID="$CURRENT_UID" \
    --build-arg GID="$CURRENT_GID" \
    --build-arg APK_MIRRORS="$APK_MIRRORS" \
    "${build_args[@]}"

  echo "$img"
}

