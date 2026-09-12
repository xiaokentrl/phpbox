#!/bin/bash
# backup/restore 行为验证（修复切片：数据库数据目录容器化打包）
# 用状态记忆型假 docker + 沙箱目录钉住机制，不需要真实 Docker/数据库：
#   1. backup：mysql/pgsql 数据目录走容器 root 打包（外层归档只见成员 tar，无裸数据路径）
#   2. backup：停服覆盖 pgsql 新线；结束后三线容器均被重启；BASE_DIR 无成员 tar 残留
#   3. restore：成员 tar 借容器解回绝对路径（数据文件复位）、卷内容复位
#   4. restore：含 .. 的归档被拒绝且不落盘；成员 tar 路径越界被拒绝
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
mkdir -p "$box/fakebin"

# 假 docker：record 一切调用；按挂载点伪装出 容器内 root 打包/解包 的语义——
# 沙箱文件宿主可读，故用宿主 tar 真实生成/解出成员 tar，测试产物真实可用
cat > "$box/fakebin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$FAKE_DOCKER_LOG"
cmd=$1; shift
case "$cmd" in
  info) exit 0 ;;
  inspect) echo "true"; exit 0 ;;
  stop)  echo "$1" >> "$FAKE_STOP_LOG";  exit 0 ;;
  start) echo "$1" >> "$FAKE_START_LOG"; exit 0 ;;
  ps) exit 0 ;;
  volume)
    case "$1" in ls) echo "$FAKE_VOLUME_NAME" ;; create) : ;; esac
    exit 0 ;;
  run)
    argv=("$@")
    image_idx=-1; m_host=""; m_backup=""; m_vol=""; m_target=""
    for i in "${!argv[@]}"; do
      a="${argv[$i]}"
      if [ "$prev" = "-v" ]; then
        case "$a" in
          /:/host*)  m_host=1 ;;
          *:/backup*) m_backup="${a%%:*}" ;;
          *:/source*) m_vol="${a%%:*}" ;;
          *:/target*) m_target="${a%%:*}" ;;
        esac
      fi
      prev="$a"
      [ "$a" = "alpine" ] && { image_idx=$((i+1)); break; }
    done
    [ "$image_idx" -lt 0 ] && exit 0
    rest=("${argv[@]:$image_idx}")
    op="$(${rest[@]:0:2} 2>/dev/null || echo "${rest[0]} ${rest[1]}")"
    if [ "$op" = "tar czf" ]; then
      out="${rest[2]}"; name=$(basename "$out")
      if [ -n "$m_vol" ]; then
        tar czf "$m_backup/$name" -C "$FAKE_VOL_SRC" .
      elif [ -n "$m_host" ]; then
        for i in "${!rest[@]}"; do [ "${rest[$i]}" = "-C" ] && { c_idx=$((i+1)); break; }; done
        path="${rest[$((c_idx+1))]}"
        tar czf "$m_backup/$name" -C / "$path"
      fi
    elif [[ "$op" == "tar xz"* ]]; then
      in_f="${rest[2]}"
      for i in "${!rest[@]}"; do [ "${rest[$i]}" = "-C" ] && { c_idx=$((i+1)); break; }; done
      dest="${rest[$c_idx]}"
      case "$dest" in
        /target) tar xzPf "$m_backup/$(basename "$in_f")" -C "$FAKE_VOL_SRC" ;;
        /host)   tar xzPf "$m_backup/$(basename "$in_f")" -C / --no-same-owner --no-same-permissions ;;
      esac
    fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$box/fakebin/docker"
export FAKE_DOCKER_LOG="$box/docker.calls"
export FAKE_STOP_LOG="$box/stop.calls"
export FAKE_START_LOG="$box/start.calls"
export FAKE_VOLUME_NAME="phpbox_redis8_data"
export FAKE_VOL_SRC="$box/volsrc"
mkdir -p "$FAKE_VOL_SRC"
echo vol-data > "$FAKE_VOL_SRC/dump.rdb"
export PATH="$box/fakebin:$PATH"

# 环境：先加载默认，再整体指向沙箱（顺序反了会被 env.sh 默认值盖回真实目录）
source lib/common/log.sh
source lib/common/paths.sh
source lib/common/env.sh
export PROJECT_NAME=phpbox
export PGSQL_SERVICE_PREFIX=pg   # 真实链路由 load_env 设默认；测试不调 load_env 须自设
BASE_DIR="$box/root"
ENV_FILE="$BASE_DIR/.env";      mkdir -p "$BASE_DIR";      echo "K=V" > "$ENV_FILE"
CONFIG_DIR="$BASE_DIR/config";  mkdir -p "$CONFIG_DIR/php/8.4"; echo ini > "$CONFIG_DIR/php/8.4/php.ini"
OFFLINE_DIR="$BASE_DIR/offline"; mkdir -p "$OFFLINE_DIR/php/8.4/pecl"; echo pkg > "$OFFLINE_DIR/php/8.4/pecl/x.tgz"
BACKUP_DIR="$BASE_DIR/backups"; mkdir -p "$BACKUP_DIR"
EXT_DIR="$BASE_DIR/compose/services"; mkdir -p "$EXT_DIR"
WWW_ROOT="$box/www"   # 不创建：验证缺失目录被跳过
MYSQL_DATA_ROOT="$box/mysql-data";   mkdir -p "$MYSQL_DATA_ROOT/8.4";   echo db > "$MYSQL_DATA_ROOT/8.4/ibdata1"
PGSQL_DATA_ROOT="$box/pgsql-data";   mkdir -p "$PGSQL_DATA_ROOT/17/data"; echo pg > "$PGSQL_DATA_ROOT/17/data/PG_VERSION"
# 三个服务的 yml 存根：驱动 _phpbox_stop_svc 的容器枚举（容器名由通用命名规则派生）
for svc_ver in mysql-8.4 pgsql-17 redis-8; do echo "services:" > "$EXT_DIR/$svc_ver.yml"; done

source lib/backup/common/backup.sh
source lib/backup/common/restore.sh
source lib/backup/cli.sh

# ---- 场景 1：backup 全流程 ----
# 子壳运行：cmd_backup 会设置自己的 EXIT trap，不能顶掉测试的清理 trap
( cmd_backup ) >"$box/backup.log" 2>&1
f=$(ls "$BACKUP_DIR"/backup*.tar.gz 2>/dev/null | head -1)
[ -n "$f" ] && ok "场景1 备份归档生成: $(basename "$f")" || bad "场景1 归档未生成"

members=$(tar -tzf "$f")
echo "$members" | grep -q "^${BASE_DIR#/}/.env$" && ok "场景1 .env 入档" || bad "场景1 .env 缺失"
echo "$members" | grep -q 'phpbox-dbdata-mysql.tar.gz'  && ok "场景1 mysql 成员 tar 入档"  || bad "场景1 mysql 成员缺失"
echo "$members" | grep -q 'phpbox-dbdata-pgsql.tar.gz'  && ok "场景1 pgsql 成员 tar 入档"  || bad "场景1 pgsql 成员缺失"
echo "$members" | grep -q 'phpbox_redis8_data.tar.gz'   && ok "场景1 redis 卷 tar 入档"    || bad "场景1 卷 tar 缺失"
if echo "$members" | grep -q 'mysql-data/8.4/ibdata1'; then
  bad "场景1 裸数据文件直接进了外层归档（应只走成员 tar）"
else
  ok "场景1 外层归档无裸数据路径（容器打包机制生效）"
fi
grep -q 'docker run.*dbdata-mysql' "$FAKE_DOCKER_LOG" && ok "场景1 mysql 数据借容器打包" || bad "场景1 未走容器打包"
if grep -q 'mysql84' "$FAKE_STOP_LOG" && grep -q 'pg17' "$FAKE_STOP_LOG" && grep -q 'redis8' "$FAKE_STOP_LOG"; then
  ok "场景1 停服覆盖 mysql/pgsql/redis 三线"
else
  bad "场景1 停服不完整: $(cat "$FAKE_STOP_LOG" 2>/dev/null | tr '\n' ' ')"
fi
if grep -q 'mysql84' "$FAKE_START_LOG" && grep -q 'pg17' "$FAKE_START_LOG"; then
  ok "场景1 结束后被停容器全部重启"
else
  bad "场景1 有容器未重启"
fi
[ -e "$BASE_DIR"/phpbox-dbdata-*.tar.gz ] && bad "场景1 BASE_DIR 残留成员 tar" || ok "场景1 成员 tar 已清理"

# ---- 场景 2：restore 全流程（-y 非交互）----
rm -f "$MYSQL_DATA_ROOT/8.4/ibdata1" "$PGSQL_DATA_ROOT/17/data/PG_VERSION" "$FAKE_VOL_SRC/dump.rdb"
cmd_restore "$f" -y >"$box/restore.log" 2>&1
[ -f "$MYSQL_DATA_ROOT/8.4/ibdata1" ] && ok "场景2 mysql 数据经容器解回复位" || bad "场景2 mysql 数据未复位"
[ -f "$PGSQL_DATA_ROOT/17/data/PG_VERSION" ] && ok "场景2 pgsql 数据经容器解回复位" || bad "场景2 pgsql 数据未复位"
[ -f "$FAKE_VOL_SRC/dump.rdb" ] && ok "场景2 redis 卷内容复位" || bad "场景2 卷内容未复位"
grep -q 'dbdata-mysql' "$FAKE_DOCKER_LOG" && grep -q 'xzPf' "$FAKE_DOCKER_LOG" && ok "场景2 成员 tar 走容器解包" || bad "场景2 未走容器解包"
[ -e "$BASE_DIR"/phpbox-dbdata-*.tar.gz ] && bad "场景2 成员 tar 未清理" || ok "场景2 成员 tar 用后即清"

# ---- 场景 3：危险归档拒绝（含 .. 的成员）----
badf="$box/bad.tar.gz"
python3 - "$badf" <<'PYEOF'
import tarfile, sys
with tarfile.open(sys.argv[1], 'w:gz') as t:
    import io
    info = tarfile.TarInfo('../evil.txt')
    data = b'evil'
    info.size = len(data)
    t.addfile(info, io.BytesIO(data))
PYEOF
if ( cmd_restore "$badf" -y ) >/dev/null 2>&1; then
  bad "场景3 含 .. 归档未被拒绝"
else
  [ ! -e "$BASE_DIR/evil.txt" ] && [ ! -e /tmp/evil.txt ] && ok "场景3 含 .. 归档被拒绝且未落盘" || bad "场景3 拒绝了但落了盘"
fi

# ---- 场景 4：成员 tar 路径越界拒绝（外层成员路径合法、内容越界）----
mkdir -p "$box/stage" "$box/smuggle/home/x"
echo evil > "$box/smuggle/home/x/evil.txt"
tar czf "$box/stage/phpbox-dbdata-mysql.tar.gz" -C "$box/smuggle" home/x
tar czf "$box/bad2.tar.gz" -C "$box/stage" phpbox-dbdata-mysql.tar.gz
if ( cmd_restore "$box/bad2.tar.gz" -y ) >/dev/null 2>&1; then
  bad "场景4 越界成员 tar 未被拦截"
else
  [ ! -e /home/x/evil.txt ] && [ ! -e "$box/home/x/evil.txt" ] && ok "场景4 越界成员 tar 被拒绝" || bad "场景4 拒绝了但解了包"
fi

echo "----------------------------------------"
echo "backup: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ] || exit 1
