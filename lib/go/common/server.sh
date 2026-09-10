#!/bin/bash
# shellcheck shell=bash
# Go 项目自动发现、版本/项目解析、compose 生成、Nginx 代理与清单
# （搬运自 lib/go.sh，纯迁移无逻辑改动）

# Go 项目按目录自动发现：目录名是项目名，存在 go.mod 才算 Go 项目。

_go_project_env_value() {
  local env_file=$1 wanted_key=$2 default_value=$3
  local key value found=""
  [ -f "$env_file" ] || { echo "$default_value"; return; }
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key%$'\r'}"
    [[ "$key" == "$wanted_key" ]] || continue
    found=$(_env_strip_quotes "${value%$'\r'}")
  done < "$env_file"
  echo "${found:-$default_value}"
}

_go_validate_project_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || error "无效 Go 项目名: $1"
}

# 版本归一化（AGENTS.md §2.6：只能由 Go 线公共函数实现）
_go_resolve_version() {
  local requested=$1
  requested="${requested#golang:}"
  requested="${requested%-alpine}"
  case "$requested" in
    alpine|latest)
      GO_IMAGE_TAG="alpine"
      GO_CACHE_VERSION="latest"
      ;;
    *)
      validate_version "$requested"
      GO_IMAGE_TAG="${requested}-alpine"
      GO_CACHE_VERSION="$requested"
      ;;
  esac
}

_go_resolve_project() {
  local requested=${1:-} project_path
  [ -n "$requested" ] || error "用法: phpbox go <list|run|test|shell|logs|stop|env> <项目名或路径>"
  if [[ "$requested" == /* || "$requested" == ./* || "$requested" == ../* ]]; then
    project_path=$requested
  else
    _go_validate_project_name "$requested"
    project_path="$GO_PROJECTS_ROOT/$requested"
  fi
  [ -d "$project_path" ] || error "Go 项目目录不存在: $project_path"
  [ -f "$project_path/go.mod" ] || error "不是 Go 项目（缺少 go.mod）: $project_path"
  project_path=$(cd "$project_path" && pwd)
  GO_PROJECT_PATH=$project_path
  GO_PROJECT_NAME=$(basename "$project_path")
  _go_validate_project_name "$GO_PROJECT_NAME"
  GO_PROJECT_ENV="$project_path/.env"
  GO_VERSION=$(_go_project_env_value "$GO_PROJECT_ENV" GO_VERSION "$GO_DEFAULT_VERSION")
  GO_PORT=$(_go_project_env_value "$GO_PROJECT_ENV" GO_PORT "$GO_DEFAULT_PORT")
  GO_PROJECT_CGO=$(_go_project_env_value "$GO_PROJECT_ENV" GO_CGO_ENABLED "$GO_CGO_ENABLED")
  _go_resolve_version "$GO_VERSION"
  [[ "$GO_PORT" =~ ^[1-9][0-9]{0,4}$ && "$GO_PORT" -le 65535 ]] || error "项目 ${GO_PROJECT_NAME} 的 GO_PORT 无效: $GO_PORT"
  [[ "$GO_PROJECT_CGO" == 0 || "$GO_PROJECT_CGO" == 1 ]] || error "项目 ${GO_PROJECT_NAME} 的 GO_CGO_ENABLED 无效: $GO_PROJECT_CGO"
  GO_SERVICE_NAME="${GO_SERVICE_PREFIX:-go}-${GO_PROJECT_NAME}"
  GO_SERVICE_FILE="$EXT_DIR/go-${GO_PROJECT_NAME}.yml"
  GO_CACHE_PATH="$GO_CACHE_ROOT/$GO_CACHE_VERSION"
}

_go_generate_compose() {
  local temp_file
  mkdir -p "$GO_CACHE_PATH"
  temp_file=$(mktemp "$EXT_DIR/.go-${GO_PROJECT_NAME}.XXXXXX.yml")
  log "生成 Go 项目 ${GO_PROJECT_NAME} Compose（Go ${GO_VERSION}，端口 ${GO_PORT}）..."
  cat > "$temp_file" <<YEOF
services:
  ${GO_SERVICE_NAME}:
    image: golang:${GO_IMAGE_TAG}
    container_name: ${GO_SERVICE_NAME}
    working_dir: /workspace
    command: ["sh", "-c", "while true; do sleep 3600; done"]
    volumes:
      - ${GO_PROJECT_PATH}:/workspace
      - ${GO_CACHE_PATH}:/go
    environment:
      GOPROXY: "${GO_PROXY}"
      CGO_ENABLED: "${GO_PROJECT_CGO}"
      GO_PORT: "${GO_PORT}"
    networks:
      - net
    restart: unless-stopped
    labels:
      - "${PROJECT_NAME}${LABEL_SEPARATOR}service=go"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}project=${GO_PROJECT_NAME}"
      - "${PROJECT_NAME}${LABEL_SEPARATOR}version=${GO_VERSION}"
    healthcheck:
      test: ["CMD", "go", "version"]
      interval: 10s
      timeout: 5s
      retries: 3
YEOF
  if ! docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" \
      -f "$COMPOSE_FILE" -f "$temp_file" config >/dev/null; then
    rm -f "$temp_file"
    error "Go 项目 ${GO_PROJECT_NAME} Compose 校验失败，旧配置保持不变"
  fi
  mv "$temp_file" "$GO_SERVICE_FILE"
  success "Go 项目 ${GO_PROJECT_NAME} Compose 配置就绪"
}

_go_ensure_running() {
  [ -f "$GO_SERVICE_FILE" ] || _go_generate_compose
  log "启动 Go 项目 ${GO_PROJECT_NAME} 容器（超时 ${DOCKER_TIMEOUT:-60}s）..."
  if ! timeout "${DOCKER_TIMEOUT:-60}" run_compose go "$GO_PROJECT_NAME" up -d "$GO_SERVICE_NAME"; then
    error "Go 项目 ${GO_PROJECT_NAME} 启动失败，旧服务状态未主动删除"
  fi
  success "Go 项目 ${GO_PROJECT_NAME} 容器已启动"
}

# 跨线显式动作（需求文档 §六.3 允许项）：借用 site 线的原子替换落 vhost，
# 与 _site_atomic_replace / $SITES_DIR 的耦合保持原样，加载链保证函数在场
_go_proxy_nginx() {
  [ -f "$EXT_DIR/nginx-default.yml" ] || {
    log "Nginx 未安装，跳过 ${GO_PROJECT_NAME}.test 反向代理"
    return 0
  }
  if ! docker ps --filter 'name=^/nginx$' --format '{{.Names}}' | grep -qx nginx; then
    log "Nginx 未运行，跳过 ${GO_PROJECT_NAME}.test 反向代理"
    return 0
  fi
  local domain="${GO_PROJECT_NAME}.test"
  if [ -f "$SITES_DIR/${domain}.conf" ]; then
    grep -qF "set \$go_upstream ${GO_SERVICE_NAME}:${GO_PORT};" "$SITES_DIR/${domain}.conf" || \
      error "Nginx 站点已存在，无法自动代理 Go 项目: $domain"
    return 0
  fi
  local new_conf="server {
    listen 80;
    server_name ${domain};
    location / {
        resolver 127.0.0.11 valid=10s ipv6=off;
        set \$go_upstream ${GO_SERVICE_NAME}:${GO_PORT};
        proxy_pass http://\$go_upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}"
  _site_atomic_replace "$domain" "$new_conf"
  log "请执行 'phpbox hosts add ${domain}' 添加本机域名解析"
}

_go_server() {
  echo "已发现 Go 项目:"
  local project_dir project_name status
  shopt -s nullglob
  for project_dir in "$GO_PROJECTS_ROOT"/*; do
    [ -f "$project_dir/go.mod" ] || continue
    project_name=$(basename "$project_dir")
    status="未启动"
    if docker ps --filter "name=^/${GO_SERVICE_PREFIX:-go}-${project_name}$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
      status="运行中"
    fi
    printf "  %-24s %s\n" "$project_name" "$status"
  done
  shopt -u nullglob
}

_go_list() {
  local label_prefix="${PROJECT_NAME}${LABEL_SEPARATOR}"
  local container_format="table {{.Names}}\tgo\t{{.Label \"${label_prefix}version\"}}\t{{.Ports}}\t{{.Status}}"

  echo "Go 容器:"
  docker ps -a --filter "label=${label_prefix}service=go" --format "$container_format"

  echo
  echo "Go 镜像:"
  docker image ls golang --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'
}
