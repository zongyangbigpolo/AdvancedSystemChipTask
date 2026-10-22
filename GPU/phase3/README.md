# GPU Phase 3：单卡计算、访存与性能分析

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | GPU-P3-01 主机与设备传输矩阵 | 量化小传输、带宽及内存页锁定影响 | pageable/pinned、同步/异步拷贝、不同长度 | 一张 GPU、足量主机内存 | 将传输瓶颈与 kernel 计算瓶颈分开 |
| [ ] | GPU-P3-02 计算规模与精度对照 | 测量计算效率及数值误差 | GEMM，固定 M/N/K、FP32/FP16 等模式、核对参考结果 | 支持对应类型的 GPU | 数据类型或 Tensor Core 改变时必须同时报告精度条件 |
| [ ] | GPU-P3-03 stream 与 kernel 优化 | 理解并发、访存和同步开销 | 固定工作量比较 1/2/4 stream、合并访问与流水线 | 同上 | 一次改变一个变量，避免把数据量变化当优化收益 |
| [ ] | GPU-P3-04 裸机与 VM 性能对照 | 判断直通与 CPU/NUMA 配置影响 | 同一卡先裸机后直通，固定版本、功耗和输入 | 可直通 GPU | 同一设备时分复用，不用不同型号机器推断虚拟化开销 |

## 2. GPU-P3-01：传输测试

基础样例：

```bash
cd "$LAB/src/cuda-samples"
./Samples/1_Utilities/bandwidthTest/bandwidthTest \
  --memory=pinned --mode=range --start=128 --end=512 --increment=128
./Samples/1_Utilities/bandwidthTest/bandwidthTest \
  --memory=pinned --mode=range --start=1500 --end=1500 --increment=1
./Samples/1_Utilities/bandwidthTest/bandwidthTest \
  --memory=pinned --mode=range --start=1048576 --end=16777216 --increment=1048576
```

将 `--memory=pinned` 替换为 `pageable` 重跑。第一个命令会额外覆盖 384 B，必需分析点仍为 128/256/512 B；也可分别用单点区间运行。1500 B 仅用于对比 DPU 小消息任务，不代表 GPU 的最优批量；应同时覆盖 1 MiB、16 MiB、64 MiB 等较大传输。

异步拷贝和计算重叠需 pinned host memory、多个 CUDA stream、合适的设备 copy engine 能力，并明确同步边界。可构建固定 tag 的 `asyncAPI`、`simpleStreams` 样例了解 API，但样例输入不同，不能直接用两段样例耗时计算优化增益。

若需要严格对照，编写同一测试程序，通过参数控制：

```text
分配相同大小的 host/device buffer → 初始化相同输入 → 预热
同步组：H2D → kernel → D2H → 等待完成
流水组：将相同总数据拆成固定 chunk，用 1/2/4 stream 排程
等待所有 stream 完成 → 校验每个输出 → 输出时间与字节数
```

分配与首次上下文初始化放在计时区外，端到端耗时包含全部传输与同步。CUDA Events 用于设备时间，同步后的主机单调时钟用于端到端时间；不能只测异步 API 的返回时间。

## 3. GPU-P3-02：矩阵计算与正确性

选用 cuBLAS 或匹配版本的 cuBLASLt 示例，固定并记录：

| 变量 | 必需取值与约束 |
| --- | --- |
| 矩阵 | 正方形 M=N=K=256/1024/4096；可用显存不足时减小并记录 |
| 类型 | FP32 为基线；硬件支持时增加 FP16/BF16 输入和 FP32 累加 |
| 运算 | 固定 `C = alpha × A × B + beta × C`、layout、transpose、leading dimension、alpha/beta |
| 计算模式 | 明确 cuBLAS compute type、math mode、是否允许 TF32/Tensor Core，记录算法选择 |
| 重复 | 每格预热至少 10 次，正式至少 100 次；至少 3 轮 |
| 正确性 | 固定随机种子，与 CPU FP64 或明确的高精度参考比较，记录绝对/相对误差和容差 |

用相同程序修改参数做对照；CUDA `matrixMul` 可作入门，但不能把它与不同算法的 cuBLAS 结果直接归因为单个优化。吞吐按 `2MNK / 时间` 计算并注明 GFLOP/s 或 TFLOP/s；这是标准 GEMM 运算量约定，不是对任意 kernel 通用的 FLOP 计算方法。

输入缩小精度可能提高吞吐但增加误差，报告必须同时列数据类型、累加类型、容差和最大误差；不只写“精度一致”。

## 4. GPU-P3-03：分析方法

对同一可参数化程序保存带行号信息的构建，Release 测量不启用 `-G`。性能采样与正式结果分别运行：

```bash
nsys profile --trace=cuda,nvtx,osrt -o "$LAB/results/timeline" ./gpu_bench
ncu --set basic -o "$LAB/results/kernel" ./gpu_bench
compute-sanitizer --tool memcheck ./gpu_bench
```

`gpu_bench` 为待编写的统一基准程序占位名，不是仓库已有程序；在程序及正确性检查完成前不执行这些命令。Nsight Compute 指标权限按管理员策略授予，不全局放宽 profiling 权限。不同版本 profiler 支持范围需核对。

先从 Nsight Systems 检查 CPU 空洞、H2D/D2H、同步与 stream 重叠，再从 Nsight Compute 检查 memory throughput、SM 利用、occupancy、寄存器压力与访存合并。高 occupancy 不自动等于高性能；每个改动需要相同工作量的前后数据。

## 5. GPU-P3-04：裸机/VM 与报告

同一 GPU 先在裸机完成矩阵，再释放并直通到 VM 重跑。两边保持驱动/库兼容版本、输入、GPU 时钟策略、功率上限、温度区间和 CPU/NUMA 位置一致；不支持完全一致时列出差异。不要为固定条件擅自修改生产环境功率或锁频。

| 路径 | 负载/规模 | 类型/模式 | pinned/stream | kernel 时间 | 端到端时间 | 带宽或 FLOP/s | 最大误差 | 温度/功率/时钟 | 日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | — | — | — | — | — | — |

报告至少包含重复值、均值和标准差。若报告 P95/P99，需保留每次样本、说明分位数算法并提供足够样本；样例仅提供平均值时不能补写尾延迟。虚拟化耗时开销为 `(VM时间-裸机时间)/裸机时间×100%`；吞吐与延迟分别用各自定义，不能混用方向。
