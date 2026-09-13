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
| Tauri 2（Rust） | 备选 | bollard 社区库质量高但非官方；sidecar 可执行一次性命令，但**未提供"高频短生命周期命令 + 流式输出"的开箱即用抽象**（社区 tauri-sidecar-manager 的定位恰是长驻服务），需自行封装进程管理与输出转发；Rust 所有权范式迁移成本高；崩溃隔离优势在本规模可用 recover() + 看门狗对冲 |
| Electron | 拒绝 | 150MB+ 与"轻量本地工具"定位相悖；Docker Desktop 用 Electron 是历史包袱（其后端 com.docker.backend 为 Go 进程——先例验证的是"Go 引擎 + Web 技术 UI"的分层，而非 Electron 本身） |
| 本地 Web 服务（Portainer 形态） | 不作主形态 | 与"桌面软件"目标冲突；引擎保持框架无关，未来经 `cmd/phpboxd` + Gin 适配层可随时补位 |

## 3. Decision

1. **语言/引擎**：Go；`internal/engine/` 纯 Go 库（不 import 任何 UI/框架包），`cmd/phpboxd` 将引擎暴露为 CLI（parity 对拍 + 高级用户入口 + 未来 server 模式挂载点）。
2. **Docker 通信**：核心路径走 Engine API（官方 SDK + API 版本协商）；`docker compose` 与 `save/load` 仍包装 CLI（Docker Desktop 三平台自带）。
3. **桌面壳**：**当前用 Wails v2.10+（稳定版）**；Wails v3 为 beta——官方 2026-08-02 公告原文："This is a beta release, not the final 3.0 release. The desktop API is stable and teams are already using v3 in production, but you should test thoroughly before deploying"（桌面 API 已稳定、有生产使用，但无 GA 日期；中文社区流传的"已 GA"不实）。壳层仅 main.go + bindings 薄适配（引擎零依赖原则已定），v3 GA 后的迁移是**有界壳层任务**（Vue 前端零改动），估计 ≤2 天。
4. **Windows**：阶段 0（bash 引擎壳）只发布 Linux/macOS；Windows 随阶段 1 Go 引擎原生支持（Engine API named pipe），**不引入 WSL2 依赖**。
5. **前端**：Vue 3 + TypeScript + Vite + Naive UI + Pinia（不变）。

## 4. 被否决的替代判断（记录理由）

- "主选升级 Wails v3 Beta"：v3 对本项目实际收益有限（显式对象模型利好多窗口应用，本项目单窗口+对话框；TS 绑定注释保留是 DX 改进非决策级）；beta 对单人开发者的隐性税（文档缺口、beta 间破坏性变更、社区可搜索答案少）高于团队。引擎解耦原则使 v2→v3 成本有界，无需用 beta 换提前量。
- "现在决定 WSL2 vs 原生"：伪决策。阶段 0 不面向 Windows 发布；阶段 1 原生支持是 Engine API 架构的自然副产物。**条件项**：若未来公开发布且 Windows 用户占比显著，阶段 0 可追加"WSL2 预览版"（明确标注）收集反馈，而非完全跳过。

## 5. Consequences

- 正面：引擎可在无窗口环境独立开发测试（`go test ./internal/engine/...` + phpboxd）；bash 七闸门 → parity 对拍；v3 迁移成本有界；Windows 原生无需 WSL。
- 负面：v2 处于维护态（新特性不再进入）；若 v3 长期不 GA，壳层停留在 v2（对已发布桌面应用可接受——桌面依赖允许冻结）。**托盘约束显性化**：v2 官方不支持系统托盘（维护者确认 systray 不进 v2）；临时方案 energye/systray 存在 macOS 限制（"添加菜单后不可设置图标点击处理器"）——UI 规格 v2.1 中托盘属 v2 阶段能力，v0.1~v1.1 以最小化到任务栏替代，不构成阻塞。
- 中性：与 Docker Desktop 共存意味着 UI 空闲内存差（30 vs 60MB）无实际意义；体积与生态才是决策指标。

## 6. 重估触发条件（满足任一即重开本决策）

1. Wails v3 发布 stable GA → 评估迁移（预期 ≤2 天壳层任务）。
2. v2 出现影响核心功能且不再修复的缺陷（维护态风险兑现）。
3. 出现多窗口/系统托盘等 v2 无法满足的硬需求 → 提前评估 v3 或原生托盘方案。
4. bollard/Tauri 生态出现官方 Docker 背书 + 团队 Rust 能力变化 → 重开 Tauri 选项。
5. **壳层选型评估窗口（阶段 0.5，v1.0 构建前）**：复评 v3 状态——若已 GA 或进入后期 beta（破坏性变更停止）→ 直接以 v3 构建 v1.0，跳过迁移；若仍早期 beta → 继续 v2，托盘随 v3 迁移交付。
6. **时间检查点（2026-12-31，其后每年复核一次）**：检查点只安排"何时审视"，不构成迁移理由——重开本决策仍需技术条件成立（v3 仍未 GA **且** v2 出现影响开发效率的阻塞问题；备选含 Tauri 与纯 server 形态）。

---

## 7. 修订记录

**Amendment 1（2026-09-13，基于外部评审二）**：① v3 状态表述补官方原文（2026-08-02 公告：beta 但桌面 API 已稳定、有生产使用；纠正中文社区"已 GA"谣言）；② Tauri sidecar 论点精化（一次性命令可行，缺的是高频短命令+流式的开箱抽象）；③ 托盘约束显性化（v2 无官方托盘 + energye/systray 的 macOS 点击处理器限制）；④ 新增触发器 5/6（壳层评估窗口 + 时间检查点）；⑤ WSL2 追加公开发布条件项。核验来源：Wails 官方博客/FAQ/GitHub 状态表、Wails 维护者 leaanthony 关于 systray 不进 v2 的确认、docker client 官方文档（WithAPIVersionNegotiation 推荐）、tauri-sidecar-manager crate。
**Amendment 2（2026-09-13，基于外部评审三）**：外部评审确认——错误二分法成立（pgsql=事实性错误/危害半径小，托盘=前提性误读/技术判断本身准确）；"稳定 ≠ 适合作为起点"（beta 隐性税对单人+Go 新手放大）；"不切换 v3 不是押注 v3 不 GA，而是把决策权交给触发器"；规格 v2.1 九项采纳零过度采纳。修正：触发器 #6 语义显式化——日期只是审视时点，决策仍需技术条件（阻断"时间到了要迁移"的焦虑驱动误读）。**结论：决策框架收敛，后续有效输入转为代码（阶段 0 POC），不再接受对本 ADR 的进一步元评审。**

**Amendment 3（2026-09-13，触发器 #3 触发：用户确认托盘为硬需求）**：

评估：① v2 无官方托盘（维护者确认）；② v2 + energye/systray 在 **macOS 存在 AppDelegate 冲突（链接错误，Issue #1521）**，维护者在 Issue #1010 原话 "Running systray and Wails together is basically impossible"；社区补丁 ra1phdd/systray-on-wails 存在但维护性存疑；③ **Linux/Windows 下 energye/systray 与 v2 组合可用**（冲突仅 macOS）；④ Wails v3 内置原生托盘（官方文档）。

决策：**维持 v2，托盘经 energye/systray 实现，范围 Linux/Windows（v0.1 交付）；macOS 托盘随 v3 迁移交付**。理由：用户主力平台 Linux（energye 路径完全可用）；v3 beta 税（Amendment 1 论证）对单人开发仍高于"macOS 托盘延后"的代价；托盘实现隔离在 internal/app/tray（TrayProvider 接口），v3 迁移时仅换实现、菜单定义零改动。若 macOS 托盘提前成为硬需求 → 触发器 5（评估窗口）提前，按有界迁移切换 v3。

**Amendment 4（2026-09-13，触发器 #3 深化评估：托盘升级为一级产品能力 → 桌面壳切换 Wails v3 Beta）**

背景：外部规约 v2.0 将托盘从"图标"升格为一级产品能力（§6：服务状态菜单/最近任务/关闭到托盘生命周期/通知联动/图标状态指示），并提议桌面壳直接采用 Wails v3 Beta。原 Amendment 3 决策（v2 + energye/systray）被重新评估。

关键事实（本次核验）：

- macOS：v2 + energye 因 AppDelegate 冲突**完全不可用**（Issue #1521）——"跨平台"产品目标下，v2 路径在 macOS 结构性断裂。
- Linux：Wails v3 托盘依赖 GTK3 + libayatana-appindicator3，**目标机已装（ldconfig 实测确认）**；energye 依赖同一批库，依赖面持平。
- 时机：引擎尚未 Go 化、壳层零代码——"迁移 ≤2 天"的论据此刻处于**最强时点**：从 v3 起步彻底避免未来迁移；beta 税只落在薄壳层。
- v3 桌面 API 官方声明稳定，已有团队生产使用（2026-08-02 公告，Amendment 1 已核验）。

决策：**桌面壳切换为 Wails v3 Beta（go.mod 锁定具体 beta 版本），废止 Amendment 3 的 v2 + energye 路径**。

缓解措施（对 beta 税的对冲）：

- 壳层保持薄（main.go + bindings），引擎零依赖原则不变——beta 破坏性变更的爆炸半径 = 壳层。
- beta 版本显式锁定；升级为独立决策（读 release notes + 回归测试），不做自动跟随。
- 回退路径保留：本 ADR 历史完整记录 v2 方案；若 v3 出现阻塞性缺陷，引擎零改动降级 v2。
- Linux 前置依赖写入安装前置文档与 §6.7 式降级提示。

**Amendment 4 补充（同日，首次 Linux 构建实测）**：① wails3 doctor 报 ready 为**误报**——未检查编译链；实测根因链：gcc 未装 → Go 自动 CGO_ENABLED=0 → wails linux 文件（`pointer` 定义于 cgo 标签下）全部 undefined；pkg-config 与开发头文件亦缺。② **Linux 构建前置实测修正**：wails v3 beta.20 默认 **GTK4 + webkitgtk-6.0**（非 v2 时代 GTK3 栈）——`sudo apt install build-essential pkg-config libgtk-4-dev libwebkitgtk-6.0-dev`；托盘另需 libayatana-appindicator3（含 -dev）。③ 引擎纯 Go 部分不受影响（phpboxd list 正常）。

对 Amendment 3 的取代说明：其"beta 税 vs macOS 延后"权衡在"托盘=一个图标"的前提下成立；当托盘升为一级产品能力（状态菜单/最近任务/关闭到托盘/通知联动），前提改变，结论随之改变——在"什么都还没写"的时点，从最终框架起步是总成本最低的路径。energye 依赖废弃。

触发器 5/6（评估窗口/时间检查点）随本决策消化；新增回看点：**v3 项目停滞（≥12 个月无 beta 更新）且出现阻塞 → 重估（含回退 v2）**。

流程备注：外部规约 v2.0 声称"已在 ADR-001 Amendment 4 记录理由"——经核验该记录当时并不存在，本 Amendment 为补写（事实在先、记录在后），并对外部文档的无据断言予以更正。
