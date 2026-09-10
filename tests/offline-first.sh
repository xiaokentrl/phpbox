#!/bin/bash
# offline-first 行为验证：PECL 暂存备份优先（优化切片 C）
# 场景 1：offline 库全命中 → 全程零网络（curl 替身被调即留痕，断言零痕迹）
#         ——同时验证 BUILD_PROXY=auto 时代理探测也被跳过（探测本身用 curl）
# 场景 2：仅 xdebug 缺失 → 只有 xdebug 触网一次并正确进入晋升集，其余走备份
# 运行前提：不需要 Docker、不需要真实网络；curl 全程为 PATH 注入的替身
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

source lib/common/log.sh          # log/error：被测函数的依赖
source lib/php/common/build.sh    # 仅加载函数定义，不执行任何动作

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT

# curl 替身：记录每次调用；伪造 -w url_effective（stdout）与 -o 落盘
mkdir -p "$box/fakebin"
cat > "$box/fakebin/curl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_CURL_LOG"
out=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  prev="$a"
  case "$a" in -*) : ;; *) url="$a" ;; esac
done
case "$url" in
  */get/xdebug) echo "https://pecl.php.net/get/xdebug-6.0.2.tgz" ;;
  *) echo "$url" ;;
esac
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

echo "----------------------------------------"
echo "offline-first: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ] || exit 1
