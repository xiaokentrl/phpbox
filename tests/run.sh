#!/bin/bash
# phpbox 行为回归测试。
# 不需要 Docker daemon：compose 配置用 `config` 渲染断言，镜像构建/配置提取用桩替代。
# 用法: bash tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# assert_contains <描述> <内容> <子串>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1（缺少: $3）"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1（不应出现: $3）"; fi
}
# assert_cmd_error <描述> <期望错误信息片段> <命令...>
assert_cmd_error() {
  local desc=$1 expect=$2
  shift 2
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" == *"$expect"* ]]; then
    ok "$desc"
  else
    bad "$desc（rc=$rc, 输出: ${out:0:80}）"
  fi
}

echo "== 准备假 HOME 环境 =="
export HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/phpbox/compose/services"
cat > "$HOME/phpbox/compose/docker-compose.yml" <<'EOF'
networks:
  net:
    driver: bridge
    name: ${NETWORK_NAME:-phpboxnet}
EOF
cat > "$HOME/phpbox/.env" <<EOF
PROJECT_NAME=phpbox
WWW_ROOT=$HOME/www
NGINX_PORT=80
MYSQL_DATA_ROOT=$HOME/mysql-custom
EOF
mkdir -p "$HOME/phpbox/state" "$HOME/phpbox/config" "$HOME/www" "$HOME/mysql-custom"
echo "PHP_EXTENSIONS=gd,redis" > "$HOME/phpbox/state/php-84-extensions.env"

# 载入真实库；桩掉需要拉镜像/构建的部分
source "$ROOT/lib/common.sh"
source "$ROOT/lib/build.sh"
source "$ROOT/lib/php.sh"
source "$ROOT/lib/mysql.sh"
source "$ROOT/lib/redis.sh"
source "$ROOT/lib/nginx.sh"
source "$ROOT/lib/site.sh"
source "$ROOT/lib/backup.sh"
_php_build_image() { echo "stub-image"; }
init_config_files() { :; }
# 本套件不依赖 daemon（compose config 是纯客户端渲染），桩掉 daemon 预检以维持该契约
require_docker() { :; }
# common.sh 的 source-time trap（半安装回滚）会覆盖套件的清理 trap——source 后重设，
# 否则每次测试运行泄漏整个临时 HOME（/tmp/tmp.XXX 含完整 phpbox 夹具）
trap 'rm -rf "$HOME"' EXIT
load_env

echo "== 1. 生成服务 yml 并渲染（路径解析/环境变量/卷名）=="
_php_generate_compose 8.4
_mysql_generate_compose 8.4
_redis_generate_compose 7.4
_nginx_generate_compose

PHP_CONF=$(run_compose php 8.4 config)
assert_contains "php: php.ini 挂载到 phpbox 内" "$PHP_CONF" "source: $HOME/phpbox/config/php/8.4/php.ini"
assert_contains "php: 日志目录挂载到 phpbox 内" "$PHP_CONF" "source: $HOME/phpbox/logs/php"
assert_contains "php: WWW_ROOT 来自 .env" "$PHP_CONF" "source: $HOME/www"
assert_not_contains "php: 渲染结果无 ESC 控制字符（日志不得污染 yml）" "$PHP_CONF" $'\x1b'

MYSQL_CONF=$(run_compose mysql 8.4 config)
assert_contains "mysql: MYSQL_DATA_ROOT 来自 .env（可配置）" "$MYSQL_CONF" "source: $HOME/mysql-custom/8.4"
assert_contains "mysql: my.cnf 挂载到 phpbox 内" "$MYSQL_CONF" "source: $HOME/phpbox/config/mysql/8.4/my.cnf"
assert_contains "mysql: entrypoint 启动前清理残留 socket" "$MYSQL_CONF" "rm -f /var/lib/mysql/mysql.sock"
assert_contains "mysql: entrypoint 以 exec 交接保持 PID 1" "$MYSQL_CONF" "exec docker-entrypoint.sh mysqld"

REDIS_CONF=$(run_compose redis 7.4 config)
assert_contains "redis: 卷名无项目名双重前缀" "$REDIS_CONF" "name: phpbox_redis74_data"
assert_not_contains "redis: 不应出现双重前缀卷名" "$REDIS_CONF" "phpbox_phpbox"

NGINX_CONF=$(run_compose nginx default config)
assert_contains "nginx: nginx.conf 挂载到 phpbox 内" "$NGINX_CONF" "source: $HOME/phpbox/config/nginx/alpine/nginx.conf"
assert_contains "nginx: sites 目录挂载到 phpbox 内" "$NGINX_CONF" "source: $HOME/phpbox/config/nginx/sites"
assert_contains "nginx: 日志目录挂载到 phpbox 内" "$NGINX_CONF" "source: $HOME/phpbox/logs/nginx"

# PHP Dockerfile 渲染：镜像源/依赖顺序须落在生成物上。
# 注意：PEAR 代理配置已由 IPE 自管（手写 config-set 会因 scheme 解析损坏代理），
# 此处反向断言其不存在，防止回归
DOCKERFILE_TXT=$(_php_render_dockerfile 8.4 "gd,redis" "" 0)
assert_contains "php: Dockerfile 多镜像源 repositories" "$DOCKERFILE_TXT" 'for m in $APK_MIRRORS'
assert_not_contains "php: Dockerfile 不应手写 PEAR 代理配置（IPE 自管）" "$DOCKERFILE_TXT" 'pear config-set http_proxy'
assert_contains "php: 扩展列表展开为多参数" "$DOCKERFILE_TXT" "install-php-extensions gd redis"
assert_contains "php: UID/GID 保持构建时取值" "$DOCKERFILE_TXT" "usermod -u \${UID}"

# 站点目录必须与 Nginx 版本解耦：换 tag 只换主配置目录，sites 挂载点一字不变
NGINX_VERSION=1.30
_nginx_generate_compose
NGINX_YML_130=$(cat "$HOME/phpbox/compose/services/nginx-default.yml")
assert_contains "nginx: 换版本后主配置目录随版本" "$NGINX_YML_130" "./config/nginx/1.30/nginx.conf"
assert_contains "nginx: 换版本后镜像 tag 随版本" "$NGINX_YML_130" "image: nginx:1.30"
assert_contains "nginx: 换版本后 sites 挂载不变" "$NGINX_YML_130" "./config/nginx/sites:/etc/nginx/sites:ro"
assert_not_contains "nginx: 版本目录下不出现 sites" "$NGINX_YML_130" "./config/nginx/1.30/sites"

# 主配置注入 sites include：位置在 conf.d 之后、且重复执行不累积
INJ=$(mktemp)
cat > "$INJ" <<'EOF'
user  nginx;
http {
    include       /etc/nginx/mime.types;
    include       /etc/nginx/conf.d/*.conf;
}
EOF
_nginx_inject_sites_include "$INJ"
INJ_TXT=$(cat "$INJ")
assert_contains "nginx: 注入站点 include" "$INJ_TXT" "include /etc/nginx/sites/*.conf;"
INJ_CONFD_LINE=$(grep -n 'conf\.d/\*\.conf;' "$INJ" | head -1 | cut -d: -f1)
INJ_SITES_LINE=$(grep -n 'sites/\*\.conf;' "$INJ" | head -1 | cut -d: -f1)
if [ -n "$INJ_CONFD_LINE" ] && [ -n "$INJ_SITES_LINE" ] && [ "$INJ_SITES_LINE" -gt "$INJ_CONFD_LINE" ]; then
  ok "nginx: sites include 位于 conf.d 之后"
else
  bad "nginx: sites include 位置错误（conf.d=$INJ_CONFD_LINE sites=$INJ_SITES_LINE）"
fi

_nginx_inject_sites_include "$INJ"
_nginx_inject_sites_include "$INJ"
INJ_CNT=$(grep -c 'sites/\*\.conf;' "$INJ")
if [ "$INJ_CNT" -eq 1 ]; then ok "nginx: 重复注入不产生重复 include"; else bad "nginx: 注入不幂等（出现 $INJ_CNT 条）"; fi

# 旧写法/不同缩进的历史注入行应被清理，只保留权威写法
OLD=$(mktemp)
printf 'http {\n\tinclude /etc/nginx/sites/*.conf;\n    include  /etc/nginx/legacy-sites/*.conf;\n}\n' > "$OLD"
_nginx_inject_sites_include "$OLD"
OLD_TXT=$(cat "$OLD")
assert_not_contains "nginx: 清理历史 sites 注入行" "$OLD_TXT" "legacy-sites"
if [ "$(grep -c 'sites/\*\.conf;' "$OLD")" -eq 1 ]; then ok "nginx: 清理后仅保留一条 sites include"; else bad "nginx: 清理后仍有多条 sites include"; fi
rm -f "$INJ" "$OLD"

# 版本漂移：.env 改了 NGINX_VERSION 但 yml 未重建时，校验必须以 yml 里实际 tag 为准
NGINX_VERSION=1.30
_nginx_generate_compose
NGINX_VERSION=alpine
if [ "$(_nginx_effective_version)" = "1.30" ]; then
  ok "nginx: 已安装实例的版本优先于 .env（防漂移）"
else
  bad "nginx: 版本漂移校验失败（effective=$(_nginx_effective_version)，期望 1.30）"
fi
rm -f "$HOME/phpbox/compose/services/nginx-default.yml"
if [ "$(_nginx_effective_version)" = "alpine" ]; then
  ok "nginx: 未安装时回退 NGINX_VERSION"
else
  bad "nginx: 未安装时回退失败（effective=$(_nginx_effective_version)）"
fi
# 恢复默认版本，避免影响后续用例
_nginx_generate_compose

# NGINX_VERSION 会被拼进目录/yml/docker 命令，注入字符必须在 load_env 即被拒绝
assert_cmd_error "nginx: 含分号的 NGINX_VERSION 被拒" "无效的 NGINX_VERSION" \
  env NGINX_VERSION='1.30; rm -rf /' bash -c "source '$ROOT/lib/common.sh'; load_env"
assert_cmd_error "nginx: 含路径穿越的 NGINX_VERSION 被拒" "无效的 NGINX_VERSION" \
  env NGINX_VERSION='../etc' bash -c "source '$ROOT/lib/common.sh'; load_env"

# daemon 未运行时（本沙箱即如此）必须给出明确的启动指引，而不是伪装成"配置验证失败"
if command -v docker &>/dev/null && ! docker info &>/dev/null; then
  assert_cmd_error "daemon 未运行时给出明确报错" "Docker daemon 未运行" \
    bash -c "source '$ROOT/lib/common.sh'; require_docker"
else
  echo "  - Docker daemon 运行中，跳过 daemon-down 用例"
fi

echo "== 2. 站点模板求值 + switch/list 解析 =="
T=$(mktemp -d)
site=demo.test
php_key=php84
eval "$(sed -n "/local new_conf=\"server {/,/^}\"/p" "$ROOT/lib/site.sh" | sed "s/^[[:space:]]*local //")"
printf "%s\n" "$new_conf" > "$T/demo.test.conf"
assert_contains "模板: 使用 resolver 动态解析" "$new_conf" "resolver 127.0.0.11 valid=10s"
assert_contains "模板: upstream 变量指向 php84" "$new_conf" "set \$php_upstream php84:9000;"
assert_contains "模板: fastcgi_pass 使用变量" "$new_conf" "fastcgi_pass \$php_upstream;"
assert_contains "模板: \$uri 保持字面量" "$(grep try_files "$T/demo.test.conf")" 'try_files $uri $uri/ /index.php?$args'
assert_not_contains "模板: 无未展开的占位符" "$new_conf" '${php_key}'

SWITCHED=$(echo "$new_conf" | sed "s|set \$php_upstream [^;]*;|set \$php_upstream php81:9000;|")
assert_contains "switch: 可切换到 php81" "$SWITCHED" "set \$php_upstream php81:9000;"
assert_not_contains "switch: 无旧版本残留" "$SWITCHED" "php84"

LIST_VER=$(grep -F 'set $php_upstream' "$T/demo.test.conf" | awk '{print $3}' | cut -d: -f1)
assert_contains "list: 新模板解析出版本" "$LIST_VER" "php84"
printf 'server {\n    fastcgi_pass php81:9000;\n}\n' > "$T/legacy.conf"
LEGACY=$(grep -F 'set $php_upstream' "$T/legacy.conf" | awk '{print $3}' | cut -d: -f1 || true)
if [ -z "$LEGACY" ]; then LEGACY=$(grep fastcgi_pass "$T/legacy.conf" | awk '{print $2}' | cut -d: -f1); fi
assert_contains "list: 旧版模板回退解析" "$LEGACY" "php81"

echo "== 3. 参数校验（缺参须有友好报错而非静默退出）=="
assert_cmd_error "site add 无参数给出用法" "用法: phpbox site add" bash -c "
  set -euo pipefail; export HOME=$HOME; source '$ROOT/lib/common.sh'; source '$ROOT/lib/site.sh'; load_env; cmd_site add"
assert_cmd_error "site switch 无参数给出用法" "用法: phpbox site switch" bash -c "
  set -euo pipefail; export HOME=$HOME; source '$ROOT/lib/common.sh'; source '$ROOT/lib/site.sh'; load_env; cmd_site switch"
assert_cmd_error "site add 正常参数走到后续检查" "Nginx 未安装" bash -c "
  set -euo pipefail; export HOME=$HOME; source '$ROOT/lib/common.sh'; source '$ROOT/lib/site.sh'; load_env
  rm -f '$HOME/phpbox/compose/services/nginx-default.yml'
  cmd_site add demo.test 8.4"
assert_cmd_error "site remove 无参数给出用法" "用法: phpbox site remove" bash -c "
  set -euo pipefail; export HOME=$HOME; source '$ROOT/lib/common.sh'; source '$ROOT/lib/site.sh'; load_env; cmd_site remove"
assert_cmd_error "php install 无版本给出用法" "用法: phpbox php install" bash -c "
  set -euo pipefail; export HOME=$HOME; source '$ROOT/lib/common.sh'; source '$ROOT/lib/php.sh'; load_env; cmd_php install"

echo "== 4. 备份包含 state/，且不泄露密码 =="
MYSQL_STDOUT=$(_mysql_generate_compose 8.4 2>/dev/null)
assert_not_contains "mysql 安装过程不在终端打印密码" "$MYSQL_STDOUT" "$(grep '^MYSQL_84_ROOT_PASSWORD=' "$HOME/phpbox/.env" | cut -d= -f2)"
bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/php.sh'; source '$ROOT/lib/mysql.sh'; source '$ROOT/lib/redis.sh'; source '$ROOT/lib/nginx.sh'; source '$ROOT/lib/site.sh'; source '$ROOT/lib/backup.sh'
  require_docker() { :; }   # 桩：本套件不依赖 daemon，预检放行
  load_env; cmd_backup" >/dev/null 2>&1
BACKUP_TAR=$(ls "$HOME"/phpbox/backups/backup*.tar.gz 2>/dev/null | head -1)
if [ -n "$BACKUP_TAR" ]; then
  TARLIST=$(tar -tzf "$BACKUP_TAR")
  assert_contains "备份: 包含 .env" "$TARLIST" "phpbox/.env"
  assert_contains "备份: 包含 state/（扩展清单）" "$TARLIST" "phpbox/state/php-84-extensions.env"
  assert_contains "备份: 包含 config/" "$TARLIST" "phpbox/config/"
else
  bad "备份: 未生成备份文件"
fi

echo "== 5. restore 路径白名单拒绝越界成员 =="
python3 - "$T/evil.tar.gz" <<'PYEOF'
import tarfile, io, sys
with tarfile.open(sys.argv[1], "w:gz") as t:
    info = tarfile.TarInfo("../evil.txt")
    info.size = 5
    t.addfile(info, io.BytesIO(b"evil\n"))
PYEOF
# 走 cmd_restore 的完整校验（-y 跳过交互），必须在解包前因非法路径报错退出
RESTORE_OUT=$(bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/backup.sh'
  load_env; cmd_restore '$T/evil.tar.gz' -y" 2>&1) && RESTORE_RC=0 || RESTORE_RC=$?
assert_contains "restore: 拒绝包含 .. 的归档" "$RESTORE_OUT" "非法路径"
if [ "$RESTORE_RC" -ne 0 ]; then
  ok "restore: 非法归档已在解包前拒绝（rc=$RESTORE_RC）"
else
  bad "restore: 非法归档未被拒绝"
fi
rm -rf "$T"

echo "== 6. 输入校验 / 幂等 / env 契约 / 备份保真 =="
OUT=$(bash -c "source '$ROOT/lib/common.sh'; log 探针; success 探针" 2>/dev/null)
if [ -z "$OUT" ]; then ok "log/success 走 stderr，不污染被捕获的 stdout"; else bad "log/success 混入 stdout: $OUT"; fi
assert_cmd_error "含空格的版本号被拒" "无效版本号" bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/mysql.sh'; load_env; cmd_mysql install '8.0 x'"
if grep -aq "MYSQL_80" "$HOME/phpbox/.env" 2>/dev/null; then bad "被拒版本未在 .env 留脏键"; else ok "被拒版本未在 .env 留脏键"; fi
OUT=$(bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/mysql.sh'
  _mysql_ensure_running() { :; }   # 桩：禁止测试触碰真实 daemon（会重建生产容器）
  require_docker() { :; }; load_env; cmd_mysql install 8.0.35" 2>&1) || true
if echo "$OUT" | grep -q "无效版本号"; then bad "三段版本 8.0.35 不应被拒"; else ok "三段版本 8.0.35 放行"; fi
assert_cmd_error "mysql 7.4（不存在的版本线）被拒" "不存在" bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/mysql.sh'; load_env; cmd_mysql install 7.4"

echo "== 7. 安装失败自动回滚半安装状态 =="
# 用第 1 节未生成过的 7.4：若用 8.4 会撞上"已安装"守卫，回滚逻辑根本不会被触发
OUT=$(bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/mysql.sh'
  _mysql_ensure_running() { error '模拟启动失败'; }
  load_env; cmd_mysql install 7.4 --port 3374" 2>&1) || true
if [ -f "$HOME/phpbox/compose/services/mysql-7.4.yml" ]; then bad "失败后 yml 未回滚"; else ok "失败后 yml 已回滚"; fi
if grep -q '^MYSQL_74_PORT=' "$HOME/phpbox/.env" 2>/dev/null; then bad ".env 端口键未回滚"; else ok ".env 端口键已回滚"; fi
if grep -q '^MYSQL_74_ROOT_PASSWORD=' "$HOME/phpbox/.env" 2>/dev/null; then bad ".env 密码键未回滚"; else ok ".env 密码键已回滚"; fi
if [ -d "$HOME/phpbox/config/mysql/7.4" ]; then bad "配置目录未回滚"; else ok "配置目录已回滚"; fi
if [ -d "$HOME/mysql-custom/7.4" ]; then bad "数据目录未回滚"; else ok "数据目录已回滚"; fi

OUT=$(bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/php.sh'; load_env; cmd_php extension add 8.4 'gd;rm'" 2>&1) || true
if echo "$OUT" | grep -q "无效扩展名"; then ok "含分号扩展名被拒"; else bad "含分号扩展名未拒: $OUT"; fi

# 首装与二装分开进程：error() 会 exit，|| true 拦不住（exit 不是命令失败）
bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/mysql.sh'
  _mysql_ensure_running() { :; }   # 桩：禁止测试触碰真实 daemon
  require_docker() { :; }; load_env; cmd_mysql install 8.0" >/dev/null 2>&1 || true
OUT=$(bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/mysql.sh'
  _mysql_ensure_running() { :; }   # 桩：禁止测试触碰真实 daemon
  require_docker() { :; }; load_env; cmd_mysql install 8.0" 2>&1) || true
if echo "$OUT" | grep -q "已安装"; then ok "重复安装报已安装（幂等）"; else bad "重复安装未拦截: $OUT"; fi

printf 'EQTEST=a=b\n' >> "$HOME/phpbox/.env"
assert_contains "read_env_value 保留值中的等号（自定义密码场景）" \
  "$(bash -c "source '$ROOT/lib/common.sh'; read_env_value EQTEST" 2>/dev/null)" "a=b"

# yml 引用的每个变量：.env 文件或 load_env 导出的进程环境二者其一必须有
ENVMISS=0
for v in $(grep -hoE '\$\{[A-Z_0-9]+(:-[^}]*)?\}' "$HOME"/phpbox/compose/services/*.yml "$HOME/phpbox/compose/docker-compose.yml" | sed 's/\${//;s/}.*//' | sort -u); do
  base="${v%%:-*}"
  if ! grep -q "^$base=" "$HOME/phpbox/.env" 2>/dev/null && [ -z "${!base:-}" ]; then
    echo "  ✗ 契约缺失: $v"; ENVMISS=1
  fi
done
[ "$ENVMISS" -eq 0 ] && ok "yml↔.env 变量契约完整" || bad "yml↔.env 变量契约缺口"

# 备份→删除→恢复→内容还原
cp "$HOME/phpbox/.env" "$HOME/env.copy"
echo "fidelity-probe" > "$HOME/phpbox/state/probe.txt"
bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/php.sh'; source '$ROOT/lib/mysql.sh'; source '$ROOT/lib/redis.sh'; source '$ROOT/lib/nginx.sh'; source '$ROOT/lib/site.sh'; source '$ROOT/lib/backup.sh'
  require_docker() { :; }
  load_env; cmd_backup" >/dev/null 2>&1
rm -f "$HOME/phpbox/.env" "$HOME/phpbox/state/probe.txt"
TAR2=$(ls "$HOME"/phpbox/backups/backup*.tar.gz 2>/dev/null | sort | tail -1)
bash -c "
  set -euo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/php.sh'; source '$ROOT/lib/mysql.sh'; source '$ROOT/lib/redis.sh'; source '$ROOT/lib/nginx.sh'; source '$ROOT/lib/site.sh'; source '$ROOT/lib/backup.sh'
  require_docker() { :; }
  load_env; cmd_restore '$TAR2' -y" >/dev/null 2>&1
if diff -q "$HOME/env.copy" "$HOME/phpbox/.env" >/dev/null 2>&1; then ok "restore 后 .env 内容保真"; else bad "restore 后 .env 不一致"; fi
if [ "$(cat "$HOME/phpbox/state/probe.txt" 2>/dev/null)" = "fidelity-probe" ]; then ok "restore 后 state 文件保真"; else bad "restore 后 state 文件缺失"; fi

echo "== 8. 离线 Dockerfile：依赖层必须先于一切编译 =="
# 回归背景：离线渲染曾把 apk add --no-network 排在 pecl 循环之后，
# phpize 因找不到 autoconf 失败（Cannot find autoconf）
OFFLINE_DF=$(bash -c "
  set -uo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/build.sh'; source '$ROOT/lib/php.sh'; load_env 2>/dev/null
  _php_render_dockerfile 8.0 'bcmath,gd' 'imagick.tgz redis.tgz' 1")
DEPS_N=$(echo "$OFFLINE_DF" | grep -n "apk add --no-network /tmp/apk" | cut -d: -f1)
PECL_N=$(echo "$OFFLINE_DF" | grep -n "pecl install" | cut -d: -f1)
INST_N=$(echo "$OFFLINE_DF" | grep -n "docker-php-ext-install" | cut -d: -f1)
COPY_N=$(echo "$OFFLINE_DF" | grep -c "COPY pecl")
if [ -n "$DEPS_N" ] && [ -n "$PECL_N" ] && [ -n "$INST_N" ] && [ "$DEPS_N" -lt "$PECL_N" ] && [ "$DEPS_N" -lt "$INST_N" ]; then
  ok "离线：依赖安装层先于 pecl 与内置编译"
else
  bad "离线：依赖安装层顺序错误（deps=$DEPS_N pecl=$PECL_N inst=$INST_N）"
fi
if [ "$COPY_N" -eq 1 ]; then ok "离线：COPY pecl 恰好出现一次"; else bad "离线：COPY pecl 出现 $COPY_N 次（应为 1）"; fi
ONLINE_DF=$(bash -c "
  set -uo pipefail; export HOME=$HOME; cd '$ROOT'
  source '$ROOT/lib/common.sh'; source '$ROOT/lib/build.sh'; source '$ROOT/lib/php.sh'; load_env 2>/dev/null
  _php_render_dockerfile 8.0 'bcmath,gd' 'imagick.tgz redis.tgz' 0")
DEPS_N=$(echo "$ONLINE_DF" | grep -n 'PHPIZE_DEPS' | head -1 | cut -d: -f1)
PECL_N=$(echo "$ONLINE_DF" | grep -n "pecl install" | cut -d: -f1)
COPY_N=$(echo "$ONLINE_DF" | grep -c "COPY pecl")
if [ -n "$DEPS_N" ] && [ -n "$PECL_N" ] && [ "$DEPS_N" -lt "$PECL_N" ]; then
  ok "在线：依赖安装层先于 pecl 编译"
else
  bad "在线：依赖安装层顺序错误（deps=$DEPS_N pecl=$PECL_N）"
fi
if [ "$COPY_N" -eq 1 ]; then ok "在线：COPY pecl 恰好出现一次"; else bad "在线：COPY pecl 出现 $COPY_N 次（应为 1）"; fi

echo "== 8b. apk 下载器：源测速 + 30 秒无响应切换 =="
# 回归背景：apk 对中断的连接无读超时会永久挂死（实测 21 包后停摆），
# 且用户要求用前测速、按最快优先下载、30 秒无响应自动切换下一个源
assert_contains "apk 下载器: 用前逐源测速（索引下载计时）" "$_PHP_APK_FETCH_SCRIPT" "APKINDEX.tar.gz"
assert_contains "apk 下载器: 按测速结果排序（最快优先）" "$_PHP_APK_FETCH_SCRIPT" "sort -n"
assert_contains "apk 下载器: 索引获取 30s 超时" "$_PHP_APK_FETCH_SCRIPT" "timeout 30 apk update"
assert_contains "apk 下载器: 下载进度双指标看门狗（目录大小+网卡流量）" "$_PHP_APK_FETCH_SCRIPT" "eth0"
assert_contains "apk 下载器: 30s 无进展杀掉并切换下一个源" "$_PHP_APK_FETCH_SCRIPT" "30 秒无响应"
assert_contains "apk 下载器: 预取与基础包同步共用同一脚本" "$(declare -f _php_apk_prefetch_run) $(declare -f _php_apk_basesync_run)" "_PHP_APK_FETCH_SCRIPT"

echo "== 9. load_env 边界：末行无换行 + 引号剥离 =="
# 回归背景一：while read 对"无换行符的末行"返回非零，循环体整行跳过——末行的
# APK_MIRRORS 配置被静默丢弃，静默回退默认镜像源（用户配置形同虚设）
# 回归背景二：.env 允许带引号的值（docker env 惯例），引号必须剥离而非并入值
cp "$HOME/phpbox/.env" "$HOME/phpbox/.env.bak"
printf 'PROJECT_NAME=phpbox\nQUOTED_KEY="hello world"\nLASTKEY=last-value' > "$HOME/phpbox/.env"
bash -c "
  set -uo pipefail; export HOME=$HOME
  source '$ROOT/lib/common.sh'; load_env 2>/dev/null
  [ \"\$PROJECT_NAME\" = 'phpbox' ] || exit 10
  [ \"\$LASTKEY\" = 'last-value' ] || exit 11
  [ \"\$QUOTED_KEY\" = 'hello world' ] || exit 12
" >/dev/null 2>&1
case $? in
  0)  ok "load_env: 无换行末行被读取且引号被剥离" ;;
  10) bad "load_env: 基础键读取失败" ;;
  11) bad "load_env: 无换行末行被整行丢弃（read 返回非零跳过循环体）" ;;
  12) bad "load_env: 带引号的值未剥离引号" ;;
  *)  bad "load_env: 边界用例异常退出" ;;
esac
# 回归背景二：read_env_value 与 load_env 必须对引号、重复键（后键覆盖）语义一致
echo 'NGINX_PORT="8080"' >> "$HOME/phpbox/.env"
echo 'NGINX_PORT=9090'   >> "$HOME/phpbox/.env"
if [ "$(read_env_value "NGINX_PORT" "")" = "9090" ]; then
  ok "read_env_value: 引号剥离且重复键后键覆盖（与 load_env 一致）"
else
  bad "read_env_value: 引号/重复键语义不一致（得到 $(read_env_value "NGINX_PORT" "")）"
fi
mv "$HOME/phpbox/.env.bak" "$HOME/phpbox/.env"
load_env 2>/dev/null   # 还原夹具，避免影响 .env 保真等后续判定

# 镜像源合并语义：默认源始终在前，APK_MIRRORS 是最终兜底追加其后（不替换默认链）
MERGE=$(bash -c "
  set -uo pipefail
  source '$ROOT/lib/common.sh'
  APK_MIRRORS='https://mirrors.aliyun.com/alpine https://x.test/alpinelinux http://sunsite.icm.edu.pl/Linux/dist/alpine'
  _load_apk_mirrors; echo \"\$APK_MIRRORS\"" 2>/dev/null)
if [ "$MERGE" = "https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine https://x.test/alpinelinux/alpine http://sunsite.icm.edu.pl/Linux/dist/alpine" ]; then
  ok "镜像源: 默认源在前、配置源兜底追加、去重并补全 /alpine"
else
  bad "镜像源: 合并语义错误（得到: $MERGE）"
fi
LEGACY=$(bash -c "
  set -uo pipefail
  source '$ROOT/lib/common.sh'
  APK_MIRROR='https://legacy.test/alpine'
  _load_apk_mirrors; echo \"\$APK_MIRRORS\"" 2>/dev/null)
if [ "$LEGACY" = "https://mirrors.aliyun.com/alpine https://dl-cdn.alpinelinux.org/alpine https://legacy.test/alpine" ]; then
  ok "镜像源: 旧变量 APK_MIRROR 并入兜底段"
else
  bad "镜像源: 旧变量 APK_MIRROR 合并错误（得到: $LEGACY）"
fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
