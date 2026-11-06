# 一生一芯（YSYX）：开源处理器芯片项目资料与公开成果

[实验目录](../README.md) · [名词与缩写](../glossary/README.md) · [公开成果索引与检查记录](projects/README.md)

“一生一芯”（One Student One Chip，YSYX）是面向学生的开源处理器芯片设计培养项目，以 RISC-V 处理器为主线，覆盖数字电路、C 语言系统软件、指令集模拟器、RTL 设计、仿真验证、SoC 集成、性能优化与流片准备。本栏目整理官方课程结构、公开学员成果的技术要点和复核方法，作为 DPU、GPU、NPU、存储方向之外的处理器设计参考栏目。

## 1. 收录原则

| 原则 | 说明 |
| --- | --- |
| 不复制作业源码 | 只记录来源链接、作者仓库、许可证状态和独立撰写的技术摘要；不搬运他人 RTL、NEMU、AM 代码或报告正文 |
| 来源可追溯 | 每项成果标注仓库地址、最近推送日期和许可证状态，以 2026-11-06 GitHub 公开信息为准 |
| 区分自述与复现 | 仓库 README 中的运行截图和功能描述记为“作者自述”；未在本仓库环境复现的内容不写成已验证结论 |
| 尊重许可证 | 未声明许可证的仓库默认保留全部权利，仅可链接和摘要；MIT、GPL、CC BY-SA 等也需遵守署名与传播条件 |
| 遵守学术诚信 | 官方流程要求学术诚信，提交答辩的代码若存在抄袭将被通报；本栏目只用于学习路线、设计思路和复核方法参考 |

## 2. 官方课程结构（v26.07）

官方课程主页为 [ysyx.oscc.cc/docs](https://ysyx.oscc.cc/docs/)。当前版本按 F→E→D→C→B→A→S 递进，学习以讲义为主，课件与录播为辅助材料；S 阶段内容仍在建设中。

| 阶段 | 主要内容 | 核心产出 | 关注重点 |
| --- | --- | --- | --- |
| F | 提问方法、Logisim、数字逻辑电路、状态机模型、数列求和处理器、简易输入输出 | 寄存器级小处理器 | 以状态机视角理解计算机系统 |
| E | 硬件描述语言、C 语言、Linux、仿真验证、迷你 RISC-V 处理器、运行时环境、总线与 SoC、后端物理设计 | 可仿真的迷你处理器与入学答辩材料 | 从 HDL 到仿真的基本工程能力 |
| D | C 到二进制、简易调试器、RISC-V 指令集、机器级表示、AM 运行时、RTL 仿真与综合、工具设施、RV32E NPC | NEMU 调试器、AM 程序与 RV32E 处理器 | 软件模拟器与 RTL 处理器对照 |
| C | ELF 与链接、设备 I/O、调试技巧、总线、SoC 计算机系统 | 接入 ysyxSoC 的处理器系统 | 总线协议、外设与系统级调试 |
| B | 异常处理与简易操作系统、时序分析、性能优化与缓存、流水线处理器 | 流水线处理器与考核材料 | 正确性、频率、IPC 与面积的取舍 |
| A | 乘除法器、系统调用、虚存、特权级与 xv6、启动 Linux/Debian、缓存与分支预测进阶 | 更完整的 RISC-V 系统 | 操作系统支持与微架构进阶 |
| S | 待续 | — | 以官方后续发布为准 |

官方考核流程要求定期提交学习记录、使用 Git 保留开发日志，通过指定测试并成功启动 RT-Thread，再参加技术答辩；参与流片的芯片需要对外开源。具体要求以 [OSCPU/ysyx 流程说明](https://github.com/OSCPU/ysyx/blob/master/wiki.src/about/procedure.rst) 和当期讲义为准。

## 3. 工程组成

```text
ysyx-workbench
├── NEMU               RISC-V 指令集模拟器，提供 sdb 调试、trace 与 difftest 参考模型
├── abstract-machine   AM 裸机运行时环境，承载测试程序、应用与 RT-Thread 移植
├── NPC                学员自行设计的 RTL 处理器，常用 Verilog/SystemVerilog/Chisel
└── 仿真与集成         Verilator 生成 C++ 仿真模型；ysyxSoC 提供总线、外设与存储控制器
```

官方工程入口为 [OSCPU/ysyx-workbench](https://github.com/OSCPU/ysyx-workbench)，通过 `bash init.sh subproject-name` 初始化子项目；SoC 环境为 [OSCPU/ysyxSoC](https://github.com/OSCPU/ysyxSoC)，当前默认分支 `ysyx6`，仓库包含 rocket-chip 子模块与 mill 构建文件。不同期次的讲义、分支和接口存在差异，复现时须固定期次与提交。

## 4. 与本仓库其他方向的关系

| 本仓库方向 | 相关的一生一芯能力 |
| --- | --- |
| DPU | 总线、设备 I/O、MMIO 与 SoC 外设集成 |
| GPU / GPUOperator | 性能计数、流水线与缓存优化、正确性优先的性能归因方法 |
| NPU | 自定义计算单元、tiling 与数据搬运的硬件视角 |
| Storage | 设备访问、异常处理与操作系统驱动基础 |

## 5. 复核路线

1. 按官方讲义独立完成对应阶段，再阅读公开成果的设计说明，不在完成前参考他人实现。
2. 先阅读架构图、模块划分和设计取舍，再对照官方讲义检查接口与测试覆盖。
3. 核对验证手段：是否接入 difftest、是否通过官方测试集、是否启动 RT-Thread、是否接入 ysyxSoC。
4. 核对性能数据口径：主频来源（综合报告或仿真假设）、IPC 统计窗口、缓存配置与测试程序。
5. 区分作者自述、截图证据和可复现日志；无法复现的结论保留为“未复现”。

具体条目与检查项见 [公开成果索引与检查记录](projects/README.md)。

## 6. 参考资料

资料核对日期：2026-11-06。

- [一生一芯官网](https://ysyx.oscc.cc/)
- [一生一芯 v26.07 课程主页](https://ysyx.oscc.cc/docs/)
- [OSCPU/ysyx：信息发布与内容网站源码](https://github.com/OSCPU/ysyx)
- [OSCPU/ysyx-workbench：工程项目框架](https://github.com/OSCPU/ysyx-workbench)
- [OSCPU/ysyxSoC：SoC 集成环境](https://github.com/OSCPU/ysyxSoC)
- [oscc-web/ysyx-docs-en：英文讲义](https://github.com/oscc-web/ysyx-docs-en)
