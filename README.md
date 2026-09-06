# phpbox

多版本 Docker 开发环境管理器（LNMP）。纯 Bash 实现：一条命令装好 PHP / MySQL / Redis / Nginx，版本与站点可随时切换、互不干扰。

## 特性


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
| `phpbox redis install <版本> [--port 端口]` | 安装 Redis |
| `phpbox redis port set <版本> <新端口>` | 修改端口 |
| `phpbox redis list` | 列出所有 Redis 实例 |
| `phpbox redis uninstall <版本> [--purge]` | 卸载 |

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
│   └── backup.sh                 # 备份与恢复
├── compose/
│   ├── docker-compose.yml        # 主 compose（仅定义共享网络）
│   └── services/                 # 每个服务版本一个 yml 分片（如 php-8.4.yml）
├── config/                       # 各服务版本配置与 PHP 扩展清单
├── offline/                      # 离线构建缓存（php/<版本>/apk/、pecl/）
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
| `config/mysql/*/my.cnf`、`config/nginx/*/{nginx.conf,conf.d/}` | 首次安装对应服务时从镜像提取或按版本生成 |
| `config/nginx/sites/*.conf` | `site add` |
| `config/php/*/extensions.env`、`logs/*.log`、`backups/*.tar.gz` | 安装过程与运行期 |

因此干净 clone 后**不需要**这些文件：执行 `install.sh`（或任意 `phpbox` 命令，`load_env` 会自动补建主 compose 文件与目录结构）即可重建。迁移或排错时改了生成物不会有预期效果——要改的是生成它们的逻辑，或改 `.env` 后重新安装。

## 备份与恢复

```bash
phpbox backup                       # 打包 .env、config/ 与数据卷
phpbox restore backups/backup-<时间戳>.tar.gz
```

备份过程会先停服务、再打包、最后启动；恢复前会校验归档成员路径，含 `..` 的归档在解包前即被拒绝。

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
