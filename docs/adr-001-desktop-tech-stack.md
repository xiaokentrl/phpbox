# ADR-001 · phpbox Desktop 技术栈决策记录

- 状态：Accepted（2026-09-13）
- 关联：docs/desktop-ui-spec-v2.md（UI 规格）、会话内两轮技术选型分析（本仓 AI + 外部 AI）
- 重估触发条件：见 §6

## 1. Context

phpbox（纯 Bash 的本地 Docker LNMP 管理器，70 文件/155 函数/七闸门测试）要升级为跨平台桌面应用。硬约束：

- 领域 = Docker 编排 + 文件事务（非 CRUD 应用），核心资产 = bash 侧验证过的事务/回滚/离线缓存经验
- 开发者单人，主力经验为 Bash（Go/Vue 均为新语言栈）
- 目标：轻量（拒绝再引入一个 Chromium）、真跨平台、复用 Web 前端

## 2. Considered Options

| 选项 | 结论 | 关键理由 |
| --- | --- | --- |
| Wails（Go + WebView） | **采用** | Docker 官方 Go SDK 是参考实现（API 版本协商/socket·named pipe 封装/事件流一等公民）；Go 心智模型与 Bash（trap/set -e → defer/error）迁移成本最低；绑定模型天然匹配"一次性命令 + 流式输出"（Tauri sidecar 模式假设长驻服务，需自定义进程管理绕行）；单进程调试便利 |
| Tauri 2（Rust） | 备选 | bollard 社区库质量高但非官方；sidecar 模式与一次性命令语义错配；Rust 所有权范式迁移成本高；崩溃隔离优势在本规模可用 recover() + 看门狗对冲 |
| Electron | 拒绝 | 150MB+ 与"轻量本地工具"定位相悖；Docker Desktop 用 Electron 是历史包袱（其后端 com.docker.backend 为 Go 进程——先例验证的是"Go 引擎 + Web 技术 UI"的分层，而非 Electron 本身） |
| 本地 Web 服务（Portainer 形态） | 不作主形态 | 与"桌面软件"目标冲突；引擎保持框架无关，未来经 `cmd/phpboxd` + Gin 适配层可随时补位 |

## 3. Decision

1. **语言/引擎**：Go；`internal/engine/` 纯 Go 库（不 import 任何 UI/框架包），`cmd/phpboxd` 将引擎暴露为 CLI（parity 对拍 + 高级用户入口 + 未来 server 模式挂载点）。
2. **Docker 通信**：核心路径走 Engine API（官方 SDK + API 版本协商）；`docker compose` 与 `save/load` 仍包装 CLI（Docker Desktop 三平台自带）。
3. **桌面壳**：**当前用 Wails v2.10+（稳定版）**；Wails v3 处于 beta（无 GA 日期），不作为起点。壳层仅 main.go + bindings 薄适配（引擎零依赖原则已定），v3 GA 后的迁移是**有界壳层任务**（Vue 前端零改动），估计 ≤2 天。
4. **Windows**：阶段 0（bash 引擎壳）只发布 Linux/macOS；Windows 随阶段 1 Go 引擎原生支持（Engine API named pipe），**不引入 WSL2 依赖**。
5. **前端**：Vue 3 + TypeScript + Vite + Naive UI + Pinia（不变）。

## 4. 被否决的替代判断（记录理由）

- "主选升级 Wails v3 Beta"：v3 对本项目实际收益有限（显式对象模型利好多窗口应用，本项目单窗口+对话框；TS 绑定注释保留是 DX 改进非决策级）；beta 对单人开发者的隐性税（文档缺口、beta 间破坏性变更、社区可搜索答案少）高于团队。引擎解耦原则使 v2→v3 成本有界，无需用 beta 换提前量。
- "现在决定 WSL2 vs 原生"：伪决策。阶段 0 不面向 Windows 发布；阶段 1 原生支持是 Engine API 架构的自然副产物。

## 5. Consequences

- 正面：引擎可在无窗口环境独立开发测试（`go test ./internal/engine/...` + phpboxd）；bash 七闸门 → parity 对拍；v3 迁移成本有界；Windows 原生无需 WSL。
- 负面：v2 处于维护态（新特性不再进入）；若 v3 长期不 GA，壳层停留在 v2（对已发布桌面应用可接受——桌面依赖允许冻结）。
- 中性：与 Docker Desktop 共存意味着 UI 空闲内存差（30 vs 60MB）无实际意义；体积与生态才是决策指标。

## 6. 重估触发条件（满足任一即重开本决策）

1. Wails v3 发布 stable GA → 评估迁移（预期 ≤2 天壳层任务）。
2. v2 出现影响核心功能且不再修复的缺陷（维护态风险兑现）。
3. 出现多窗口/系统托盘等 v2 无法满足的硬需求 → 提前评估 v3 或原生托盘方案。
4. bollard/Tauri 生态出现官方 Docker 背书 + 团队 Rust 能力变化 → 重开 Tauri 选项。
