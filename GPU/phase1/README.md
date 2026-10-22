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
