# 一生一芯（YSYX）带实验大作业

RISC-V 处理器设计方向的分阶段实验作业。每个阶段有明确任务与验收，可在本机运行的阶段附实验命令、结果与截图；受工具或硬件限制的阶段注明“未执行”，只给方法。

- 共享源码：[`lab/`](lab)（RTL、测试平台、汇编器与参考模型、脚本）
- 同类公开作业对比与检查：[`projects/README.md`](projects/README.md)

| 阶段 | 任务 | 本机执行 | 实验记录 |
| --- | --- | --- | --- |
| [Phase 1](phase1/README.md) | ALU 设计与定向/随机验证 | 是 | 10.1 万向量，0 失配 |
| [Phase 2](phase2/README.md) | 单周期 RV32E 核与参考模型 difftest | 是 | 8 程序 × 2 仿真器逐指令一致 |
| [Phase 3](phase3/README.md) | 边界/约束随机与故障注入 | 是 | 注入缺陷 3/3 被捕获，并复现一处真实 bug |
| [Phase 4](phase4/README.md) | 指令构成、CPI 与分支命中统计 | 是 | 7 程序性能画像 |
| [Phase 5](phase5/README.md) | ysyxSoC / RT-Thread / Linux / 综合 / 流片 | 否 | 未执行，仅方法与原因 |

## 环境

macOS 27.0、Apple Silicon（arm64）、10 核、16 GiB。工具：Icarus Verilog 13.0、Verilator 5.054、Python 3.14（均由 Homebrew 安装）。未使用 FPGA、交叉工具链、商用 EDA 或工艺库。

## 复现

```bash
cd lab
./run_alu.sh     # Phase 1
./run_core.sh    # Phase 2 + 3
./run_perf.sh    # Phase 4（需先跑 run_core.sh）
```

## 说明

- `lab/` 下的 RTL、测试平台、汇编器与参考模型均自行编写，未复制公开仓库代码。
- 截图为真实运行日志渲染后的终端样式页面，非系统窗口直接截屏；原始日志在各 `lab/results/*.log`。
- Phase 5 涉及的 SoC、RTOS、Linux、综合与流片在本机不具备条件，保留为未执行，不编造结果。
