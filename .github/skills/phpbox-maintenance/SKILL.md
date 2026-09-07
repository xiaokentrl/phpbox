---
name: phpbox-maintenance
description: 'Maintain the phpbox local Docker development environment. Use for Bash changes, PHP/MySQL/Redis/Nginx lifecycle work, generated Compose, offline APK/PECL builds, site management, backup/restore, testing, and project cleanup.'
argument-hint: 'Describe the phpbox maintenance task, affected service, and desired verification.'
user-invocable: true
disable-model-invocation: false
---

# phpbox 维护工作流

## 适用范围

用于修改或审查 phpbox 的入口、Bash 模块、动态 Compose、服务配置、离线构建、站点、备份恢复和测试。

## 工作步骤

1. **读取规则和状态**：读取 `AGENTS.md`、`.github/copilot-instructions.md`、匹配的 instructions 及相关模块；执行 `git status --short`。
2. **定位控制点**：找到直接决定行为的入口、函数、生成器、Compose 模板或测试，不在无关目录扩散搜索。
3. **形成假设**：用一句话说明根因假设，并选一个最便宜、可证伪的检查。
4. **说明计划**：告诉用户将修改的文件、执行阶段、风险和验证方式。
5. **最小编辑**：保留用户已有改动；配置先写临时文件并校验，成功后再替换正式文件。
6. **立即验证**：第一次编辑后先运行窄测试、`bash -n` 或配置校验；不要先做无关读取或重构。
7. **同片修复**：失败时只修复当前行为切片，重跑同一个验证，再决定是否扩大范围。
8. **运行期检查**：确认终端阶段日志、进度、超时、退出码、临时目录清理和旧状态回滚。
9. **交付报告**：列出实际变更、验证命令及结果；缺少测试时标记 `SKIPPED` 并说明原因。

## PHP 离线依赖晋升流程

修改或排查 PHP 构建时，按以下边界检查 APK/PECL：

1. **暂存**：APK 闭包和 PECL 包写入 `config/php/<版本>/` 下的本次构建暂存目录；记录来源、包数量和目标版本。此时不得写入 `offline/`。
2. **路径归一化**：通过公共环境加载逻辑解析 `OFFLINE_DIR`；支持默认项目路径、项目相对路径、绝对路径和 `~/...`，不得把未展开的 `~` 拼接到 `BASE_DIR` 下。
3. **构建验证**：生成 Dockerfile，执行带超时的镜像构建，并在镜像内验证扩展加载、`php -m`、关键 `php --ri` 和 `php-fpm -t`。任何失败都清理暂存，旧离线库保持不变。
4. **APK 提交**：仅离线构建进入提交；把暂存 `.apk` 复制到正式库同级临时目录，校验关键工具链和包数量后原子替换正式目录，再对正式目录复验。复验失败时恢复旧目录并返回非零。
5. **PECL 提交**：只复制本次新下载且已通过镜像构建验证的 `.tgz`，复制失败不得清空旧包；命中旧库的包不重复标记为新提交。
6. **收尾**：确认正式库存在且校验通过后，才删除构建暂存目录；日志必须分别报告提交开始、成功/失败、正式路径、清理和旧库保留状态。

最小验收重点：离线模式无 `.apk` 必须失败；在线降级必须明确跳过 APK 晋升；Docker 构建失败不能新增或覆盖 `offline/`；目标目录校验失败必须恢复旧库。

## Redis 本地配置流程

- `redis install` 必须创建 `config/redis/<版本>/redis.conf`，文件不存在或不完整时才生成默认模板，已有用户配置不得覆盖。
- Redis Compose 必须只读挂载 `./config/redis/<版本>/redis.conf`，并以该文件作为 `redis-server` 配置入口；修改后通过重建或重新安装服务使配置生效。
- Redis 认证密码只从 `.env` 的 `REDIS_<去点版本>_ROOT_PASSWORD` 注入启动参数，不写入 `redis.conf`；备份必须包含 `config/redis/` 和 `.env`。

## 强制行为

- 每个用户可感知步骤都要输出阶段和状态。
- 容易阻塞的 Docker、网络、构建、归档和健康检查必须有超时或无响应检测。
- 长操作必须输出进度。
- 本项目是本地开发环境，密码可以直接展示，方便查阅。
- 不执行 `git reset --hard`、`git checkout --` 或提交操作。

## 验证清单

```bash
bash -n install.sh bin/phpbox lib/*.sh
bash tests/lint.sh
bash tests/run.sh
```

测试文件不存在时，明确报告缺失，不伪造测试通过。

## 操作阶段模板

长操作统一输出：`开始 -> 进行中 -> 成功/失败 -> 清理/回滚结果`。网络、Docker、构建和健康检查必须显示目标、超时和进度；失败时必须说明旧文件或旧服务是否仍保持不变。
