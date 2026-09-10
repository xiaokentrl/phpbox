#!/bin/bash
# shellcheck shell=bash
# Go 项目容器动作：run/test/shell/logs/stop/env 经 _go_exec 分发
# （搬运自 lib/go.sh，纯迁移无逻辑改动）

_go_prepare() {
  _go_resolve_project "$1"
  _go_generate_compose
  _go_ensure_running
  _go_proxy_nginx
}

_go_resolve_existing() {
  _go_resolve_project "$1"
  [ -f "$GO_SERVICE_FILE" ] || error "Go 项目 ${GO_PROJECT_NAME} 尚未启动"
}

_go_exec() {
  local action=$1 project=$2
  case "$action" in
    run|test|shell) _go_prepare "$project" ;;
    logs|stop|env)  _go_resolve_existing "$project" ;;
  esac
  shift 2
  case "$action" in
    run)   log "执行 Go 项目 ${GO_PROJECT_NAME}: go run ."; docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$GO_SERVICE_FILE" exec -T "$GO_SERVICE_NAME" go run . "$@" ;;
    test)  log "执行 Go 项目 ${GO_PROJECT_NAME}: go test ./..."; docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$GO_SERVICE_FILE" exec -T "$GO_SERVICE_NAME" go test ./... "$@" ;;
    shell) docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$GO_SERVICE_FILE" exec "$GO_SERVICE_NAME" sh ;;
    logs)  docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$GO_SERVICE_FILE" logs -f "$GO_SERVICE_NAME" ;;
    stop)  run_compose go "$GO_PROJECT_NAME" stop "$GO_SERVICE_NAME" ;;
    env)   docker compose -p "$PROJECT_NAME" --project-directory "$BASE_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$GO_SERVICE_FILE" exec -T "$GO_SERVICE_NAME" sh -c 'printf "Go version: "; go version; go env GOROOT GOPATH GOMODCACHE GOCACHE' ;;
    *) error "未知 go 操作: $action" ;;
  esac
}
