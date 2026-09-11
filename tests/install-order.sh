#!/bin/bash
# install 顺序回归门禁：php install 的"先建目录、后写扩展状态"约束
# 背景（2026-09-12 真实故障）：_php_write_extensions 在 init_config_files 之前执行，
#   全新安装（config/php/<版本>/ 不存在）时写 extensions.env 重定向 ENOENT 直接崩，
#   回滚框架只能清半安装状态；且不能反向在写入函数里补 mkdir——init_config_files
#   对"非空但缺 php.ini"的目录会 rm -rf 重建，把刚写的扩展状态静默抹掉。
# 断言 1（静态）：_php_install 函数体内 init_config_files 出现于 _php_write_extensions 之前
# 断言 2（动态）：沙箱目录序列注入，_php_write_extensions 必须成功创建文件（目录已由前置步骤建好）
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

# ---- 断言 1：静态顺序检查 ----
src="lib/php/common/install.sh"
init_line=$(grep -n 'init_config_files "php"' "$src" | head -1 | cut -d: -f1)
write_line=$(grep -n '_php_write_extensions "\$ver" "\$exts"' "$src" | head -1 | cut -d: -f1)
if [ -n "$init_line" ] && [ -n "$write_line" ] && [ "$init_line" -lt "$write_line" ]; then
  ok "顺序约束: init_config_files($init_line 行) 先于 _php_write_extensions($write_line 行)"
else
  bad "顺序约束被破坏: init=$init_line write=$write_line（$src）——全新安装会 ENOENT 崩溃"
fi

# 同一陷阱的其他服务线排查：任何"写文件进 $CONFIG_DIR/<svc>/<ver>/ 但先于 init_config_files"的调用
while IFS=: read -r fnum rest; do
  file=$(echo "$rest" | cut -d: -f1)
  bad "发现未初始化先写配置的调用: $file:$fnum: $rest"
done < <(grep -rn 'echo .* > "\$.*CONFIG_DIR' lib/*/common/*.sh 2>/dev/null | grep -v 'tests/' | grep -viE 'init_config|mkdir' || true)

# ---- 断言 2：动态沙箱验证（不碰 Docker）----
# 加载被测函数的最小依赖集，用替身目录复现"config/php/7.4 不存在"的全新安装场景。
# 顺序关键：先加载默认环境、再覆盖 PHP_CONFIG_DIR 指向沙箱——反过来会被 env.sh 的
# 默认定义盖回真实目录，污染工作区（测试第一版就犯了这个错）
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

source lib/common/log.sh
source lib/common/env.sh
source lib/php/common/extensions.sh
export PHP_CONFIG_DIR="$sandbox/php"

# 复现修复后的序列：init（建目录+php.ini）→ write（写 extensions.env）
mkdir -p "$PHP_CONFIG_DIR/7.4"
echo "; php.ini placeholder" > "$PHP_CONFIG_DIR/7.4/php.ini"

_php_write_extensions "7.4" "gd,redis" 2>/dev/null
envf="$PHP_CONFIG_DIR/7.4/extensions.env"
if [ -f "$envf" ] && grep -q '^PHP_EXTENSIONS=gd,redis$' "$envf"; then
  ok "动态验证: 目录就位后 _php_write_extensions 成功落盘（$envf）"
else
  bad "动态验证: 写扩展状态失败（期望 $envf 含 PHP_EXTENSIONS=gd,redis）"
fi

# 反向钳制：_php_write_extensions 自身不允许靠 mkdir 补目录（防未来有人"顺手修"引入
# init_config_files rm -rf 静默抹状态的新陷阱）——在无目录场景调用必须失败
rm -rf "$sandbox/php/8.0"
_php_write_extensions "8.0" "gd" >/dev/null 2>&1
if [ ! -e "$PHP_CONFIG_DIR/8.0/extensions.env" ]; then
  ok "反向钳制: _php_write_extensions 不自行建目录（无目录时未落盘，保持调用方建目录的职责边界）"
else
  bad "反向钳制: _php_write_extensions 自行了 mkdir，破坏与 init_config_files 的职责边界"
fi

echo "----------------------------------------"
echo "install-order: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ] || exit 1
