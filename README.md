# phpbox

多版本 Docker 开发环境管理器（LNMP）。纯 Bash 实现：一条命令装好 PHP / MySQL / Redis / Nginx，版本与站点可随时切换、互不干扰。

## 特性

- 多版本 PHP、MySQL、Redis 和 Go Docker 开发环境
- Go 项目按 `go.mod` 自动发现，不需要通过 phpbox 创建项目
- Go 镜像支持最新稳定版和指定版本，项目可使用根目录 `.env` 覆盖配置
- Go 容器固定使用 `/workspace`，按版本持久化 GOPATH 缓存
- Nginx 统一使用宿主机端口，Go 项目通过 `<项目名>.test` 访问
- 配置生成、服务启动、失败清理和 Nginx 重载均有阶段日志

## 文档大纲

- [安装与快速开始](#安装)
- [命令参考](#命令参考)
- [Go 开发操作手册](#go)
- [环境变量](#环境变量env)
- [目录结构与生成物](#目录结构)
- [备份与恢复](#备份与恢复)
- [测试与验收](#测试)
- [常见问题](#常见问题)

## 前置条件

- Docker 与 Docker Compose 插件
- bash ≥ 4.4（用到 `${var^^}`、`mapfile` 等；macOS 自带 3.2，请先 `brew install bash`）

## 安装

```bash
git clone <仓库地址> phpbox
cd phpbox
bash install.sh
```

`install.sh` 会创建 `~/phpbox` 目录结构、复制 CLI 源码、生成主 compose 文件与默认 `.env`，并把 `phpbox` 软链到 `/usr/local/bin`（需 sudo，不可用时给出手动命令）。

## 快速开始

```bash
phpbox php install 8.4                  # 安装 PHP（默认扩展集见 PHP_DEFAULT_EXTENSIONS）
phpbox nginx install                    # 安装 Nginx
phpbox mysql install 8.4                # 安装 MySQL（完成后显示 root 密码）
phpbox site add demo.test --php 8.4     # 创建站点
phpbox hosts add demo.test              # 添加 hosts 解析（需 sudo）
phpbox list                             # 查看已安装服务
```

访问 `http://demo.test`；若 Nginx 端口不是 80，需带上端口（`phpbox site add` 完成后会提示实际地址）。

## 命令参考

### PHP

| 命令 | 说明 |
| --- | --- |
| `phpbox php install <版本> [--ext 扩展列表]` | 安装 PHP；不带 `--ext` 时安装 `PHP_DEFAULT_EXTENSIONS`（`--extensions` 为兼容别名） |
| `phpbox php extension add <版本> <扩展>` | 添加扩展（自动重建镜像并重载） |
| `phpbox php extension remove <版本> <扩展>` | 移除扩展 |
| `phpbox php list` | 列出所有 PHP 实例 |
| `phpbox php uninstall <版本> [--purge]` | 卸载（`--purge` 连同镜像与配置一起清除） |

### MySQL

| 命令 | 说明 |
| --- | --- |
| `phpbox mysql install <版本> [--port 端口]` | 安装 MySQL，完成后显示 root 密码（并存进 `.env`） |
| `phpbox mysql port set <版本> <新端口>` | 修改端口（失败自动回滚） |
| `phpbox mysql list` | 列出所有 MySQL 实例 |
| `phpbox mysql uninstall <版本> [--purge]` | 卸载（`--purge` 连同数据目录清除） |

### Redis

| 命令 | 说明 |
| --- | --- |
| `phpbox redis install [<版本>] [--port 端口]` | 安装 Redis；省略版本使用最新稳定主版本 Redis 8，省略端口使用 6379，密码保存到 `.env` 的 `REDIS_<去点版本>_ROOT_PASSWORD` |
| `phpbox redis port set <版本> <新端口>` | 修改端口 |
| `phpbox redis list` | 列出所有 Redis 实例 |
| `phpbox redis uninstall <版本> [--purge]` | 卸载 |

### Go

Go 项目不需要通过 phpbox 创建。`GO_PROJECTS_ROOT` 下的直接子目录只要包含 `go.mod`，就会自动识别为项目，目录名就是项目名。phpbox 不修改项目源码，也不会自动生成 `go.mod`。

```text
~/www/my-go-app/
├── .env          # 可选，仅覆盖 Go 容器配置
├── go.mod
└── main.go
```

项目 `.env` 可设置：

```dotenv
GO_VERSION=1.24
GO_PORT=8080
GO_CGO_ENABLED=0
```

项目 `.env` 只覆盖 Go 容器配置。`GO_VERSION` 选择镜像，`GO_PORT` 是应用在容器内监听的端口，`GO_CGO_ENABLED` 对应容器中的 `CGO_ENABLED`。不需要配置 `GOROOT` 和 `GOPATH`。

Go 全局默认值、国内模块代理和缓存位置在 phpbox `.env` 中设置：

```dotenv
GO_PROJECTS_ROOT=/home/kentrl/www
GO_DEFAULT_VERSION=alpine
GO_DEFAULT_PORT=8080
GO_PROXY=https://goproxy.cn,direct
GO_CACHE_ROOT=/home/kentrl/phpbox/cache/go
GO_CGO_ENABLED=0
```

配置优先级为：项目根目录 `.env` > phpbox 全局 `.env` > 内置默认值。`GO_PROXY` 只负责 Go 模块下载代理，当前默认使用国内的 `goproxy.cn`。

常用命令：

```bash
phpbox go list
phpbox go server
phpbox go install                  # golang:alpine，最新稳定版
phpbox go install 1.24             # golang:1.24-alpine
phpbox go uninstall latest         # 卸载 golang:alpine
phpbox go uninstall 1.24           # 卸载 golang:1.24-alpine
phpbox go run my-go-app
phpbox go test my-go-app
phpbox go shell my-go-app
phpbox go logs my-go-app
phpbox go stop my-go-app
phpbox go env my-go-app
```

`phpbox go list` 查看本机已下载的 Go 镜像和已创建的 Go 容器；`phpbox go server` 查看 `GO_PROJECTS_ROOT` 下自动发现的 Go 项目及其运行状态。

#### Go 操作流程

1. 准备项目目录并创建 `go.mod`：

	```bash
	mkdir -p /home/kentrl/www/my-go-app
	cd /home/kentrl/www/my-go-app
	go mod init my-go-app
	```

2. 安装默认最新稳定版镜像，或指定版本：

	```bash
	phpbox go install             # golang:alpine
	phpbox go install 1.24        # golang:1.24-alpine
	```

	`go install` 只负责拉取镜像并保存 `GO_DEFAULT_VERSION`，不会创建没有项目挂载的空容器。

3. 启动或进入项目容器：

	```bash
	phpbox go shell my-go-app     # 启动容器并进入 /workspace
	phpbox go run my-go-app       # 在容器中执行 go run .
	phpbox go test my-go-app      # 在容器中执行 go test ./...
	```

4. 查看状态和环境：

	```bash
	phpbox go list                # Go 镜像和已创建的 Go 容器
	phpbox go server              # 自动发现的 Go 项目及状态
	phpbox go env my-go-app       # GOROOT、GOPATH、模块和编译缓存路径
	phpbox go logs my-go-app
	phpbox go stop my-go-app
	```

5. 使用 Nginx 域名访问：

	```bash
	phpbox nginx install
	phpbox go run my-go-app
	phpbox hosts add my-go-app.test
	```

	Go 容器不发布宿主机端口，Nginx 使用宿主机 `NGINX_PORT`，默认是 `80`，再转发到 `go-my-go-app:<GO_PORT>`。项目默认地址为 `http://my-go-app.test`。

#### Go 容器路径

| 路径 | 作用 | 管理方式 |
| --- | --- | --- |
| `/workspace` | 项目源码 | 宿主机项目目录挂载 |
| `/usr/local/go` | `GOROOT`，Go 编译器和标准库 | 由 Go 镜像提供，不手动挂载 |
| `/go` | `GOPATH`，模块缓存和工具 | 挂载到 `GO_CACHE_ROOT/<版本>/` |

当前持久化的是 GOPATH 下的模块和工具缓存，不是完整离线仓库。首次拉取镜像或下载依赖仍可能需要网络；离线模式暂不支持。

#### Go 镜像卸载

```bash
phpbox go uninstall latest         # 卸载 golang:alpine
phpbox go uninstall 1.24           # 卸载 golang:1.24-alpine
phpbox go uninstall 1.24 --purge   # 同时删除 cache/go/1.24
```

也兼容输入完整镜像标签，例如 `phpbox go uninstall golang:alpine`。如果镜像仍被 Go 项目容器使用，必须先执行 `phpbox go stop <项目>`；卸载不会删除项目源码。

### Nginx

| 命令 | 说明 |
| --- | --- |
| `phpbox nginx install [--port 端口]` | 安装 Nginx（镜像 tag 由 `NGINX_VERSION` 决定，默认 `alpine`） |
| `phpbox nginx port set <新端口>` | 修改端口 |
| `phpbox nginx reload` | 校验配置并重载 |
| `phpbox nginx uninstall` | 卸载（保留配置与站点） |

### 站点与域名

| 命令 | 说明 |
| --- | --- |
| `phpbox site add <域名> --php <版本>` | 创建站点（生成 vhost 并校验、重载，失败回滚） |
| `phpbox site switch <域名> --php <版本>` | 切换站点的 PHP 版本 |
| `phpbox site list` | 列出站点及其使用的 PHP |
| `phpbox site remove <域名>` | 删除站点（可选一并删除站点目录） |
| `phpbox hosts add <域名>` | 添加 hosts 解析（需 sudo） |
| `phpbox hosts remove <域名>` | 移除 hosts 解析 |
| `phpbox hosts list` | 查看站点域名的 hosts 状态 |

### 全局

| 命令 | 说明 |
| --- | --- |
| `phpbox list` | 列出所有已安装服务 |
| `phpbox backup` | 备份配置、状态与数据卷到 `backups/` |
| `phpbox restore <备份文件> [-y]` | 恢复备份（`-y` 非交互确认） |
| `phpbox help` | 查看全部命令 |

## 环境变量（`.env`）

首次安装生成默认 `.env`，可按需调整（键名规则见 `.env.example`）。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PROJECT_NAME` / `NETWORK_NAME` | `phpbox` / `phpboxnet` | compose 项目名与共享网络名 |
| `WWW_ROOT` | `~/www` | 网站根目录（挂到容器 `/var/www`） |
| `MYSQL_DATA_ROOT` | `~/mysql-data` | MySQL 数据主目录 |
| `CURRENT_UID` / `CURRENT_GID` | 当前用户 | 容器内 `www-data` 对齐宿主机属主，避免文件权限问题 |
| `NGINX_PORT` | `80` | Nginx 宿主端口 |
| `NGINX_VERSION` | `alpine` | Nginx 镜像 tag；换 tag 只换主配置目录，站点目录不变 |
| `PHP_DEFAULT_EXTENSIONS` | 见 `.env.example` | `php install` 不带 `--ext` 时的默认扩展集 |
| `MYSQL_<去点版本>_PORT` / `MYSQL_<去点版本>_ROOT_PASSWORD` | `3380`/`3384`、自动生成 | 如 `MYSQL_84_PORT`、`MYSQL_84_ROOT_PASSWORD`；安装前预置密码即生效 |
| `REDIS_<去点版本>_PORT` / `REDIS_<去点版本>_ROOT_PASSWORD` | `6379`、自动生成 | 如 `REDIS_8_PORT`、`REDIS_8_ROOT_PASSWORD`；Redis 安装完成后自动写入 `.env` |
| `GO_PROJECTS_ROOT` | `~/www` | Go 项目扫描根目录；直接子目录含 `go.mod` 即自动发现 |
| `GO_DEFAULT_VERSION` | `alpine` | Go 默认镜像版本；`alpine` 表示最新稳定版 |
| `GO_DEFAULT_PORT` | `8080` | 项目未设置 `GO_PORT` 时的容器内端口 |
| `GO_PROXY` | `https://goproxy.cn,direct` | Go 模块下载代理 |
| `GO_CACHE_ROOT` | `~/phpbox/cache/go` | GOPATH 缓存根目录，按版本分目录 |
| `GO_CGO_ENABLED` | `0` | Go 默认 `CGO_ENABLED` 值，项目 `.env` 可覆盖 |
| `*_SERVICE_PREFIX`、`*_SEPARATOR`、`IMAGE_PREFIX` | 见 `.env.example` | 容器名 / 镜像 tag / 标签的命名规则 |

## 目录结构

```
$HOME/phpbox/
├── bin/phpbox                    # 主入口脚本（用户调用）
├── lib/
│   ├── common.sh                 # 公共函数：日志、环境加载、端口检查、Docker 预检、回滚框架等
│   ├── build.sh                  # PHP 镜像构建：apk/pecl 离线缓存、Dockerfile 渲染、构建验证
│   ├── php.sh                    # PHP 命令实现：install/extension/list/uninstall
│   ├── mysql.sh                  # MySQL 管理（未提供完整，但接口由主入口调用）
│   ├── redis.sh                  # Redis 管理
│   ├── nginx.sh                  # Nginx 管理
│   ├── site.sh                   # 站点管理
│   ├── go.sh                      # Go 镜像、项目发现和容器管理
│   └── backup.sh                  # 备份与恢复
├── compose/
│   ├── docker-compose.yml        # 主 compose（仅定义共享网络）
│   └── services/                 # 每个服务版本一个 yml 分片（如 php-8.4.yml）
├── config/                       # 各服务版本配置与 PHP 扩展清单
├── offline/                      # 离线构建缓存（php/<版本>/apk/、pecl/）
├── cache/go/<版本>/               # Go GOPATH 模块和工具缓存（运行期生成）
├── backups/                      # 备份归档
└── .env                          # 环境变量配置文件（用户可修改）
```

### 仓库里有什么

仓库**只跟踪源码与模板**：`bin/phpbox`、`lib/*.sh`、`install.sh`、`tests/*.sh`、`.env.example`、`README.md`、`.gitignore`，以及保证空目录存在的几个 `.gitkeep`。

其它一切都是运行期生成物，已列入 `.gitignore`，不会入仓：

| 生成物 | 由谁生成 |
| --- | --- |
| `.env` | `install.sh`（含明文密码，绝不入仓） |
| `compose/docker-compose.yml`、`compose/services/*.yml` | `install.sh` / 各服务安装命令 |
| `config/php/*/Dockerfile`、`config/php/*/php.ini` | `php install`、`php extension add/remove` |
| `config/mysql/*/my.cnf`、`config/nginx/*/{nginx.conf,conf.d/}`、`config/redis/*/redis.conf` | 首次安装对应服务时从镜像提取或按版本生成，用户可直接修改 |
| `config/nginx/sites/*.conf` | `site add` |
| `config/php/*/extensions.env`、`logs/*.log`、`backups/*.tar.gz` | 安装过程与运行期 |
| `cache/go/<版本>/`、`compose/services/go-*.yml` | Go 镜像/项目命令 |

因此干净 clone 后**不需要**这些文件：执行 `install.sh`（或任意 `phpbox` 命令，`load_env` 会自动补建主 compose 文件与目录结构）即可重建。迁移或排错时改了生成物不会有预期效果——要改的是生成它们的逻辑，或改 `.env` 后重新安装。

## 备份与恢复

```bash
phpbox backup                       # 打包 .env、config/ 与数据卷
phpbox restore backups/backup-<时间戳>.tar.gz
```

备份过程会先停服务、再打包、最后启动；恢复前会校验归档成员路径，含 `..` 的归档在解包前即被拒绝。备份包含 `WWW_ROOT` 中的 Go 源码和 `.env`，但不包含 `cache/go/` 及 Docker 镜像；换机恢复后需要重新执行 `phpbox go install`。

## 测试

```bash
bash tests/lint.sh   # 结构检查（函数长度、嵌套深度）+ shellcheck（若已安装）
bash tests/run.sh    # 行为回归测试：使用假 HOME，不需要 Docker daemon
```

## 常见问题

- **提示 bash 版本过低**：macOS 需 `brew install bash`，并用新版 bash 运行 `install.sh` 与 `phpbox`。
- **端口被占用**：安装时不指定端口会自动选空闲端口；也可 `--port` 显式指定，被占用会提示占用者。
- **忘了 MySQL root 密码**：密码存在 `.env` 的 `MYSQL_<去点版本>_ROOT_PASSWORD`，该文件不入仓。
- **站点打不开**：先用 `phpbox site list` 确认站点存在、`phpbox hosts list` 确认域名已解析，并注意 Nginx 端口非 80 时需带端口访问。
- **删掉配置想重来**：删除对应 `config/<服务>/<版本>/` 目录，下次安装会自动重新提取/生成。
- **Go 项目未被发现**：确认项目是 `GO_PROJECTS_ROOT` 的直接子目录，并且目录中存在 `go.mod`；使用 `phpbox go server` 查看发现结果。
- **Go 镜像无法卸载**：先用 `phpbox go list` 找到使用该镜像的容器，执行 `phpbox go stop <项目>` 后再卸载。
- **Go 依赖下载慢**：确认 `GO_PROXY=https://goproxy.cn,direct`，并检查 `GO_CACHE_ROOT/<版本>/` 是否可写；当前项目不提供完整离线模式。
- **Go 应用访问失败**：确认应用监听的端口与项目 `.env` 的 `GO_PORT` 一致，Nginx 已安装运行，并执行 `phpbox hosts add <项目名>.test`。
