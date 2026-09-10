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
| 3 | 按线切片纯搬运（redis → mysql → nginx → site → go → backup → php/build → common 全局件） | 待办 |
| 4 | 旧 lib/*.sh 转兼容桥（source 新结构，新旧双可用） | 待办 |
| 5 | bin/phpbox 切新加载链（common → 线common → versions） | 待办 |
| 6 | 观察期后删旧平铺脚本与重复逻辑 | 待办 |
| 7 | 全面验证 + 同步 AGENTS.md/README/.github 指令中的 lib 路径引用 | 待办 |

## 附录 A：函数归属清单（第 1 步产出）

见后续提交填充；搬运切片以本清单为核对依据，清单与实际不一致时以闸门结果为准并回写清单。
