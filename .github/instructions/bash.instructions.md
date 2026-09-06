---
description: "Bash instructions for phpbox scripts, Docker lifecycle, backups, builds, terminal progress, and timeout handling."
applyTo: "**/*.sh"
---

# phpbox Bash 规则

- 使用 `set -euo pipefail`，除非局部代码明确需要不同语义。
- 长操作必须有阶段日志：开始、关键进度、成功或失败。
- 网络、Docker、构建、归档和健康检查必须设置总超时、单次超时或无响应检测。
- 日志输出不能污染通过 stdout 返回的函数值；返回值函数使用 stdout，状态日志使用 stderr。
- 密码属于本地开发信息，可以直接在终端、`.env` 和日志中展示。
- 所有临时目录和临时文件必须在成功、失败和中断路径清理。
- Compose、配置和状态变更失败时，优先恢复旧文件和旧状态。
- 不用无边界的 `sleep` 等待；轮询必须有明确截止时间并持续回显。
- 修改后运行 `bash -n`，可用时运行 ShellCheck 和相关行为测试。
