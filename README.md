# phpbox

**中文** | [English](#english)

多版本 Docker 开发环境管理器（LNMP + Go）。纯 Bash 实现，一条命令装好 PHP / MySQL / Redis / Nginx：多版本共存、随时切换、互不干扰；构建支持离线缓存，断网也能重装；每个长操作都有阶段日志、超时边界和失败回滚。

- 多版本 PHP（5.6/7.x/8.x）、MySQL、Redis、Go 共存，随装随用
- 站点一键绑定域名 + PHP 版本，`site switch` 秒切版本
- Go 项目按 `go.mod` 自动发现，无需通过 phpbox 创建
- APK/PECL 构建依赖离线缓存（`offline/`），命中即零网络构建
- 失败不破坏旧状态：配置生成原子替换、安装事务自动回滚、备份前暂停服务

## 前置条件

- Docker 与 Docker Compose 插件
- bash ≥ 4.4（macOS 自带 3.2，请先 `brew install bash`）

## 安装

```bash
git clone <仓库地址> phpbox
cd phpbox
bash install.sh
```

`install.sh` 创建 `~/phpbox` 目录结构、复制源码、生成主 compose 与默认 `.env`，并把 `phpbox` 软链到 `/usr/local/bin`（需 sudo；失败时给出手动命令）。

## 快速开始

```bash
phpbox php install 8.4                  # 装 PHP 8.4（默认扩展集见 .env）
phpbox nginx install                    # 装 Nginx（默认 80 端口）
phpbox mysql install 8.4                # 装 MySQL（完成后显示 root 密码）
phpbox redis install                    # 装 Redis 8（默认端口 6379）
phpbox site add demo.test --php 8.4     # 创建站点
phpbox hosts add demo.test              # 域名解析（需 sudo）
phpbox list                             # 查看所有服务
```

浏览器访问 `http://demo.test` 即可（Nginx 端口非 80 时带端口访问，命令完成时会提示实际地址）。

## 用户场景

### 场景 1：老项目要 PHP 7.4，新项目要 8.4

```bash
phpbox php install 7.4
phpbox php install 8.4
phpbox site add legacy.test --php 7.4
phpbox site add shiny.test --php 8.4
```

两套 PHP 容器同时运行，站点各自连各自的 PHP-FPM。要给老项目升级试水：`phpbox site switch legacy.test --php 8.0`，切回同样一条命令。

### 场景 2：按需增减扩展

```bash
phpbox php extension add 8.4 yaf       # 加扩展（自动重建镜像并重载 Nginx）
phpbox php extension remove 8.4 xdebug # 减扩展
phpbox php install 8.4 --ext gd,redis  # 全新安装时直接指定扩展集
```

扩展状态存在 `config/php/8.4/extensions.env`，每个版本独立维护。

### 场景 3：断网重装 / 换机迁移

只要 `offline/` 里有已验证的资产（PHP：`php/<版本>/` 的 APK 闭包 + PECL 包；MySQL/Redis：`mysql/<版本>/`、`redis/<版本>/` 镜像 tar——首次安装自动回写），断网也能完整重装：

```bash
phpbox php uninstall 8.4
phpbox php install 8.4        # 备份命中，全程零网络
```

换机用备份迁移：`phpbox backup` 打包 `.env`、`config/`、`offline/` 离线库、站点源码（`WWW_ROOT`）、MySQL 数据与全部数据卷；新机器 `phpbox restore backups/backup-<时间戳>.tar.gz`。

### 场景 4：多 MySQL 并行调试

```bash
phpbox mysql install 5.7 --port 3357
phpbox mysql install 8.4 --port 3384
```

各版本独立端口、独立数据目录（`~/mysql-data/<版本>/`）。端口冲突自动顺延或 `mysql port set` 修改。

### 场景 5：Go 开发

```bash
phpbox go install 1.24       # 拉取 golang:1.24-alpine 镜像
phpbox go run my-go-app      # ~/www/my-go-app（含 go.mod 即自动发现）
phpbox hosts add my-go-app.test
```

Go 容器源码挂 `/workspace`、按版本持久化 GOPATH 缓存，不发布宿主机端口——统一走 Nginx `<项目名>.test` 域名访问。

## 命令参考

### PHP

| 命令 | 说明 |
| --- | --- |
| `phpbox php install <版本> [--ext 扩展列表]` | 安装 PHP；不带 `--ext` 用 `PHP_DEFAULT_EXTENSIONS`（`--extensions` 为兼容别名） |
| `phpbox php extension add <版本> <扩展>` | 添加扩展（自动重建镜像并重载） |
| `phpbox php extension remove <版本> <扩展>` | 移除扩展 |
| `phpbox php list` | 列出所有 PHP 实例 |
| `phpbox php uninstall <版本> [--purge]` | 卸载（`--purge` 连同镜像与配置目录清除） |

### MySQL

| 命令 | 说明 |
| --- | --- |
| `phpbox mysql install <版本> [--port 端口]` | 安装 MySQL（镜像优先走 `offline/mysql/<版本>/` 离线命中，未命中在线拉取后自动回写离线库），完成后显示 root 密码（存入 `.env`） |
| `phpbox mysql port set <版本> <新端口>` | 修改端口（失败自动回滚） |
| `phpbox mysql list` | 列出所有 MySQL 实例 |
| `phpbox mysql uninstall <版本> [--purge]` | 卸载（`--purge` 连同数据目录清除） |

### Redis

| 命令 | 说明 |
| --- | --- |
| `phpbox redis install [<版本>] [--port 端口]` | 安装 Redis（镜像优先走 `offline/redis/<版本>/` 离线命中）；省略版本用最新稳定主版本 Redis 8，省略端口用 6379；密码存 `.env` 的 `REDIS_<去点版本>_ROOT_PASSWORD` |
| `phpbox redis port set <版本> <新端口>` | 修改端口 |
| `phpbox redis list` | 列出所有 Redis 实例 |
| `phpbox redis uninstall <版本> [--purge]` | 卸载 |

### Nginx / 站点 / hosts

| 命令 | 说明 |
| --- | --- |
| `phpbox nginx install [--port 端口]` | 安装 Nginx（镜像 tag 由 `NGINX_VERSION` 决定，默认 `alpine`） |
| `phpbox nginx port set <新端口>` | 修改端口 |
| `phpbox nginx reload` | 校验配置并重载 |
| `phpbox nginx uninstall` | 卸载（保留配置与站点） |
| `phpbox site add <域名> --php <版本>` | 创建站点（生成 vhost 并校验重载，失败回滚） |
| `phpbox site switch <域名> --php <版本>` | 切换站点的 PHP 版本 |
| `phpbox site list` | 列出站点及其 PHP |
| `phpbox site remove <域名>` | 删除站点（校验失败自动恢复；可选删站点目录） |
| `phpbox hosts add <域名>` | 添加 hosts 解析（需 sudo） |
| `phpbox hosts remove <域名>` | 移除 hosts 解析 |
| `phpbox hosts list` | 查看域名解析状态 |

### Go

Go 项目不需要通过 phpbox 创建：`GO_PROJECTS_ROOT`（默认 `~/www`）下的直接子目录只要包含 `go.mod` 即自动发现，目录名就是项目名。

```text
~/www/my-go-app/
├── .env          # 可选，仅覆盖 Go 容器配置
├── go.mod
└── main.go
```

项目 `.env` 可设置（只覆盖 Go 容器配置）：

```dotenv
GO_VERSION=1.24
GO_PORT=8080
GO_CGO_ENABLED=0
```

`GO_VERSION` 选镜像，`GO_PORT` 是应用容器内监听端口。不需要配置 `GOROOT`/`GOPATH`（容器内固定 `/usr/local/go` 与 `/go`）。

```bash
phpbox go install [版本]        # 默认 alpine=最新稳定版；1.24 → golang:1.24-alpine
phpbox go uninstall <版本> [--purge]   # latest=最新稳定版；--purge 连缓存删除
phpbox go list                  # 已下载镜像与容器
phpbox go server                # 自动发现的项目及运行状态
phpbox go run <项目>            # go run .
phpbox go test <项目>           # go test ./...
phpbox go shell <项目>          # 进入容器 /workspace
phpbox go logs / stop / env <项目>
```

镜像仍被项目容器使用时拒绝卸载，先 `phpbox go stop <项目>`。

### 全局

| 命令 | 说明 |
| --- | --- |
| `phpbox list` | 列出所有已安装服务 |
| `phpbox backup` | 备份（暂停 MySQL/Redis 后打包 `.env`、`config/`、`offline/`、站点源码、MySQL 数据目录与数据卷） |
| `phpbox restore <备份文件> [-y]` | 恢复（拒绝含 `..` 的危险归档路径；`-y` 非交互） |
| `phpbox help` | 全部命令 |

## 环境变量（`.env`）

首次安装生成默认 `.env`，可按需调整；完整键名与注释见 `.env.example`。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WWW_ROOT` | `~/www` | 网站根目录（挂到容器 `/var/www`），Go 项目扫描根 |
| `MYSQL_DATA_ROOT` | `~/mysql-data` | MySQL 数据主目录（每版本一个子目录） |
| `CURRENT_UID` / `CURRENT_GID` | 当前用户 | 容器内 `www-data` 对齐宿主属主，避免权限问题 |
| `NGINX_PORT` / `NGINX_VERSION` | `80` / `alpine` | Nginx 宿主端口 / 镜像 tag |
| `PHP_DEFAULT_EXTENSIONS` | 见 `.env.example` | `php install` 不带 `--ext` 时的默认扩展集 |
| `MYSQL_<去点版本>_PORT` / `MYSQL_<去点版本>_ROOT_PASSWORD` | 自动分配 / 自动生成 | 如 `MYSQL_84_PORT`、`MYSQL_84_ROOT_PASSWORD`；安装前预置即生效 |
| `REDIS_<去点版本>_PORT` / `REDIS_<去点版本>_ROOT_PASSWORD` | `6379` / 自动生成 | 如 `REDIS_8_PORT`；redis 安装完成后自动写入 |
| `APK_MIRRORS` | 阿里云 + 官方源 | Alpine 镜像源列表（空格分隔，测速排序，超时切换） |
| `APK_TIMEOUT` | `30` | 镜像源网络超时秒数（测速/索引/无响应判定共用） |
| `BUILD_PROXY` | `auto` | 构建代理：`auto`=探测本地代理端口；`none`=禁用；或 `host:port` |
| `OFFLINE_DIR` | `./offline` | APK/PECL 离线库位置（支持 `~/` 与绝对路径） |
| `GO_PROJECTS_ROOT` | `~/www` | Go 项目扫描根目录 |
| `GO_DEFAULT_VERSION` | `alpine` | Go 默认镜像版本 |
| `GO_DEFAULT_PORT` | `8080` | 项目未设 `GO_PORT` 时的容器内端口 |
| `GO_PROXY` | `https://goproxy.cn,direct` | Go 模块下载代理 |
| `GO_CACHE_ROOT` | `~/phpbox/cache/go` | GOPATH 缓存根目录，按版本分目录 |
| `GO_CGO_ENABLED` | `0` | Go 默认 `CGO_ENABLED`，项目 `.env` 可覆盖 |
| `PROJECT_NAME` / `NETWORK_NAME` 等 | 见 `.env.example` | compose 项目名 / 共享网络 / 容器与镜像命名规则 |

## 目录结构与生成物

```
$HOME/phpbox/
├── bin/phpbox                    # 薄入口：加载 lib/ 固定加载链后转调 lib/cli.sh
├── lib/                          # 四层分层结构（详见 AGENTS.md §3）
│   ├── common/                   # 全局公共层：env/log/paths/ports/docker/config 六件套 + install 事务框架
│   ├── cli.sh                    # 命令路由实现与全局命令（help/list）
│   ├── php/                       # PHP 线：common/{install,extensions,apk-fetch,offline,build,config} + versions/ + cli.sh
│   ├── mysql/                     # MySQL 线：common/{install,offline,port,config} + versions/ + cli.sh
│   ├── redis/                     # Redis 线：common/{install,port,config} + versions/ + cli.sh
│   ├── nginx/                     # Nginx 线：common/{install,reload,config} + versions/ + cli.sh
│   ├── site/                      # 站点与 hosts：common/{add,switch,list,hosts} + cli.sh
│   ├── go/                        # Go 线：common/{install,run,shell,server} + versions/ + cli.sh
│   └── backup/                    # 备份与恢复：common/{backup,restore} + cli.sh
├── compose/
│   ├── docker-compose.yml        # 主 compose（仅定义共享网络）
│   └── services/                 # 每个服务版本一个 yml 分片（如 php-8.4.yml）
├── config/                       # 各服务版本配置与 PHP 扩展清单
├── offline/                      # 离线缓存（php/<版本>/apk+pecl/；mysql、redis/<版本>/ 镜像 tar）
├── cache/go/<版本>/               # Go GOPATH 模块和工具缓存
├── backups/                      # 备份归档
├── logs/                         # Nginx 与 PHP 日志
└── .env                          # 环境变量（用户可修改）
```

仓库**只跟踪源码与模板**：`bin/phpbox`、`lib/`、`install.sh`、`tests/`、`.env.example`、文档与 `.gitkeep` 占位。其余全是运行期生成物，已列入 `.gitignore`，干净 clone 后执行 `install.sh` 即自动重建——直接改生成物不会持久生效，要改的是生成逻辑或 `.env`。

| 生成物 | 由谁生成 |
| --- | --- |
| `.env` | `install.sh`（含明文密码，绝不入仓） |
| `compose/` 的 yml | `install.sh` / 各服务安装命令 |
| `config/php/*/Dockerfile`、`php.ini` | `php install`、`php extension add/remove` |
| `config/mysql/*/my.cnf`、`config/nginx/*/{nginx.conf,conf.d/}`、`config/redis/*/redis.conf` | 首次安装时从镜像提取或生成，用户可直接修改 |
| `config/nginx/sites/*.conf` | `site add` |
| `config/php/*/extensions.env`、`logs/*.log`、`backups/*.tar.gz` | 安装过程与运行期 |
| `offline/`（php 构建闭包 + mysql/redis 镜像 tar）、`cache/go/` | 构建验证成功后自动晋升 / 镜像拉取后回写 / Go 命令 |

## 测试与验收

```bash
bash tests/lint.sh    # 全量 bash -n 语法门禁（含容器内脚本）
bash tests/run.sh    # 五闸门：lint → 函数清单 → 冒烟 → offline-first 行为 → install 顺序回归
```

冒烟与行为测试优先用可控替身（假 curl / 沙箱目录），不依赖真实网络；涉及真实 Docker 的项目显式标注。

## 常见问题

- **bash 版本过低**：macOS 先 `brew install bash`，再用新版运行。
- **端口被占用**：不指定端口时自动挑空闲端口；`--port` 显式指定被占用会提示占用者。
- **忘了数据库密码**：MySQL/Redis 密码都在 `.env`（`MYSQL_<版本>_ROOT_PASSWORD` / `REDIS_<版本>_ROOT_PASSWORD`），该文件不入仓。
- **站点打不开**：`site list` 确认站点、`hosts list` 确认解析，Nginx 非 80 端口要带端口访问。
- **PHP 构建卡在下载**：确认 `APK_MIRRORS` 可达；网络受限配 `BUILD_PROXY` 指向本地代理。
- **删掉配置想重来**：删对应 `config/<服务>/<版本>/` 目录，下次安装自动重新生成。
- **Go 项目未被发现**：确认是 `GO_PROJECTS_ROOT` 直接子目录且含 `go.mod`，用 `go server` 查看发现结果。
- **Go 镜像无法卸载**：先 `go stop` 使用它的项目容器。

---

# English

**[中文](#phpbox)** | English

A multi-version Docker dev-environment manager (LNMP + Go), implemented in pure Bash: install PHP / MySQL / Redis / Nginx with a single command — multiple versions coexist, switch anytime without interference. Builds are backed by an offline cache (reinstall without network), and every long operation ships with staged logs, timeouts, and rollback on failure.

- Multi-version PHP (5.6/7.x/8.x), MySQL, Redis, and Go, side by side
- One-command site scaffolding with domain + PHP version binding; `site switch` flips versions instantly
- Go projects auto-discovered by `go.mod` — no scaffolding through phpbox
- APK/PECL build deps cached in `offline/` — offline rebuilds with zero network
- Failures never destroy prior state: atomic config replacement, transactional installs with auto-rollback, services paused before backup

## Prerequisites

- Docker with the Docker Compose plugin
- bash ≥ 4.4 (macOS ships 3.2 — `brew install bash` first)

## Installation

```bash
git clone <repo-url> phpbox
cd phpbox
bash install.sh
```

`install.sh` creates the `~/phpbox` layout, copies sources, generates the main compose file and default `.env`, and symlinks `phpbox` into `/usr/local/bin` (sudo required; a manual command is printed if it fails).

## Quick Start

```bash
phpbox php install 8.4                  # PHP 8.4 (default extension set from .env)
phpbox nginx install                    # Nginx (port 80 by default)
phpbox mysql install 8.4                # MySQL (root password shown when done)
phpbox redis install                    # Redis 8 (port 6379 by default)
phpbox site add demo.test --php 8.4     # create a site
phpbox hosts add demo.test              # domain resolution (sudo)
phpbox list                             # overview of installed services
```

Open `http://demo.test` in a browser (include the port if Nginx isn't on 80 — the actual URL is printed on completion).

## User Scenarios

### Scenario 1: legacy app needs PHP 7.4, new app needs 8.4

```bash
phpbox php install 7.4
phpbox php install 8.4
phpbox site add legacy.test --php 7.4
phpbox site add shiny.test --php 8.4
```

Both PHP containers run concurrently; each site talks to its own PHP-FPM. Piloting an upgrade for the legacy app is one command — `phpbox site switch legacy.test --php 8.0` — and one more to switch back.

### Scenario 2: add or remove extensions on demand

```bash
phpbox php extension add 8.4 yaf       # add (rebuilds image, reloads Nginx)
phpbox php extension remove 8.4 xdebug # remove
phpbox php install 8.4 --ext gd,redis  # specify the set on a fresh install
```

Extension state lives in `config/php/8.4/extensions.env`, maintained per version.

### Scenario 3: reinstall offline / migrate machines

As long as `offline/` holds verified assets (PHP: APK closures + PECL tarballs under `php/<version>/`; MySQL & Redis: image tars under `mysql/<version>/` and `redis/<version>/`, auto-saved on first install), a full reinstall works with no network:

```bash
phpbox php uninstall 8.4
phpbox php install 8.4        # cache hits all the way — zero network
```

To move machines, `phpbox backup` archives `.env`, `config/`, the `offline/` library, site sources (`WWW_ROOT`), MySQL data, and all volumes; restore on the new host with `phpbox restore backups/backup-<timestamp>.tar.gz`.

### Scenario 4: parallel MySQL versions for debugging

```bash
phpbox mysql install 5.7 --port 3357
phpbox mysql install 8.4 --port 3384
```

Each version gets its own port and data directory (`~/mysql-data/<version>/`). Port conflicts auto-bump, or change later with `mysql port set`.

### Scenario 5: Go development

```bash
phpbox go install 1.24       # pulls golang:1.24-alpine
phpbox go run my-go-app      # ~/www/my-go-app (auto-discovered via go.mod)
phpbox hosts add my-go-app.test
```

Go containers mount sources at `/workspace`, persist GOPATH caches per version, and publish no host ports — access goes through the Nginx domain `<project>.test`.

## Command Reference

### PHP

| Command | Description |
| --- | --- |
| `phpbox php install <version> [--ext list]` | Install PHP; without `--ext` uses `PHP_DEFAULT_EXTENSIONS` (`--extensions` is a compat alias) |
| `phpbox php extension add <version> <ext>` | Add extension (rebuilds image, reloads) |
| `phpbox php extension remove <version> <ext>` | Remove extension |
| `phpbox php list` | List PHP instances |
| `phpbox php uninstall <version> [--purge]` | Uninstall (`--purge` also removes image and config dir) |

### MySQL

| Command | Description |
| --- | --- |
| `phpbox mysql install <version> [--port N]` | Install MySQL (image prefers the `offline/mysql/<version>/` cache, online pull auto-saved back); root password shown and saved to `.env` |
| `phpbox mysql port set <version> <new>` | Change port (auto-rollback on failure) |
| `phpbox mysql list` | List MySQL instances |
| `phpbox mysql uninstall <version> [--purge]` | Uninstall (`--purge` also removes the data directory) |

### Redis

| Command | Description |
| --- | --- |
| `phpbox redis install [<version>] [--port N]` | Install Redis (image prefers the `offline/redis/<version>/` cache); defaults to latest stable major Redis 8 and port 6379; password stored in `REDIS_<dotless>_ROOT_PASSWORD` |
| `phpbox redis port set <version> <new>` | Change port |
| `phpbox redis list` | List Redis instances |
| `phpbox redis uninstall <version> [--purge]` | Uninstall |

### Nginx / Sites / Hosts

| Command | Description |
| --- | --- |
| `phpbox nginx install [--port N]` | Install Nginx (image tag from `NGINX_VERSION`, default `alpine`) |
| `phpbox nginx port set <new>` | Change port |
| `phpbox nginx reload` | Validate config and reload |
| `phpbox nginx uninstall` | Uninstall (config and sites kept) |
| `phpbox site add <domain> --php <ver>` | Create a site (vhost generated, validated, reloaded; rolled back on failure) |
| `phpbox site switch <domain> --php <ver>` | Switch the site's PHP version |
| `phpbox site list` | List sites and their PHP |
| `phpbox site remove <domain>` | Remove a site (auto-restores on failed validation; site dir deletion optional) |
| `phpbox hosts add <domain>` | Add hosts entry (sudo) |
| `phpbox hosts remove <domain>` | Remove hosts entry |
| `phpbox hosts list` | Show hosts status |

### Go

Go projects are never scaffolded by phpbox: any direct subdirectory of `GO_PROJECTS_ROOT` (default `~/www`) containing `go.mod` is auto-discovered; the directory name is the project name.

```text
~/www/my-go-app/
├── .env          # optional, overrides Go container config only
├── go.mod
└── main.go
```

Project `.env` keys (Go container config only):

```dotenv
GO_VERSION=1.24
GO_PORT=8080
GO_CGO_ENABLED=0
```

`GO_VERSION` selects the image; `GO_PORT` is the port your app listens on inside the container. No `GOROOT`/`GOPATH` needed (fixed at `/usr/local/go` and `/go`).

```bash
phpbox go install [version]           # default alpine = latest stable; 1.24 → golang:1.24-alpine
phpbox go uninstall <version> [--purge]  # latest = latest stable; --purge also removes caches
phpbox go list                        # downloaded images and containers
phpbox go server                      # auto-discovered projects and status
phpbox go run <project>               # go run .
phpbox go test <project>              # go test ./...
phpbox go shell <project>             # shell into /workspace
phpbox go logs / stop / env <project>
```

Uninstalling an image still used by a project container is refused — `phpbox go stop <project>` first.

### Global

| Command | Description |
| --- | --- |
| `phpbox list` | List all installed services |
| `phpbox backup` | Backup (pauses MySQL/Redis, then archives `.env`, `config/`, `offline/`, site sources, MySQL data, and volumes) |
| `phpbox restore <file> [-y]` | Restore (archives containing `..` paths are rejected; `-y` = non-interactive) |
| `phpbox help` | Full command list |

## Environment Variables (`.env`)

A default `.env` is generated on first install; see `.env.example` for the full key list with comments.

| Variable | Default | Description |
| --- | --- | --- |
| `WWW_ROOT` | `~/www` | Web root (mounted at `/var/www`); also the Go project scan root |
| `MYSQL_DATA_ROOT` | `~/mysql-data` | MySQL data root (one subdirectory per version) |
| `CURRENT_UID` / `CURRENT_GID` | current user | Aligns container `www-data` with the host owner to avoid permission issues |
| `NGINX_PORT` / `NGINX_VERSION` | `80` / `alpine` | Nginx host port / image tag |
| `PHP_DEFAULT_EXTENSIONS` | see `.env.example` | Default extension set when `php install` omits `--ext` |
| `MYSQL_<dotless>_PORT` / `MYSQL_<dotless>_ROOT_PASSWORD` | auto-assigned / generated | e.g. `MYSQL_84_PORT`, `MYSQL_84_ROOT_PASSWORD`; preset before install to take effect |
| `REDIS_<dotless>_PORT` / `REDIS_<dotless>_ROOT_PASSWORD` | `6379` / generated | e.g. `REDIS_8_PORT`; written automatically after redis install |
| `APK_MIRRORS` | Aliyun + official | Alpine mirror list (space-separated; speed-ranked, failover on timeout) |
| `APK_TIMEOUT` | `30` | Network timeout in seconds for mirrors (speed test / index / stall detection) |
| `BUILD_PROXY` | `auto` | Build proxy: `auto` = probe local proxy ports; `none` = disabled; or `host:port` |
| `OFFLINE_DIR` | `./offline` | Location of the APK/PECL offline library (`~/` and absolute paths supported) |
| `GO_PROJECTS_ROOT` | `~/www` | Go project scan root |
| `GO_DEFAULT_VERSION` | `alpine` | Default Go image version |
| `GO_DEFAULT_PORT` | `8080` | In-container port when the project sets no `GO_PORT` |
| `GO_PROXY` | `https://goproxy.cn,direct` | Go module proxy |
| `GO_CACHE_ROOT` | `~/phpbox/cache/go` | GOPATH cache root, one subdirectory per version |
| `GO_CGO_ENABLED` | `0` | Default `CGO_ENABLED`; overridable per project |
| `PROJECT_NAME` / `NETWORK_NAME` etc. | see `.env.example` | Compose project / shared network / naming rules |

## Directory Layout & Generated Files

```
$HOME/phpbox/
├── bin/phpbox                    # thin entry: fixed loading chain, then lib/cli.sh
├── lib/                          # four-layer structure (see AGENTS.md §3)
│   ├── common/                   # global layer: env/log/paths/ports/docker/config + install framework
│   ├── cli.sh                    # command routing and global commands (help/list)
│   ├── php/ mysql/ redis/ nginx/ site/ go/ backup/   # service lines, each with common/, versions/, cli.sh
├── compose/                      # main compose (shared network) + per-service-version yml fragments
├── config/                       # per-version service configs and PHP extension manifests
├── offline/                      # offline cache (php/<version>/apk+pecl/; mysql & redis/<version>/ image tars)
├── cache/go/<version>/           # Go GOPATH module and tool caches
├── backups/                      # backup archives
├── logs/                         # Nginx and PHP logs
└── .env                          # environment variables (user-editable)
```

The repository **tracks only sources and templates**: `bin/phpbox`, `lib/`, `install.sh`, `tests/`, `.env.example`, docs, and `.gitkeep` placeholders. Everything else is generated at runtime, listed in `.gitignore`, and rebuilt automatically by `install.sh` on a clean clone — editing generated files directly won't persist; change the generating logic or `.env` instead.

| Generated file | Produced by |
| --- | --- |
| `.env` | `install.sh` (contains plaintext passwords — never committed) |
| `compose/` yml files | `install.sh` / service install commands |
| `config/php/*/Dockerfile`, `php.ini` | `php install`, `php extension add/remove` |
| `config/mysql/*/my.cnf`, `config/nginx/*/{nginx.conf,conf.d/}`, `config/redis/*/redis.conf` | extracted from images or generated on first install; user-editable |
| `config/nginx/sites/*.conf` | `site add` |
| `config/php/*/extensions.env`, `logs/*.log`, `backups/*.tar.gz` | install process & runtime |
| `offline/` (php build closures + mysql/redis image tars), `cache/go/` | promoted after verified builds / written back after image pull / Go commands |

## Testing

```bash
bash tests/lint.sh    # bash -n syntax gate over all shell sources
bash tests/run.sh    # five gates: lint → function inventory → smoke → offline-first → install-order
```

Behavior tests prefer controlled fakes (fake curl, sandboxed dirs) and don't require the network; items needing real Docker are labeled explicitly.

## FAQ

- **bash too old**: on macOS, `brew install bash` and run everything with the new one.
- **Port in use**: a free port is picked automatically when unspecified; with `--port`, the occupying process is reported.
- **Forgot a database password**: MySQL/Redis passwords live in `.env` (`MYSQL_<version>_ROOT_PASSWORD` / `REDIS_<version>_ROOT_PASSWORD`), which is never committed.
- **Site unreachable**: check `site list` and `hosts list`; include the port if Nginx isn't on 80.
- **PHP build stalls on downloads**: verify `APK_MIRRORS` reachability; set `BUILD_PROXY` to a local proxy on restricted networks.
- **Start over with configs**: delete the matching `config/<service>/<version>/` directory; the next install regenerates it.
- **Go project not discovered**: it must be a direct subdirectory of `GO_PROJECTS_ROOT` containing `go.mod`; inspect `go server`.
- **Go image refuses to uninstall**: `go stop` the project containers using it first.
