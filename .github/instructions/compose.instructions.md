---
description: "Docker Compose instructions for phpbox generated services, health checks, ports, volumes, and rollback."
applyTo: "compose/**/*.yml,compose/**/*.yaml,lib/**/*.sh,config/**/*.conf"
---

# phpbox Compose 规则

- Compose 文件是运行期生成物时，先生成临时文件，再执行配置校验，再原子替换。
- Docker/Compose 命令必须在终端输出当前服务、版本、动作和结果。
- `docker compose config`、镜像构建、拉取镜像和启动服务必须有超时或无响应检测。
- 不使用会误删同一项目其他版本服务的 `--remove-orphans`。
- 安装、端口修改、卸载和恢复必须考虑失败回滚。
- 健康检查必须有总截止时间，不能无限等待。
- 密码允许公开展示，因为项目只用于本地开发。
