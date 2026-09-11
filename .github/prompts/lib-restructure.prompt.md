---
description: "Execute lib/ four-layer restructure per 新改造需求.txt with slice/verify/rollback discipline."
name: "phpbox lib restructure"
argument-hint: "Step number 0-7, or 'verify' to run all gates only"
---

# lib/ 四层重构迁移（执行规范）

权威需求：仓库根目录《新改造需求.txt》。本文件只固化执行纪律与裁决记录，与需求文档冲突时以需求文档为准。

## 执行纪律（每个切片必须依次通过后才进入下一片）

1. 纯搬运：搬运切片绝不夹带逻辑修改；改写类动作（回调化、拆解分发器）独立成片并单独验证。
2. 闸门三件（全部绿才算过片）：
   - `bash tests/lint.sh`——全量 bash -n（覆盖新旧两种目录形态）
   - `bash tests/functions.sh`——函数清单与 `tests/functions.baseline` 一致 + 无重复定义
   - `bash tests/smoke.sh`——CLI 冒烟（Docker daemon 不在时相关项输出 SKIPPED）
3. 每切片一个 git commit；验证失败 revert 单片重做，绝不带病前进。
4. 迁移期间运行时目录（`offline/ config/ compose/ .env backups/ cache/ logs/`）只读不写。

## 三处执行裁决（全部依需求文档自身条款作出）

1. **versions/ 可选加载**：`${线}/versions/${版本}.sh` 存在才 source，缺失回退本线 common 默认。
   依据 §十一.9（保持对旧调用的兼容）——现行 CLI 版本门放行任意 `8.*`，字面枚举加载会让
   `phpbox php install 8.1` 直接失败，违反兼容条款。
2. **state/ 目录**：按目标树保留空目录；PHP 扩展状态事实来源仍为
   `config/php/<版本>/extensions.env`，需求文档全文无回迁要求，不产生双源。
3. **lib/cli.sh**：承接 bin/phpbox 的命令路由实现；bin/phpbox 退化为薄入口
   （shebang + 转调 lib/cli.sh），同时满足 §六.1 固定加载链与既有"入口只路由"原则。

## 七步主线（对应需求文档 §八）

| 步 | 内容 | 状态 |
|---|---|---|
| 0 | 验证脚手架（tests/ 三闸门 + 本文件） | 完成 |
| 1 | 函数归属清单（附录 A，"拆"标记函数需独立重构切片） | 进行中 |
| 2 | 目录骨架 + 空职责文件（按需求文档 §三 目标树） | 待办 |
| 3 | 按线切片纯搬运（redis → mysql → nginx → site → go → backup → php/build → common 全局件） | 完成 |
| 4 | 旧 lib/*.sh 转兼容桥（source 新结构，新旧双可用） | 完成 |
| 5 | bin/phpbox 切新加载链（common → 线common → versions） | 完成 |
| 6 | 观察期后删旧平铺脚本与重复逻辑 | 完成（2026-09-12 删 9 桥，lib/ 仅剩 cli.sh 本体；引用核零：install.sh/bin/phpbox/tests 均无旧路径引用） |
| 7 | 全面验证 + 同步 AGENTS.md/README/.github 指令中的 lib 路径引用 | 完成 |

## 附录 A：函数归属清单（第 1 步产出，137 个函数全覆盖）

以 `tests/functions.baseline` 为核对底册；【拆】标记 = 纯搬运后需独立重构切片（回调化/提取版本差异），绝不与搬运混在同一提交。

### lib/common/（全局公共，36 个）

| 目标文件 | 函数 | 说明 |
|---|---|---|
| log.sh | log, success, error, confirm_yes | 终端输出与交互 |
| env.sh | _env_strip_quotes, _env_read_file, load_env, read_env_value, _load_apk_mirrors | .env 读取侧与镜像源列表归一化 |
| paths.sh | get_service_key, get_container_name, get_volume_name, validate_version | 命名/键名派生与版本号校验 |
| ports.sh | port_key, check_port, show_port_owner, check_and_report_port, find_free_port, get_or_set_port | 端口检查与分配 |
| docker.sh | require_docker, stop_and_remove_container, run_compose, http_probe_ok, _rm_rf_with_docker_fallback | Docker 预检与 Compose 通用调用 |
| config.sh | sed_i, escape_sed, env_set, env_unset | 配置持久化工具（.env 写入侧） |
| install.sh | get_or_set_password, _install_rollback_begin, _install_rollback_commit, _install_rollback_run, init_config_files, _generic_service_install, _generic_db_port_set, verify_service | 安装事务与回滚框架【拆：8 个内的服务 case 分发回调化】 |

### lib/cli.sh（2 个）：show_help（自 bin/phpbox 迁入）, cmd_list

### lib/php/（33 个）

| 目标文件 | 函数 | 说明 |
|---|---|---|
| common/install.sh | _php_install, _php_ensure_running, _php_show_list, _php_uninstall, _php_cleanup_images | 生命周期 |
| common/build.sh | build.sh 全部 17 个 + _apk_mirror_host_args, _apk_ranked_fetch_run | 镜像构建 + APK 下载器（仅 PHP 线使用，自 common.sh 迁入）。优化切片 A 后按职责拆为三文件：apk-fetch.sh（下载器）、offline.sh（离线资产事务）、build.sh（编排渲染），桥 lib/build.sh 三路转发 |
| common/extensions.sh | _php_get_extensions_file, _php_read_extensions, _php_write_extensions, _php_validate_extensions, _php_infer_installed_version, _php_extension_op | 扩展状态与操作 |
| common/config.sh | _php_generate_compose, _init_php_config | _init_php_config 自 nginx.sh 迁入（修正既有错位） |
| cli.sh | cmd_php | 子命令分发 |
| versions/7.4.sh | 【拆】imagick 3.7.0 / xdebug 3.1.6 旧版钉住（自 _php_pecl_tarball_url 提取） | versions/8.0.sh、8.4.sh 当前为空占位 |

### lib/mysql/（10 个）：install.sh（_mysql_clean_stale_sock, _mysql_ensure_running, _mysql_install, _mysql_show_list, _mysql_purge, _mysql_uninstall）、port.sh（_mysql_port_set）、config.sh（_mysql_generate_compose, _init_mysql_config【拆：8.4 认证差异 → versions/8.4.sh】）、cli.sh（cmd_mysql）；versions/{5.7,8.0}.sh 空占位

### lib/redis/（9 个）：install.sh（_redis_ensure_running, _redis_install, _redis_show_list, _redis_purge, _redis_uninstall）、port.sh（_redis_port_set）、config.sh（_redis_generate_compose, _init_redis_config）、cli.sh（cmd_redis）；versions/8.sh 空占位

### lib/nginx/（12 个）：install.sh（_nginx_ensure_running, _nginx_remove, _nginx_install, _nginx_port_set）、reload.sh（nginx_try_reload, _nginx_reload）、config.sh（_nginx_inject_sites_include, _init_nginx_config, _nginx_effective_version, _nginx_validate, _nginx_generate_compose）、cli.sh（cmd_nginx）；versions/{alpine,1.25}.sh 空占位

### lib/site/（12 个）：add.sh（_valid_domain, _site_rollback, _site_atomic_replace, _site_add, _site_remove）、switch.sh（_site_switch）、list.sh（_site_show_list）、hosts.sh（cmd_hosts, _hosts_add, _hosts_remove, _hosts_list）、cli.sh（cmd_site）

### lib/go/（15 个）：install.sh（_go_install, _go_uninstall）、run.sh（_go_prepare, _go_exec——run/test/shell/logs/stop/env 六个子命令经此分发）、shell.sh（占位，shell 由 _go_exec 分发，拆分后迁入）、server.sh（_go_server, _go_list, _go_proxy_nginx, _go_resolve_project, _go_resolve_version, _go_resolve_existing, _go_project_env_value, _go_validate_project_name, _go_generate_compose, _go_ensure_running）、cli.sh（cmd_go）；versions/{alpine,1.24}.sh 空占位

### lib/backup/（8 个）：common/backup.sh（_get_abs_path, _phpbox_stop_svc, _phpbox_start_stopped）、common/restore.sh（_restore_list_vol_files, _restore_collect_invalid_paths, _restore_volumes）、cli.sh（cmd_backup, cmd_restore——顶层命令实现）

### 跨线显式动作（§六.3 允许项，搬运时保留直调，cli.sh 全量加载保证函数在场）

- php/common/install.sh:53 → nginx_try_reload（PHP 起容器后刷新 upstream）
- site/common/add.sh:47,54,266 → _nginx_validate（改站点前先验 Nginx 配置）

### 树缺口判断记录（目标树未枚举、按命名规则补齐）

1. lib/common/install.sh：安装事务/回滚框架是全服务共享的基础设施，§四.1 六文件为"例如"式列举，按职责命名补此文件。
2. lib/site/common/hosts.sh：hosts 增删查现属 site 线，目标树未列，按职责命名补齐。
3. _site_remove 归 add.sh（站点变更生命周期）；_nginx_port_set 归 install.sh（目标树 nginx 线无 port.sh）。
4. backup/cli.sh 承接 cmd_backup/cmd_restore 两个顶层命令实现。

