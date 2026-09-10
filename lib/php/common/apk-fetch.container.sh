#!/bin/sh
# 容器内 apk 下载器脚本（自 build.sh 的 _APK_FETCH_SCRIPT 单引号字符串实体化，内容逐字保留）。
# 由 _apk_ranked_fetch_run 以只读方式挂载为 /apk-fetch.sh 后在预取容器内执行，
# 与 _apk_mirror_host_args、_load_apk_mirrors（lib/common/env.sh）同属 apk 源管理公共层：
# 1) 用前测速：逐源下载 main 索引计时（APK_TIMEOUT 秒上限，超时/失败剔除），按最快优先排序；
# 2) 按测速顺序逐源整批下载：索引获取 APK_TIMEOUT 秒超时；下载期间以 /pkgs 增量 + 容器网卡
#    流量为进度双指标，APK_TIMEOUT 秒无增长 = 无响应，杀掉当前下载自动切换下一个源。
# 闭包必须出自同一源：切换源即清空 /pkgs 重来，避免两个源的版本混装。
# 运行环境是 alpine busybox sh（非 bash）；APK_MIRRORS/APK_TIMEOUT/HOST_UID 经 -e 注入。调用:
#   sh /apk-fetch.sh recursive <包列表...>   # 递归闭包（预取）
#   sh /apk-fetch.sh installed               # 全量已装包（基础包同步）

cp /etc/apk/repositories /tmp/repos.orig
MODE=$1; shift
APK_TIMEOUT="${APK_TIMEOUT:-30}"
VER="v$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)"
case "$VER" in
  v) VER=$(sed -n "s|^https://dl-cdn.alpinelinux.org/alpine/||p" /tmp/repos.orig | head -n1 | cut -d/ -f1) ;;
esac
ARCH=$(uname -m)
RANKED=""
echo "== 初始化 apk 下载器（模式: $MODE，架构: $ARCH，超时: ${APK_TIMEOUT}s）=="
echo "== 源测速（APKINDEX 下载耗时，${APK_TIMEOUT}s 上限）=="
for m in $APK_MIRRORS; do
  start=$(cut -d" " -f1 /proc/uptime)
  if timeout $APK_TIMEOUT wget -T $APK_TIMEOUT -q -O /dev/null "$m/$VER/main/$ARCH/APKINDEX.tar.gz" 2>/dev/null; then
    end=$(cut -d" " -f1 /proc/uptime)
    t=$(awk -v a="$end" -v b="$start" "BEGIN{printf \"%.2f\", a-b}")
    echo "  可用 $m  ${t}s"
    RANKED="$RANKED$t $m
"
  else
    echo "  不可用 $m（超时或失败，跳过）"
  fi
done
if [ -n "$RANKED" ]; then
  ORDER=$(printf "%s" "$RANKED" | sort -n | cut -d" " -f2-)
else
  echo "全部源测速失败，退回配置顺序尝试"
  ORDER="$APK_MIRRORS"
fi
n=0
total=$(printf "%s" "$ORDER" | grep -c .)
for m in $ORDER; do
  n=$((n+1))
  echo "== 尝试源 $n/$total: $m =="
  { echo "$m/$VER/main"; echo "$m/$VER/community"; } > /etc/apk/repositories
  # 索引获取：瞬时失败很常见（间歇性网络），重试 3 次；彻底失败仍不放弃该源——
  # 交给 fetch 解析检验（community 缺索引只影响 community 包，main 包照常解析）
  u=1
  while [ $u -le 3 ]; do
    echo "  获取 apk 索引（第 $u/3 次，最长 ${APK_TIMEOUT}s）..."
    if timeout $APK_TIMEOUT apk update >/dev/null 2>&1; then
      echo "  apk 索引获取完成"
      break
    fi
    u=$((u+1))
    [ $u -le 3 ] && { echo "  索引获取失败，重试 $u/3"; sleep 2; }
  done
  [ $u -gt 3 ] && echo "  警告：部分索引获取失败，仍尝试解析下载"
  # 清空仅在递归闭包模式下发生（换源即重来，闭包必须出自同一源）；
  # installed（基础包同步）是增量补充——曾因清空对两种模式都生效，把预取闭包删得只剩
  # 基础镜像自带包（41 个），离线构建 phpize 报 Cannot find autoconf
  case "$MODE" in
    recursive) rm -f /pkgs/*.apk 2>/dev/null; echo "  开始递归下载构建依赖（目标包: $#，输出目录: /pkgs）"; apk fetch --recursive -o /pkgs shadow curl $PHPIZE_DEPS "$@" & ;;
    installed) echo "  开始同步基础镜像已安装包（输出目录: /pkgs）"; apk fetch -o /pkgs $(apk info -q) & ;;
  esac
  apid=$!
  last="$(du -sk /pkgs 2>/dev/null | cut -f1) $(grep "^ *eth0:" /proc/net/dev | awk "{print \$2}")"
  stall=0
  dead=""
  started=$(cut -d" " -f1 /proc/uptime)
  while kill -0 $apid 2>/dev/null; do
    sleep 5
    cur="$(du -sk /pkgs 2>/dev/null | cut -f1) $(grep "^ *eth0:" /proc/net/dev | awk "{print \$2}")"
    now=$(cut -d" " -f1 /proc/uptime)
    elapsed=$(awk -v a="$now" -v b="$started" "BEGIN{printf \"%.0f\", a-b}")
    echo "  下载进行中：已耗时 ${elapsed}s，文件 ${cur%% *} KiB，网卡接收 ${cur##* } KiB"
    if [ "$cur" = "$last" ]; then
      stall=$((stall+5))
      [ $stall -ge $APK_TIMEOUT ] && { dead=1; break; }
    else
      stall=0; last="$cur"
    fi
  done
  if [ -n "$dead" ]; then
    kill $apid 2>/dev/null
    wait $apid 2>/dev/null
    echo "  ${APK_TIMEOUT} 秒无响应，停止并切换下一个源"
    continue
  fi
  if wait $apid; then
    # apk fetch 可能对"无法解析"静默返回 0 且零下载（实测：community 索引缺失时整单
    # 放弃仍退出 0）——按内容验收：phpize 工具链必须落地，缺失视作该源失败换下一个
    # （与宿主侧 _php_apk_closure_verify 同一套清单，双端把关）
    verify=1
    for t in autoconf gcc g++ make pkgconf re2c musl-dev linux-headers file dpkg; do
      ls /pkgs/$t-*.apk >/dev/null 2>&1 || { verify=0; break; }
    done
    if [ "$verify" = 1 ]; then
      count=$(find /pkgs -maxdepth 1 -name "*.apk" -type f 2>/dev/null | wc -l)
      size=$(du -sh /pkgs 2>/dev/null | cut -f1)
      echo "== 源 $m 下载完成（$count 个包，$size）=="
      OK=1
      break
    fi
    echo "  该源闭包不完整（缺构建工具），换下一个源"
    continue
  fi
  echo "  下载失败，换下一个源"
done
if [ "$OK" = 1 ]; then
  chown -R "$HOST_UID:$HOST_UID" /pkgs 2>/dev/null || true
  exit 0
fi
echo "全部源均失败"
exit 1
