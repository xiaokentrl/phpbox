#!/bin/bash
# offline-first 行为验证：PECL 暂存备份优先（优化切片 C）+ 代理解析收敛（优化切片 D）
# 场景 1：offline 库全命中 → 全程零网络（curl 替身被调即留痕，断言零痕迹）
#         ——同时验证 BUILD_PROXY=auto 时代理探测也被跳过（探测本身用 curl）
# 场景 2：仅 xdebug 缺失 → 只有 xdebug 触网一次并正确进入晋升集，其余走备份
# 场景 3：代理解析公共前段——宿主侧（base，pecl 预下载）与容器侧（resolve，docker build）
#         的语义边界：base 不做 docker0 改写，resolve 必须改写 loopback 并补 scheme
# 运行前提：不需要 Docker、不需要真实网络；curl/ip 全程为 PATH 注入的替身
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

source lib/common/log.sh          # log/error：被测函数的依赖
source lib/php/common/apk-fetch.sh   # 与真实加载链同序（downloader → offline）
source lib/php/common/offline.sh  # 被测层：PECL 暂存/晋升 + 代理解析（优化切片 A 拆分后所在）
source lib/php/common/build.sh    # 编排层也一并加载，保持与 bin/phpbox 装载形态一致

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT

# curl 替身：记录每次调用；伪造 -w url_effective（stdout）与 -o 落盘
mkdir -p "$box/fakebin"
cat > "$box/fakebin/curl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_CURL_LOG"
out=""; url=""; prev=""; wantwrite=0
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -w) wantwrite=1 ;; esac
  prev="$a"
  case "$a" in -*) : ;; *) url="$a" ;; esac
done
# -w 才回显 url_effective（下载路径捕获用）；探测路径只传 -o /dev/null 无 -w，
# 喷内容会污染探测函数命令替换的返回值
if [ "$wantwrite" = 1 ]; then
  case "$url" in
    */get/xdebug) echo "https://pecl.php.net/get/xdebug-6.0.2.tgz" ;;
    *) echo "$url" ;;
  esac
fi
[ -n "$out" ] && echo "fake-tgz-body" > "$out"
exit 0
EOF
chmod +x "$box/fakebin/curl"
export FAKE_CURL_LOG="$box/curl.calls"

# ---- 场景 1：全命中 → 零网络（BUILD_PROXY 留空=auto，验证探测也被跳过）----
export OFFLINE_DIR="$box/offline"
mkdir -p "$OFFLINE_DIR/php/8.4/pecl"
echo body-imagick > "$OFFLINE_DIR/php/8.4/pecl/imagick-3.8.0.tgz"   # 带版本键
echo body-redis   > "$OFFLINE_DIR/php/8.4/pecl/redis.tgz"            # 旧式无版本键
echo body-xdebug  > "$OFFLINE_DIR/php/8.4/pecl/xdebug-3.1.6.tgz"
work1="$box/work1"; mkdir -p "$work1/pecl"
rm -f "$FAKE_CURL_LOG"
PATH="$box/fakebin:$PATH" _php_stage_pecl_tarballs 8.4 "imagick xdebug redis" "$work1" >"$box/s1.log" 2>&1

if [ -e "$FAKE_CURL_LOG" ]; then
  bad "场景1 全命中仍触网，curl 调用: $(tr '\n' ';' < "$FAKE_CURL_LOG")"
else
  ok "场景1 全命中零网络（curl 未被调用，含代理探测）"
fi
[ -s "$work1/pecl/imagick-3.8.0.tgz" ] && ok "场景1 imagick（glob 带版本键）命中落盘" || bad "场景1 imagick 未落盘"
[ -s "$work1/pecl/redis.tgz" ]        && ok "场景1 redis（精确旧式键）命中落盘"       || bad "场景1 redis 未落盘"
[ -s "$work1/pecl/xdebug-3.1.6.tgz" ] && ok "场景1 xdebug 命中落盘"                  || bad "场景1 xdebug 未落盘"
[ -z "${_PECL_STAGED:-}" ] && ok "场景1 暂存集为空（无可晋升新包）" || bad "场景1 暂存集应为空，实际: $_PECL_STAGED"

# ---- 场景 2：仅 xdebug 缺失 → 只有它触网一次（BUILD_PROXY=none 跳过探测，隔离被测行为）----
rm -f "$OFFLINE_DIR/php/8.4/pecl/xdebug-3.1.6.tgz"
work2="$box/work2"; mkdir -p "$work2/pecl"
rm -f "$FAKE_CURL_LOG"
export BUILD_PROXY=none
PATH="$box/fakebin:$PATH" _php_stage_pecl_tarballs 8.4 "imagick xdebug redis" "$work2" >"$box/s2.log" 2>&1

calls=$(wc -l < "$FAKE_CURL_LOG" 2>/dev/null || echo 0)
[ "$calls" = "1" ] && ok "场景2 仅 1 次 curl 调用（缺失的 xdebug）" || bad "场景2 curl 调用 $calls 次（应 1 次）"
[ -s "$work2/pecl/xdebug-6.0.2.tgz" ] && ok "场景2 xdebug 下载暂存（url_effective 命名）" || bad "场景2 xdebug 未暂存"
[ -s "$work2/pecl/imagick-3.8.0.tgz" ] && ok "场景2 imagick 仍走备份（未重复下载）"       || bad "场景2 imagick 未命中"
[ -z "${_PECL_STAGED:-}" ] && { bad "场景2 暂存集为空（xdebug 应入晋升集）"; }
[ "$_PECL_STAGED" = "xdebug-6.0.2.tgz" ] && ok "场景2 暂存集只含新下载包" || bad "场景2 暂存集: $_PECL_STAGED"

# ---- 场景 3：代理解析公共前段（优化切片 D）——base/resolve 语义边界 ----
# 前两个场景用"命令前缀 PATH"注入替身；本场景直接调用解析函数，须显式导出。
# ip 替身：-o 形式给 detect 用（$4 取地址），无 -o 形式给 resolve 用（$2 取地址）
export PATH="$box/fakebin:$PATH"
cat > "$box/fakebin/ip" <<'EOF'
#!/bin/sh
case " $* " in
  *" -o "*) echo "2: docker0 inet 172.17.0.1/16" ;;
  *) echo "    inet 172.17.0.1/16 scope global docker0" ;;
esac
EOF
chmod +x "$box/fakebin/ip"

export BUILD_PROXY=none
[ "$(_php_resolve_build_proxy_base)" = "none" ] && ok "场景3 base: none → none" || bad "场景3 base: none 应输出 none"
[ "$(_php_resolve_build_proxy)" = "none" ] && ok "场景3 resolve: none → none" || bad "场景3 resolve: none 应输出 none"

export BUILD_PROXY=127.0.0.1:7890
[ "$(_php_resolve_build_proxy_base)" = "127.0.0.1:7890" ] \
  && ok "场景3 base: 显式 loopback 原样（宿主侧直达，不做 docker0 改写）" \
  || bad "场景3 base: 显式值被改写: $(_php_resolve_build_proxy_base)"
[ "$(_php_resolve_build_proxy)" = "http://172.17.0.1:7890" ] \
  && ok "场景3 resolve: loopback 改写为 docker0 网关 + 补 scheme" \
  || bad "场景3 resolve: 容器侧改写错误: $(_php_resolve_build_proxy)"

export BUILD_PROXY=auto
rm -f "$FAKE_CURL_LOG"
[ "$(_php_resolve_build_proxy_base)" = "http://172.17.0.1:10809" ] \
  && ok "场景3 base: auto 经 curl 替身探测命中首个端口 10809" \
  || bad "场景3 base: auto 探测结果错误: $(_php_resolve_build_proxy_base)"

export BUILD_PROXY=http://10.0.0.5:8888
[ "$(_php_resolve_build_proxy)" = "http://10.0.0.5:8888" ] \
  && ok "场景3 resolve: 非本机显式代理原样（不误改写）" \
  || bad "场景3 resolve: 非本机代理被误改写: $(_php_resolve_build_proxy)"

echo "----------------------------------------"
echo "offline-first: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ] || exit 1
