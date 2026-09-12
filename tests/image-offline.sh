#!/bin/bash
# 镜像离线事务行为验证（公共层 _ensure_offline_image，mysql/redis 两线共用）：
# 用假 docker / 假 tar 替身钉住路径，不需要真实 Docker 与网络：
#   场景 1：镜像已在本地 → 不 load 不 pull，直接返回镜像名
#   场景 2：离线库命中 → docker load，零 pull；load 后镜像名不匹配 → 拦截报错
#   场景 3：未命中 → docker pull，install 模式回写离线库（save→tar 校验→原子替换）
#   场景 4：preload 模式 → pull 成功但不回写
#   场景 5：redis tag 变体 → redis:8-alpine 的离线库目录是裸版本号 offline/redis/8/
#         （版本与 tag 后缀不同是公共层分参传值的原因，此断言钉住该映射）
#   场景 6：nginx tag 别名 → 离线库目录名就是 tag 本身（alpine/1.25，非数字版本）
#   场景 7：pgsql → postgres:17-alpine 的离线库目录是裸版本号 offline/pgsql/17/
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
mkdir -p "$box/fakebin"

# 假 docker：inspect/pull/load/save 按 FAKE_* 行为走，调用留痕到 $FAKE_DOCKER_LOG。
# 镜像存在性 = 显式预置（FAKE_LOCAL_IMAGES）或本会话已成功 load（状态文件）——
# 对齐真实 docker 语义：load 成功后镜像才出现，load 前后 inspect 结果不同。
# FAKE_LOAD_NOIMAGE=1 模拟"load 成功但 tar 内容与版本目录不匹配"的异常路径
cat > "$box/fakebin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$FAKE_DOCKER_LOG"
cmd="$1"
case "$cmd" in
  image)
    img="$3"
    [ -n "$FAKE_LOCAL_IMAGES" ] && exit 0
    [ -f "$FAKE_LOADED_STATE" ] && grep -qx "$img" "$FAKE_LOADED_STATE" && exit 0
    exit 1 ;;
  load)
    [ -n "$FAKE_LOAD_FAIL" ] && { echo "load: invalid tar" >&2; exit 1; }
    [ -z "$FAKE_LOAD_NOIMAGE" ] && echo "${FAKE_LOAD_IMAGE:-unknown}" >> "$FAKE_LOADED_STATE"
    exit 0 ;;
  pull)
    [ -n "$FAKE_PULL_FAIL" ] && { echo "pull: denied" >&2; exit 1; }
    exit 0 ;;
  save)
    # 对齐真实 docker save：-o 指定的文件必须真实落盘，否则后续 mv/校验测试无物可测
    prev=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && echo "fake-image-tar" > "$a"
      prev="$a"
    done
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$box/fakebin/docker"
# 假 tar：-t 校验按 TAR_FAKE_CORRUPT 决定成败
cat > "$box/fakebin/tar" <<'EOF'
#!/bin/sh
echo "tar $*" >> "$FAKE_DOCKER_LOG"
[ -n "$TAR_FAKE_CORRUPT" ] && exit 1
exit 0
EOF
chmod +x "$box/fakebin/tar"
export FAKE_DOCKER_LOG="$box/docker.calls"
export FAKE_LOADED_STATE="$box/loaded.state"
: > "$FAKE_LOADED_STATE"   # 本会话已成功 load 的镜像清单（替身的 docker 状态记忆）
export PATH="$box/fakebin:$PATH"

source lib/common/log.sh
source lib/common/env.sh
source lib/common/docker.sh          # 公共层：_ensure_offline_image 本体
export OFFLINE_DIR="$box/offline"   # 沙箱离线库，测试后随 trap 清理
source lib/mysql/common/offline.sh  # 薄绑定：mysql:<版本>
source lib/redis/common/offline.sh  # 薄绑定：redis:<版本>-alpine
source lib/nginx/common/offline.sh # 薄绑定：nginx:<tag 别名>
source lib/pgsql/common/offline.sh # 薄绑定：postgres:<版本>-alpine（与 redis 同款版本≠tag）

# ---- 场景 1：镜像已在本地 → 零 load 零 pull ----
rm -f "$FAKE_DOCKER_LOG"
export FAKE_LOCAL_IMAGES=1
out=$(_mysql_ensure_image "ok" "install" 2>"$box/s1.log")
[ "$out" = "mysql:ok" ] && ok "场景1 返回镜像名 mysql:ok" || bad "场景1 返回值异常: $out"
if grep -qE 'docker (load|pull)' "$FAKE_DOCKER_LOG"; then
  bad "场景1 本地已有镜像仍触发 load/pull"
else
  ok "场景1 本地已有镜像零网络"
fi
unset FAKE_LOCAL_IMAGES

# ---- 场景 2a：离线库命中 → load 且零 pull ----
mkdir -p "$OFFLINE_DIR/mysql/hit"
echo fake-tar-body > "$OFFLINE_DIR/mysql/hit/mysql-hit.tar"
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"
export FAKE_LOAD_IMAGE="mysql:hit"
out=$(_mysql_ensure_image "hit" "install" 2>"$box/s2a.log")
[ "$out" = "mysql:hit" ] && ok "场景2a 离线命中返回 mysql:hit" || bad "场景2a 返回值异常: $out（$(cat "$box/s2a.log"）)"
grep -q 'docker load' "$FAKE_DOCKER_LOG" && ok "场景2a 走 docker load" || bad "场景2a 未调用 load"
if grep -q 'docker pull' "$FAKE_DOCKER_LOG"; then bad "场景2a 命中仍 pull"; else ok "场景2a 命中零 pull"; fi
unset FAKE_LOAD_IMAGE

# ---- 场景 2b：load 后镜像名不匹配 → 必须拦截（防离线契约被静默绕过）----
# error() 是 exit 1：必须用子 shell (...) 包住错误路径，否则会杀掉整个测试脚本
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"
FAKE_LOAD_NOIMAGE=1 bash -c 'true' 2>/dev/null
if ( FAKE_LOAD_NOIMAGE=1 _mysql_ensure_image "hit" "install" ) >/dev/null 2>"$box/s2b.log"; then
  bad "场景2b load 后无镜像未拦截"
else
  grep -q '不匹配' "$box/s2b.log" && ok "场景2b load 后镜像缺失被拦截并报错" || bad "场景2b 退出但错误信息不符: $(cat "$box/s2b.log")"
fi

# ---- 场景 3a：未命中 → pull + install 模式回写（save→tar 校验→原子替换）----
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"
export FAKE_LOAD_IMAGE="mysql:miss"   # save 前的存在性复核（真 docker 里 pull 后镜像即在）
out=$(_mysql_ensure_image "miss" "install" 2>"$box/s3a.log")
[ "$out" = "mysql:miss" ] && ok "场景3a 拉取路径返回 mysql:miss" || bad "场景3a 返回值异常: $out（$(cat "$box/s3a.log"）)"
grep -q 'docker pull mysql:miss' "$FAKE_DOCKER_LOG" && ok "场景3a 在线拉取" || bad "场景3a 未调用 pull"
grep -q 'docker save' "$FAKE_DOCKER_LOG" && ok "场景3a 回写执行 docker save" || bad "场景3a 未执行 save"
tarf="$OFFLINE_DIR/mysql/miss/mysql-miss.tar"
[ -f "$tarf" ] && ok "场景3a 镜像 tar 已入离线库（$tarf）" || bad "场景3a 离线库无 tar"
[ -e "$tarf.tmp."* ] && bad "场景3a 存在 tmp 残留: $(ls "$tarf".tmp.* 2>/dev/null)" || ok "场景3a 无 .tmp 残留"

# ---- 场景 3b：tar 校验失败 → 清理临时文件不回写，安装不中断 ----
rm -f "$FAKE_DOCKER_LOG"; rm -f "$tarf"
export TAR_FAKE_CORRUPT=1
out=$(_mysql_ensure_image "miss" "install" 2>"$box/s3b.log")
[ "$out" = "mysql:miss" ] && ok "场景3b 校验失败仍完成镜像获取（回写尽力而为）" || bad "场景3b 返回值异常: $out"
[ ! -f "$tarf" ] && ok "场景3b 校验失败未写坏 tar 进库" || bad "场景3b 坏 tar 进了离线库"
[ ! -e "$tarf.tmp."* ] && ok "场景3b 临时文件已清理" || bad "场景3b tmp 残留"
unset TAR_FAKE_CORRUPT

# ---- 场景 4：preload 模式 → pull 但不回写 ----
rm -f "$FAKE_DOCKER_LOG"
out=$(_mysql_ensure_image "miss" "preload" 2>"$box/s4.log")
grep -q 'docker pull' "$FAKE_DOCKER_LOG" && ok "场景4 preload 仍拉取" || bad "场景4 未拉取"
if grep -q 'docker save' "$FAKE_DOCKER_LOG"; then bad "场景4 preload 不应回写"; else ok "场景4 preload 不回写离线库"; fi

# ---- 场景 5：redis tag 变体 → 离线库目录用裸版本号，tag 带 -alpine 后缀 ----
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"
mkdir -p "$OFFLINE_DIR/redis/8"
echo fake-tar-body > "$OFFLINE_DIR/redis/8/redis-8.tar"
export FAKE_LOAD_IMAGE="redis:8-alpine"
out=$(_redis_ensure_image "8" "install" 2>"$box/s5.log")
[ "$out" = "redis:8-alpine" ] && ok "场景5 redis 返回带 -alpine 的 tag" || bad "场景5 返回值异常: $out（$(cat "$box/s5.log")）"
grep -q 'docker load' "$FAKE_DOCKER_LOG" && ok "场景5 命中走 docker load" || bad "场景5 未调用 load"
if grep -q 'docker pull' "$FAKE_DOCKER_LOG"; then bad "场景5 命中仍 pull"; else ok "场景5 命中零 pull"; fi
unset FAKE_LOAD_IMAGE
# redis 未命中拉取后回写：目录必须落在裸版本号 offline/redis/7/ 而非 7-alpine
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"; rm -rf "$OFFLINE_DIR/redis/7"
FAKE_LOAD_IMAGE="redis:7-alpine" out=$(_redis_ensure_image "7" "install" 2>"$box/s5b.log")
grep -q 'docker pull redis:7-alpine' "$FAKE_DOCKER_LOG" && ok "场景5b 拉取 redis:7-alpine" || bad "场景5b 未拉取正确 tag"
rtarf="$OFFLINE_DIR/redis/7/redis-7.tar"
[ -f "$rtarf" ] && ok "场景5b 回写落在裸版本目录（$rtarf）" || bad "场景5b 离线库路径错误，实际找: $rtarf"

# ---- 场景 6：nginx tag 别名 → 离线库目录名就是 tag 本身（非数字版本） ----
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"
mkdir -p "$OFFLINE_DIR/nginx/alpine"
echo fake-tar-body > "$OFFLINE_DIR/nginx/alpine/nginx-alpine.tar"
export FAKE_LOAD_IMAGE="nginx:alpine"
out=$(_nginx_ensure_image "alpine" "install" 2>"$box/s6.log")
unset FAKE_LOAD_IMAGE
[ "$out" = "nginx:alpine" ] && ok "场景6 nginx 返回 tag 别名" || bad "场景6 返回值异常: $out（$(cat "$box/s6.log")）"
grep -q 'docker load' "$FAKE_DOCKER_LOG" && ok "场景6 命中走 docker load" || bad "场景6 未调用 load"
if grep -q 'docker pull' "$FAKE_DOCKER_LOG"; then bad "场景6 命中仍 pull"; else ok "场景6 命中零 pull"; fi
# 未命中拉取后回写：目录必须落在 tag 名 offline/nginx/1.25/
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"; rm -rf "$OFFLINE_DIR/nginx/1.25"
export FAKE_LOAD_IMAGE="nginx:1.25"
out=$(_nginx_ensure_image "1.25" "install" 2>"$box/s6b.log")
unset FAKE_LOAD_IMAGE
grep -q 'docker pull nginx:1.25' "$FAKE_DOCKER_LOG" && ok "场景6b 拉取 nginx:1.25" || bad "场景6b 未拉取正确 tag"
ntarf="$OFFLINE_DIR/nginx/1.25/nginx-1.25.tar"
[ -f "$ntarf" ] && ok "场景6b 回写落在 tag 目录（$ntarf）" || bad "场景6b 离线库路径错误"

# ---- 场景 7：pgsql 版本≠tag（postgres:17-alpine → offline/pgsql/17/） ----
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"
mkdir -p "$OFFLINE_DIR/pgsql/17"
echo fake-tar-body > "$OFFLINE_DIR/pgsql/17/pgsql-17.tar"
export FAKE_LOAD_IMAGE="postgres:17-alpine"
out=$(_pgsql_ensure_image "17" "install" 2>"$box/s7.log")
[ "$out" = "postgres:17-alpine" ] && ok "场景7 pgsql 返回带 -alpine 的 tag" || bad "场景7 返回值异常: $out（$(cat "$box/s7.log")）"
grep -q 'docker load' "$FAKE_DOCKER_LOG" && ok "场景7 命中走 docker load" || bad "场景7 未调用 load"
if grep -q 'docker pull' "$FAKE_DOCKER_LOG"; then bad "场景7 命中仍 pull"; else ok "场景7 命中零 pull"; fi
unset FAKE_LOAD_IMAGE
# 未命中拉取后回写：目录必须落在裸版本号 offline/pgsql/16/
rm -f "$FAKE_DOCKER_LOG"; : > "$FAKE_LOADED_STATE"; rm -rf "$OFFLINE_DIR/pgsql/16"
export FAKE_LOAD_IMAGE="postgres:16-alpine"
out=$(_pgsql_ensure_image "16" "install" 2>"$box/s7b.log")
grep -q 'docker pull postgres:16-alpine' "$FAKE_DOCKER_LOG" && ok "场景7b 拉取 postgres:16-alpine" || bad "场景7b 未拉取正确 tag"
ptarf="$OFFLINE_DIR/pgsql/16/pgsql-16.tar"
[ -f "$ptarf" ] && ok "场景7b 回写落在裸版本目录（$ptarf）" || bad "场景7b 离线库路径错误"
unset FAKE_LOAD_IMAGE

echo "----------------------------------------"
echo "image-offline: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ] || exit 1
