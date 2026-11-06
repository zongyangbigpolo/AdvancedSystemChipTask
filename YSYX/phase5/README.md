# YSYX Phase 5：ysyxSoC / RT-Thread / Linux / 综合 / 流片（未执行）

[作业索引](../README.md) · [源码 lab/](../lab)

本阶段内容在本机不具备条件，**未执行**：ysyxSoC 依赖 JVM/mill 与大磁盘、RTOS 与 Linux 需要交叉工具链与完整 SoC、综合与流片需要工艺库与后端 EDA。以下只记录方法、环境、产物与判定，不含本机结果，也不编造数据。原因见 [作业索引](../README.md) 环境一节。

## 1. 接入 ysyxSoC

- 环境：Linux、JDK、mill/sbt、Verilator、`riscv64-unknown-elf-gcc`。
- 过程：克隆 [OSCPU/ysyxSoC](https://github.com/OSCPU/ysyxSoC) 并初始化子模块；把核内部存储接口改为 AXI4 主端口并按握手插入等待状态；mill 生成 SoC Verilog；加载 bootrom 与 AM 程序，先跑最小程序再跑外设程序。
- 产物/判定：AXI 适配核、SoC 仿真、UART 日志、difftest 轨迹；插入等待状态后仍逐指令匹配参考模型，UART 打印预期字符串。
- 本机限制：mill/rocket-chip 依赖重、磁盘占用大，macOS 需额外适配，建议 Linux 容器或服务器。

## 2. 运行 RT-Thread

- 前置：核需先实现 CSR（`mtvec/mepc/mcause/mstatus`）、`mret/ecall`、定时器与外部中断——当前核尚未实现。
- 过程：配置 BSP（内存布局、时钟、UART、定时器周期）；交叉编译 RT-Thread 为镜像；仿真启动，经 UART 进入 `msh` 并运行线程/信号量/定时器示例。
- 判定：进入 `msh`、定时器周期正确、多线程切换无数据损坏。

## 3. 启动 Linux

- 两条路线：NEMU 上启动（软件模拟器，复用公开笔记成本低，但验证的是模拟器，见公开成果 Y-08）；RTL 上启动（需 A 扩展、S 模式、MMU、完整中断，仿真时间长）。
- 过程（RTL 主线）：扩展 ISA 与特权、页表/TLB、`sfence.vma`；交叉编译 OpenSBI + Kernel + initramfs 与设备树；bootrom→OpenSBI→Kernel→用户态；先用 NEMU 跑通整条栈再迁移 RTL 做长序列 difftest。
- 判定：内核初始化并进入 shell，分页/中断/串口正常，与 NEMU 轨迹一致。

## 4. 逻辑综合

- 环境：Yosys（开源）或商用综合工具、标准单元库、SDC 约束。
- 过程：去除仿真结构（`$readmemh/$display`、延时），存储改用 SRAM 宏或寄存器阵列；读库与约束设定时钟目标；综合后检查建立/保持违例、面积、功耗；针对关键路径调整微架构（如分支计算从 ID 移到 EX）；必要时做形式等价检查。
- 判定：目标周期下无违例、面积在预算内、关键路径可解释。
- 本机限制：商用工具/工艺库受许可约束；开源可用 Yosys + Sky130，但本作业尚未提供可综合的 SRAM 替换。

## 5. 物理设计与流片

- 环境：OpenROAD/OpenLANE 或商用后端、工艺 PDK、DRC/LVS 工具。
- 过程：floorplan→布局→CTS→布线→寄生提取与签核 STA→DRC/LVS→生成 GDSII，随 MPW 交付制造，回片后测功能与频率。
- 判定：时序签核通过、DRC/LVS 无违例、满足工艺与 MPW 规范。
- 本机限制：需 PDK、后端工具与制造流程，均不在本机范围。

## 落地顺序建议

1. 先在当前核补齐 CSR、异常与中断，用定向测试与 difftest 覆盖（RTOS/Linux 的前置）。
2. 用 Linux 容器隔离交叉工具链与 mill，避免污染本机。
3. 接入 SoC/RTOS/Linux 后仍以参考模型为准，只是比较的状态集合需扩展到 CSR 与内存。
4. 综合先用开源工具拿量级，再评估是否进入后端与流片。
