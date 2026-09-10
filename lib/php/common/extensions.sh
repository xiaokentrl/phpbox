#!/bin/bash
# shellcheck shell=bash
# PHP 扩展状态读写、校验与 add/remove 操作（搬运自 lib/php.sh，纯迁移无逻辑改动）

_php_get_extensions_file() {
  local ver=$1
  echo "$PHP_CONFIG_DIR/$ver/extensions.env"
}

_php_read_extensions() {
  local ver=$1
  local f="$(_php_get_extensions_file "$ver")"
  if [ -f "$f" ]; then
    # 清洗流水线：去注释行 → 去空行 → 去掉 "KEY=" 前缀 → 再去空行 →
    # 按逗号拆行排序去重 → 重新拼回逗号串（最终输出形如 gd,redis）
    grep -v '^#' "$f" | grep -v '^$' | sed 's/^[A-Za-z_][A-Za-z0-9_]*=//' | grep -v '^$' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
  else
    echo ""
  fi
}

_php_write_extensions() {
  local ver=$1 exts=$2
  local f="$(_php_get_extensions_file "$ver")"
  echo "# PHP ${ver} 扩展列表（逗号分隔）" > "$f"
  echo "PHP_EXTENSIONS=${exts}" >> "$f"
}

_php_validate_extensions() {
  local exts="$1"
  local IFS=,   # 把分词符设为逗号：下面的 for 直接按逗号逐项遍历 $exts
  for ext in $exts; do
    # 白名单字符集：扩展名会被拼进 Dockerfile，禁止空格/分号等注入字符。
    # 允许点号：install-php-extensions 的版本钉住语法（如 apcu-5.1.27）需要
    if ! [[ "$ext" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      error "无效扩展名: $ext"
    fi
  done
}

# 只安装了一个 PHP 版本时返回其版本号（stdout）；零个或多个时给出明确指引并失败。
# 供 extension add/remove 省略版本参数时推断使用
_php_infer_installed_version() {
  local versions=() f
  for f in "$EXT_DIR"/php-*.yml; do
    [ -f "$f" ] || continue
    versions+=("$(basename "$f" .yml | sed 's/php-//')")
  done
  case ${#versions[@]} in
    0) error "尚未安装任何 PHP 版本，请先 phpbox php install <版本>" ;;
    1) echo "${versions[0]}" ;;
    *) error "存在多个 PHP 版本（${versions[*]}），请显式指定: phpbox php extension <add|remove> <版本> <扩展名>" ;;
  esac
}

_php_extension_op() {
  local sub="${1:-}"
  local ver="${2:-}"
  local ext="${3:-}"
  [ -z "$sub" ] && error "用法: phpbox php extension {add|remove} <版本> <扩展名>"
  # 版本推断：只装了一个 PHP 版本时允许省略版本参数（ver 缺省才推断，显式给了就尊重）
  if [ -z "$ver" ]; then
    ver=$(_php_infer_installed_version)
    log "已推断 PHP 版本: $ver"
  fi
  [ -z "$ext" ] && error "用法: phpbox php extension $sub <版本> <扩展名>（例: phpbox php extension add 8.0 xdebug）"
  validate_version "$ver"
  [[ "$ver" == 5.* || "$ver" == 7.* || "$ver" == 8.* ]] || error "PHP 不存在 ${ver%%.*}.x 版本，可用版本线: 5.6 / 7.x / 8.x"
  _php_validate_extensions "$ext"

  # 幂等短路在前：已存在/不存在的扩展直接返回，不需要 daemon
  local current="$(_php_read_extensions "$ver")"
  local new_exts=""
  if [ "$sub" = "add" ]; then
    # 两端补逗号做整项匹配：查 "gd" 才不会误命中 "xgdx"
    if [[ ",$current," == *",$ext,"* ]]; then
      log "扩展 $ext 已存在"
      return
    fi
    new_exts="${current:+$current,}$ext"   # ${var:+x}：current 非空时展开为 "current内容,"，空则不加逗号
  elif [ "$sub" = "remove" ]; then
    # 同上整项匹配，此处 != 表示"列表里不存在该项"
    if [[ ",$current," != *",$ext,"* ]]; then
      log "扩展 $ext 不存在"
      return
    fi
    new_exts=$(echo "$current" | tr ',' '\n' | grep -v "^$ext$" | tr '\n' ',' | sed 's/,$//')
  else
    error "未知扩展操作: $sub (支持 add/remove)"
  fi

  require_docker

  _php_cleanup_images "$ver"
  rm -f "$EXT_DIR/php-${ver}.yml"
  _php_write_extensions "$ver" "$new_exts"
  _php_generate_compose "$ver"
  _php_ensure_running "$ver"
  success "PHP ${ver} 扩展已更新（${sub}: $ext）"
}
