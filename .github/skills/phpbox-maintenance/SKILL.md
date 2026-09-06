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
