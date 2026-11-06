# 一生一芯公开成果索引与检查记录

[一生一芯栏目](../README.md) · [实验目录](../../README.md) · [名词与缩写](../../glossary/README.md)

以下条目均为第三方公开仓库，著作权归原作者。本页仅提供链接、元数据和独立撰写的技术摘要与检查意见；仓库信息以 2026-11-06 GitHub API 查询为准，作者自述内容未在本仓库环境复现。

## 1. 索引总表

| 编号 | 仓库 | 类型 | 主要内容（作者自述） | 许可证状态 | 最近推送 | 复现状态 |
| --- | --- | --- | --- | --- | --- | --- |
| Y-01 | [OSCPU/ysyx-workbench](https://github.com/OSCPU/ysyx-workbench) | 官方框架 | 工程初始化脚本与子项目组织 | 未声明 | 2026-10-14 | 未复现 |
| Y-02 | [OSCPU/ysyxSoC](https://github.com/OSCPU/ysyxSoC) | 官方 SoC | 外设、rocket-chip 子模块与 mill 构建 | 未声明 | 2026-10-23 | 未复现 |
| Y-03 | [Yawei-Ding/ysyx_riscv64_cpu](https://github.com/Yawei-Ding/ysyx_riscv64_cpu) | 处理器设计 | RV64 五级流水线、旁路与冒泡、Booth/Wallace 乘法器、除法器、I/D Cache、AXI 转换 | 未声明 | 2023-04-23 | 未复现 |
| Y-04 | [xiaoan109/ysyx-workbench](https://github.com/xiaoan109/ysyx-workbench) | 处理器设计 | 多周期 CPU、接入 ysyxSoC、简单 iCache | 未声明 | 2025-01-13 | 未复现 |
| Y-05 | [Han-0107/ysyx_workbench_hyh](https://github.com/Han-0107/ysyx_workbench_hyh) | 系统软件与处理器 | NEMU 运行仙剑奇侠传、Flappy Bird；NPC 运行字符版 Super Mario | 未声明 | 2024-03-17 | 未复现 |
| Y-06 | [curryfromuestc/ysyx_curry](https://github.com/curryfromuestc/ysyx_curry) | 处理器设计 | 使用 Chisel 实现 NPC | 未声明 | 2025-05-15 | 未复现 |
| Y-07 | [leesum1/ysyx](https://github.com/leesum1/ysyx) | 完整工作区 | 包含 PA 阶段分支（默认分支 `pa4`）的工作区 | 未声明 | 2023-10-28 | 未复现 |
| Y-08 | [Seeker0472/ysyx-linux](https://github.com/Seeker0472/ysyx-linux) | A 阶段拓展 | 在 NEMU（rv32ima_zicsr_zifencei）上启动 Linux Kernel 的笔记与分享 | README 以徽章标注 CC BY-SA 4.0 与 MIT，未登记许可证文件 | 2025-06-01 | 未复现 |
| Y-09 | [CSerht/ysyx-sdb-tui](https://github.com/CSerht/ysyx-sdb-tui) | 调试工具 | 基于 vim clientserver、gdb-multiarch 与 pyelftools 的 sdb 源码/反汇编定位界面 | MIT | 2024-03-11 | 未复现 |
| Y-10 | [MrAMS/verilogModuleAddPrefix](https://github.com/MrAMS/verilogModuleAddPrefix) | 工程工具 | 为 Verilog/SystemVerilog 模块名添加学号前缀并更新实例化 | GPL-3.0 | 2024-03-04 | 未复现 |
| Y-11 | [arch-simulator-sig/advanced-computer-architecture](https://github.com/arch-simulator-sig/advanced-computer-architecture) | 进阶研讨 | 超标量、Cache、TileLink、CVA6、香山前端等研讨资料与高阶自学大纲 | CC BY-SA 4.0 | 2026-09-24 | 资料类 |

## 2. 代表性成果摘要与检查意见

### Y-03：RV64 五级流水线处理器

**技术要点（据作者 README 整理）：**

- 模块划分为 IFU、IDU、EXU、LSU、WBU，另有 BRU、CLINT、寄存器堆旁路、CSR、I/D Cache 和统一接口到 AXI 的转换模块。
- 数据冒险由后续三级向译码级旁路；load-use 冒险通过向 ID/EX 插入 nop 并冻结 PC 与 IF/ID 处理。
- 控制冒险采用静态“预测不跳转”，误预测时清除 IF/ID。作者比较分支在 ID 与 EX 计算的关键路径：低频时提前计算可减少冒泡，高频时应后移以缩短组合路径。
- 乘法器将 64 位操作数扩展为 66 位以统一有符号/无符号运算，采用 radix-4 Booth 编码与 Wallace 树压缩。

**检查意见：**

| 检查项 | 结论 |
| --- | --- |
| 设计取舍 | 旁路深度与主频、分支计算级与冒泡次数的权衡论述清楚，适合作为流水线设计参考 |
| 时序数据 | README 引用路径延迟数值，但未给出工艺库、综合工具与约束条件，不能直接用于频率比较 |
| 验证证据 | README 未集中列出 difftest、官方测试集与 RT-Thread 运行日志，需到源码和提交记录中核对 |
| 复用边界 | 未声明许可证，仅可参考设计思路，不复制代码 |

### Y-04：多周期 CPU 接入 ysyxSoC

**技术要点：**多周期实现，已接入 ysyxSoC 与简单 iCache；`fence.i` 采用整体失效 iCache 的简化处理；作者注明组相联部分的形式化验证尚未迁移，axi4delayer 未实现，后续计划引入 SV+UVM 或 cocotb 验证平台。

**检查意见：**README 列出未完成项，便于界定验证范围。整体失效方案在功能上可行，但会增加 `fence.i` 之后的缺失开销；未实现 axi4delayer 时访存延迟与真实 SoC 存在差异，性能计数不宜直接与流片环境比较。

### Y-05：NEMU 与 NPC 运行应用程序

**技术要点：**NEMU 运行仙剑奇侠传、Flappy Bird 与自写终端；NPC 运行字符版 Super Mario，表明 AM 运行时、设备输入输出与处理器功能形成闭环。

**检查意见：**截图可作为功能演示，但不等同于测试集通过证明。复核时需补充运行命令、镜像来源、difftest 是否开启及测试集结果；游戏数据文件受其自身版权约束，不随作业分发。

### Y-08：在 NEMU 上启动 Linux

**技术要点：**面向 rv32ima_zicsr_zifencei 配置的 NEMU，提供启动 Linux Kernel 的笔记、网页版文档与分享视频。

**检查意见：**属于 A 阶段“启动 Linux”方向的拓展参考。README 以徽章标注 CC BY-SA 4.0 与 MIT，但未登记许可证文件；引用文字按 CC BY-SA 署名并以相同方式共享，代码复用前须确认作者对各部分的许可范围。

### Y-09 / Y-10：调试与工程工具

- **sdb TUI**：NEMU/NPC 单步时联动 vim 定位源码和反汇编；作者注明仅在 Ubuntu 22.04 测试，AM 程序需以 `-ggdb` 和 `-O1` 编译。集成需修改 NEMU 的 `Kconfig`、`init_monitor` 与执行循环，属于侵入式改动，应在独立分支评估。
- **模块前缀工具**：用于满足模块名带学号前缀的命名要求。GPL-3.0 要求分发衍生作品时保持相同许可证；作为外部工具调用即可，不必纳入作业源码。

## 3. 通用检查清单

对任一公开成果复核时逐项记录，未核实项填写“未复现”：

| 类别 | 检查内容 |
| --- | --- |
| 来源 | 仓库地址、提交哈希、期次与讲义版本、许可证 |
| 功能 | 支持的 ISA 扩展、特权级、异常与中断、设备 |
| 验证 | difftest 参考模型、官方测试集结果、RT-Thread/Linux 启动日志、随机或形式化验证覆盖 |
| 系统 | 是否接入 ysyxSoC、总线协议（AXI4/AXI4-Lite 等）、访存延迟模型 |
| 性能 | 主频来源（综合工具、工艺库、约束）、IPC/CPI 测量程序与统计窗口、缓存参数、面积 |
| 工程 | 构建依赖与版本、运行脚本、提交日志连续性、文档与代码一致性 |
| 合规 | 是否满足学号前缀等命名要求、是否包含受版权保护的第三方数据文件 |

## 4. 更新方法

新增条目时通过 GitHub API 读取仓库元数据并记录查询日期：

```bash
gh api repos/OWNER/REPO --jq '[.default_branch,.pushed_at,.language,(.license.spdx_id // "NONE"),.html_url] | @tsv'
```

条目只写独立撰写的摘要与检查意见；引用原文时控制篇幅并注明出处。仓库删除、转为私有或许可证变化时同步更新索引表。
