# 一生一芯未执行项的过程说明（ysyxSoC / RT-Thread / Linux / 综合 / 流片）

[一生一芯栏目](../README.md) · [个人作业](README.md) · [名词与缩写](../../glossary/README.md)

[个人作业](README.md) 在本机完成了 RV32E 处理器与 difftest。本文说明**本机未执行**的四类内容的标准流程、所需环境、关键产物与判定标准，供在具备条件的 Linux 环境中落地。未执行原因见个人作业第 3 节：这些内容以 Linux 工具链为主、依赖较重，且需要交叉编译器、SoC 框架乃至工艺库与后端 EDA 工具。以下为方法与过程，不含本机运行结果。

## 1. 接入 ysyxSoC

**目的：**把自写处理器核放进带总线与外设的 SoC 环境，验证其在真实访存时序与外设交互下仍然正确。

**环境：**Linux；JDK、mill/sbt（ysyxSoC 基于 Chisel 与 rocket-chip 子模块）；Verilator；RISC-V 交叉编译器 `riscv64-unknown-elf-gcc`（编译 bootrom 与测试程序）。

**过程：**

1. 获取框架：`git clone https://github.com/OSCPU/ysyxSoC`，`git submodule update --init --recursive`（含 rocket-chip）。固定一个期次分支（如 `ysyx6`），记录提交哈希。
2. 阅读 SoC 顶层接口：处理器核对外是 AXI4/AXI4-Lite 主端口，连接到交叉开关，再挂载 SRAM、UART、SPI Flash、GPIO 等外设的地址空间。
3. 适配接口：将本作业核的内部存储接口替换为标准 AXI 主端口，包含读写地址、数据、握手与响应通道；现有单周期核每周期一次访存，需要按握手协议插入等待状态。
4. 生成 SoC Verilog：用 mill 调用 Chisel 生成 `ysyxSoC.v`，与自写核一起交给 Verilator 构建仿真。
5. 运行：加载 bootrom 与 AM 程序，先跑 `char-test`、`hello` 等最小程序，再跑访存密集与外设程序（UART 输出）。
6. 验证：继续用参考模型做 difftest，但要在存在外设 MMIO、访存延迟和中断时对齐“可比较的提交点”；外设读写属于不可重复的副作用，需在参考模型中按设备模型处理或跳过比较。

**关键产物：**AXI 适配后的核、SoC 仿真可执行文件、bootrom、UART 输出日志、difftest 轨迹。
**判定标准：**在插入访存等待状态后仍逐指令匹配参考模型；UART 能打印预期字符串；访存越界/非对齐按设计产生明确响应。
**本机限制：**mill/rocket-chip 依赖 JVM 与较大磁盘空间，构建耗时长；macOS 需额外适配，建议在 Linux 服务器或容器执行。

## 2. 运行 RT-Thread

**目的：**以一个真实 RTOS 作为系统级负载，验证处理器加 SoC 能支撑多任务调度、中断与设备驱动——这是官方 B 阶段的考核目标之一。

**环境：**在 §1 的 SoC 之上，增加定时器中断、UART 驱动所需的 CLINT/PLIC 或等效中断源；RISC-V 交叉工具链；RT-Thread 源码及其 ysyx/RISC-V 的 BSP 配置。

**过程：**

1. 确认处理器已实现 RT-Thread 所需的特权与机制：至少机器模式、`mtvec`/`mepc`/`mcause`/`mstatus` 等 CSR、`mret`、定时器中断与外部中断、`ecall`。本作业当前核未实现 CSR 与异常，需先补齐。
2. 配置 BSP：设置内存布局、时钟频率、UART 寄存器地址、定时器中断周期，与 SoC 的实际地址一致。
3. 交叉编译 RT-Thread 得到 ELF，转为 SoC 可加载的镜像（bootrom 跳转或直接加载到 SRAM）。
4. 在 Verilator 仿真中启动，通过 UART 观察启动信息与 `msh` 命令行；运行线程、信号量、定时器等示例。
5. 排错以 difftest 轨迹和 UART 日志结合为主：启动卡住通常源于中断未触发、CSR 行为错误或访存映射不符。

**关键产物：**补齐 CSR/异常/中断后的核、RT-Thread 镜像、启动与 shell 的 UART 日志。
**判定标准：**成功进入 `msh` 并能执行命令、定时器中断周期正确、多线程切换无数据损坏。
**本机限制：**依赖完整 SoC、交叉工具链与中断子系统，无法在当前 macOS 直接完成。

## 3. 启动 Linux

**目的：**验证处理器具备运行通用操作系统内核的能力（官方 A 阶段方向，对应公开成果 Y-08）。

**两条常见路线：**

- **NEMU 上启动（软件模拟器）：**配置 `rv32ima_zicsr_zifencei` 或 RV64 的 NEMU，提供 CLINT/PLIC、串口与必要设备，搭配 OpenSBI 加载 Linux Kernel 与根文件系统。这是复用公开笔记成本最低的路线，但验证的是模拟器而非 RTL。
- **RTL 上启动（处理器核）：**要求核实现 A（原子）、必要的 Zicsr/Zifencei、监管者模式、`satp` 与 MMU（Sv32/Sv39）、完整中断，并接入足够内存的 SoC。难度与仿真时间都远高于 RT-Thread。

**过程（以 RTL 路线为主干）：**

1. 扩展 ISA 与特权：原子扩展、S 模式、页表与 TLB、时钟与外部中断、`sfence.vma`。
2. 准备软件栈：交叉编译 OpenSBI（M 模式固件）、Linux Kernel 与 BusyBox/initramfs，生成设备树描述内存、CPU、CLINT/PLIC 与串口。
3. 在仿真中按 bootrom → OpenSBI → Kernel → 用户空间的顺序启动，通过串口观察日志。
4. 由于仿真慢，先用 NEMU 跑通整条软件栈并作为参考模型，再迁移到 RTL 并做长序列 difftest。

**关键产物：**支持 S 模式与 MMU 的核、OpenSBI/Kernel/initramfs、设备树、串口启动日志到 shell。
**判定标准：**内核完成初始化并进入用户态 shell；分页、中断与串口正常；与 NEMU 参考轨迹一致。
**本机限制：**需要完整工具链、OpenSBI/内核构建和长时间仿真，不在当前 macOS 范围内。

## 4. 逻辑综合

**目的：**把 RTL 映射到标准单元库，得到门级网表与时序、面积、功耗估计，这是流片前的必经步骤（官方 D/B 阶段涉及）。

**环境：**综合工具（商用如 Design Compiler/Genus，或开源 Yosys）；目标工艺的标准单元库（`.lib` 时序模型、`.lef`/Liberty）；时序约束 SDC（时钟周期、输入输出延迟）。

**过程：**

1. 准备可综合 RTL：移除仿真专用结构（`$readmemh`、`$display`、延时），存储改用工艺提供的 SRAM 宏或寄存器阵列。
2. 读入单元库与约束，设定时钟周期目标与多角落（corner）条件。
3. 综合并检查：关键路径（setup/hold）、违例路径、面积与单元数、功耗估计。
4. 迭代优化：针对关键路径调整微架构（如将分支计算从 ID 移至 EX，见公开成果 Y-03 的取舍）、插入寄存器或改写组合逻辑。
5. 形式等价检查（如有）：综合前后 RTL 与网表的逻辑等价（LEC）。

**关键产物：**门级网表、时序报告、面积/功耗报告、约束文件。
**判定标准：**在目标周期下无建立/保持违例、面积在预算内、关键路径可解释。
**本机限制：**商用工具与工艺库受许可与保密约束；开源 Yosys 可做实验性综合，但需要公开工艺库（如 Sky130）与配套流程，且本作业尚未提供可综合的 SRAM 替换。

## 5. 物理设计与流片

**目的：**把网表做成可制造的版图并交付制造（tape-out）。官方要求参与流片的芯片对外开源。

**环境：**后端 EDA（布局布线，如 Innovus/ICC2 或开源 OpenROAD/OpenLANE）；工艺 PDK；DRC/LVS 检查工具与规则。

**过程（概述）：**

1. 布图规划（floorplan）：确定面积、电源网络、IO 与宏单元位置。
2. 布局、时钟树综合（CTS）、布线。
3. 寄生参数提取与签核时序分析（STA），功耗与 IR drop 分析。
4. 物理验证：DRC（设计规则）、LVS（版图与网表一致）、天线等规则。
5. 生成 GDSII，随 MPW（多项目晶圆）流程交付制造；回片后做功能与频率测试。

**关键产物：**版图 GDSII、签核时序/功耗报告、DRC/LVS 清洁报告。
**判定标准：**时序签核通过、DRC/LVS 无违例、满足工艺与 MPW 的提交规范。
**本机限制：**需要 PDK、后端工具与制造流程，均不在个人本机范围；本文仅说明流程，不产出版图或流片结果。

## 6. 落地建议

1. **先补齐特权与异常**：CSR、`mret`/`ecall`、定时器与外部中断是 RT-Thread 与 Linux 的前置条件，应在当前核上先实现并用定向测试与 difftest 覆盖。
2. **用容器隔离 Linux 工具链**：本机已安装 Docker，可在 Linux 容器内安装 RISC-V GCC、mill 与 ysyxSoC，避免污染本机并规避 macOS 适配问题；注意镜像与构建占用磁盘。
3. **始终以参考模型为准**：接入 SoC、RTOS 与 Linux 后，difftest 仍是定位错误的主要手段，只是比较点与状态集合（寄存器、CSR、内存）需要相应扩展。
4. **综合与流片分级推进**：先用开源 Yosys + 公开工艺库做实验性综合拿到时序/面积量级，再评估是否进入后端与 MPW 流程。
