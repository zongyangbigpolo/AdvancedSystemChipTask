# GPU Phase 1：GPU 架构与 CUDA 功能

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | GPU-P1-01 架构与使用场景调研 | 区分 CPU/GPU、SIMT、显存与互连 | 查型号手册、Compute Capability、拓扑和应用模型 | 一张 CUDA GPU | 按数据并行与传输成本分析适用性，不将所有程序都视为 GPU 加速对象 |
| [ ] | GPU-P1-02 驱动与 CUDA 环境建立 | 建立可复现的编译运行环境 | 匹配驱动/Toolkit，查询设备并编译样例 | Linux 主机、受支持 GPU | 固定版本并分开验证驱动、编译器、runtime |
| [ ] | GPU-P1-03 单卡正确性与带宽验证 | 检查设备可用、内存访问和计算结果 | deviceQuery、bandwidthTest、vectorAdd、Compute Sanitizer | 同上 | 先验证正确性，再开展性能测试 |
| [ ] | GPU-P1-04 内存与同步错误定位 | 建立可复现的 CUDA 调试能力 | 构造四类最小错误，用 Sanitizer 定位并修复 | 单张 CUDA GPU | 错误注入、根因与修复均可审查，不只运行无错误样例 |
| [ ] | GPU-P1-05 转置 kernel 访存优化 | 理解合并访问与 shared memory bank conflict | transpose 样例、自己实现尾块、Nsight Compute 对照 | 单张 CUDA GPU | 用源码改动与硬件指标解释带宽变化 |

## 2. GPU-P1-01：架构与场景

| 概念 | 内容及实验含义 |
| --- | --- |
| CPU 与 GPU | CPU 擅长复杂控制和低延迟串行任务；GPU 通过大量并行执行单元处理数据并行任务，收益依赖并行度和数据复用 |
| SM、warp、thread block | CUDA 线程映射到流式多处理器执行；warp 大小按 NVIDIA 架构查询，常见为 32，分支分歧影响执行效率 |
| 显存、cache、shared memory | 容量、带宽和访问延迟不同；shared memory 由 block 内线程协作使用，不是主机内存 |
| PCIe、NVLink、NVSwitch | CPU↔GPU、GPU↔GPU 的互连；有多卡不代表有 NVLink，也不代表所有 GPU 对支持 P2P |
| Tensor Core | 用于支持的矩阵运算与数据类型；数值精度、累加方式和算法均影响性能与误差 |
| 适用场景 | 矩阵计算、图像处理、科学计算和模型训练/推理；小任务或频繁主机传输可能受调度与拷贝限制 |

## 3. GPU-P1-02：环境建立

驱动与 CUDA 从发行版或 NVIDIA 对应安装指南选择一条安装路径，避免混用 runfile、发行版包和容器宿主驱动。安装前核对 Secure Boot 模块签名、内核 headers、兼容表并安排重启；不通过关闭安全机制解决安装问题。

```bash
lspci -nnk
nvidia-smi
nvidia-smi -L
nvidia-smi topo -m
nvcc --version
```

通过 `nvidia-smi -q` 保存 ECC、时钟、温度、功率和 MIG 状态。设备缺失时先检查 PCIe 枚举、驱动、签名与内核日志，不能继续解释性能数据。

固定 CUDA Samples 版本。以下以具有 Makefile 的 `v12.4` tag 为例：

```bash
sudo apt-get update
sudo apt-get install build-essential git numactl pciutils
cd "$LAB/src"
git clone https://github.com/NVIDIA/cuda-samples.git
cd cuda-samples
git checkout v12.4
make -C Samples/1_Utilities/deviceQuery -j"$(nproc)"
make -C Samples/1_Utilities/bandwidthTest -j"$(nproc)"
make -C Samples/0_Introduction/vectorAdd -j"$(nproc)"
```

若改选使用 CMake 的新版本，按该 tag 的构建说明操作，并记录配置、目标架构和二进制路径。不能对旧 Toolkit 强行编译不支持的 GPU 架构。

## 4. GPU-P1-03：功能和内存检查

```bash
cd "$LAB/src/cuda-samples"
./Samples/1_Utilities/deviceQuery/deviceQuery
./Samples/1_Utilities/bandwidthTest/bandwidthTest --memory=pinned
./Samples/1_Utilities/bandwidthTest/bandwidthTest --memory=pageable
./Samples/0_Introduction/vectorAdd/vectorAdd
compute-sanitizer --tool memcheck ./Samples/0_Introduction/vectorAdd/vectorAdd
```

判定标准为设备查询符合实物、样例结果检查通过、memcheck 无非法访问。记录 Host-to-Device、Device-to-Host 与 Device-to-Device 带宽，不将 PCIe 带宽误写为显存带宽。sanitizer 会扰动运行时间，检查结果与性能结果分别保存。

阶段产物：硬件/拓扑记录、版本清单、编译命令、功能结果、错误日志。性能数值仅在实际执行后填写。

## 5. GPU-P1-04：四类错误的定位、修复与回归

依据 [Compute Sanitizer 官方说明](https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html)，在 `$LAB/src/sanitizer_lab.cu` 编写最小实验程序，使用命令行选择以下模式。该文件是需完成的实验作业，不是仓库已有的可执行程序。

| 模式 | 构造方法 | 使用工具 | 修复与回归要求 |
| --- | --- | --- | --- |
| 越界 | 分配 N 个元素却允许线程写入索引 N | memcheck | 正确限制 `idx < N`，用 N=1/31/32/33/1025 回归 |
| 未初始化读取 | 设备输入分配后未写入便参与计算 | initcheck | 初始化所有实际读取区间，并核对数值 |
| shared memory 数据竞争 | 同一 block 内跨 warp 读写共享数组，缺少依赖同步 | racecheck | 明确生产者/消费者关系，在需要处加入合法同步，不靠延时掩盖 |
| 非法同步 | 非全体线程满足的分支调用 block barrier | synccheck | 让所需线程一致参与同步，或按正确的作用域重新组织算法 |

四个模式分别使用独立进程运行，避免前一个 CUDA 错误污染后一个上下文。检查 CUDA API、kernel launch 和同步返回值，使用有限运行时长，不在其他作业中注入错误。先通过 memcheck 排除越界，再分析其他工具结果；racecheck 主要检查 shared memory hazard，不能声称覆盖任意跨 block/global memory 竞争。

```bash
nvcc -O2 -lineinfo "$LAB/src/sanitizer_lab.cu" -o "$LAB/build/sanitizer_lab"
compute-sanitizer --tool memcheck --error-exitcode 99 "$LAB/build/sanitizer_lab" oob
compute-sanitizer --tool initcheck --error-exitcode 99 "$LAB/build/sanitizer_lab" uninit
compute-sanitizer --tool racecheck --error-exitcode 99 "$LAB/build/sanitizer_lab" race
compute-sanitizer --tool synccheck --error-exitcode 99 "$LAB/build/sanitizer_lab" sync
```

故障版本应产生目标诊断及非零返回，修复版本应通过对应工具和 CPU 数值参考。给每个运行设置实验调度器或 shell 的超时上限，超时记录为失败而不是“没有报错”。工具不能稳定复现时记录实际覆盖限制，不能仅因一次无报警而宣布竞争已消除。

交付四个最小复现、故障日志及返回码、错误行号、修复 diff、边界测试和修复后日志。正式性能计时不使用 sanitizer 或 `-G`。

## 6. GPU-P1-05：从朴素转置到分块转置

在 Phase 1 固定的 CUDA Samples `v12.4` 中：

```bash
cd "$LAB/src/cuda-samples"
make -C Samples/6_Performance/transpose -j"$(nproc)"
./Samples/6_Performance/transpose/transpose
ncu --list-sections
ncu --section MemoryWorkloadAnalysis --section SpeedOfLight \
  -o "$LAB/results/transpose-baseline" \
  ./Samples/6_Performance/transpose/transpose
```

先阅读 [官方 transpose 样例及说明](https://github.com/NVIDIA/cuda-samples/tree/v12.4/Samples/6_Performance/transpose)，分别解释朴素访问、分块共享内存、padding 避免 bank conflict 的地址映射，不只复制样例输出。

在自己的实验源码中实现三种版本：朴素转置、分块转置、带 padding 的分块转置。增加非方阵和非 tile 整倍数：`1024×1024`、`4096×4096`、`1023×1001`；host 分配、grid、边界判断及 shared memory 索引都需匹配。官方样例有自身形状假设，不能只改尺寸常量就认为完成尾块支持。

逐元素与 CPU 转置结果比较，再用 memcheck、racecheck 检查新代码。至少预热 10 次、测量 100 次、重复三轮；逻辑有效带宽为 `2 × 行 × 列 × sizeof(dtype) / 时间`，不是 PCIe 带宽。结合有效全局访存、shared memory 冲突与实际硬件指标解释变化；指标名称依 GPU 和 Nsight 版本查询，不支持的指标不填估计值。

交付自写 kernel、索引示意、边界测试、逐次时间、`.ncu-rep` 和对照表。缺少尾块正确性、只有一次加速数字或只贴利用率截图，不满足本任务要求。
