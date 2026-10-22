# GPU 方向第一阶段：计算、虚拟化与跨节点通信

## 1. 范围与实验约定

五天分别作为 Phase 1.1 至 Phase 1.5，按照“单卡功能→虚拟化→单卡性能→同机多卡→跨节点通信”的顺序组织。每个任务均列出名称、目的、方法、硬件、方案及选择原因。

本阶段以 NVIDIA CUDA 生态为命令示例。AMD ROCm、Intel oneAPI 可作为不同实验路线，但必须重新核对硬件和 API，不能将 CUDA 命令直接用于其他厂商设备。GPU 计算加速、GPU 虚拟化、RDMA 网络和 DPU 流表卸载属于不同能力，不相互替代。

**执行边界：**本文件仅提供操作过程、测试矩阵与判定标准，不包含硬件执行结果。缺少 GPU、第二张卡、第二个节点、NVLink、支持 MIG/vGPU 的型号或 RDMA 网络时，相关项目保留“待执行”或“受硬件限制未执行”。不以 CPU、单卡或普通 TCP 结果替代对应硬件结果。

### 1.1 硬件与软件基线

| 项目 | 基线与用途 | 选择依据 |
| --- | --- | --- |
| 主机 | 两台 x86_64 Linux 服务器；建议每台至少 16 核、64 GiB 内存；直通需要 VT-d/AMD-Vi | 分离 GPU、MPI、网卡、监控与 VM 资源 |
| GPU | 单卡任务至少一张 CUDA 支持的 GPU；多卡任务至少同机两张；跨节点每节点至少一张 | 资源不足时按任务边界停止，不混淆单卡与多卡 |
| 型号示例 | A100/H100 等数据中心型号，或驱动/CUDA 兼容的实验 GPU | NVLink、MIG、vGPU、P2P、GPUDirect 支持须逐型号和拓扑核对；消费卡不默认支持这些能力 |
| 网络 | 管理网独立；第五天可先测 Ethernet Socket，再选支持 RDMA 的 ConnectX 网卡和网络 | 先建立 TCP 基线，再判断 RDMA 收益 |
| 系统与工具链 | Ubuntu 22.04 LTS 示例；一组固定 NVIDIA 驱动、CUDA、cuBLAS、NCCL、MPI、Nsight 版本 | 按兼容表选择；不能只写“最新版” |
| 供电与散热 | 机箱、供电、风道和插槽满足具体 GPU 要求 | 温度、功耗和降频直接影响性能与稳定性 |
| 存储 | 独立 VM 镜像与原始日志空间 | 防止镜像并发写入及结果覆盖 |

参考软件组合可选择 CUDA 12.4 及满足其最低要求的驱动，再固定兼容的 NCCL、CUDA Samples tag 和 nccl-tests commit。实际版本以产品支持、发行版及维护状态为准。禁止在仍承载桌面显示或业务计算的 GPU 上直接解绑、切换 MIG 或重装驱动。

### 1.2 统一记录

记录主机 CPU、NUMA、GPU 型号/UUID、显存、PCIe 代际/宽度、拓扑、驱动、CUDA runtime/toolkit、ECC、MIG、功率限制、时钟、温度、软件 commit、输入规模、数据类型、随机种子及命令返回码。`nvidia-smi` 显示的 CUDA Version 是驱动支持上限，不代表已安装相应 CUDA Toolkit；后者用 `nvcc --version` 核对。

命令中设备编号、网络接口、路径与 BDF 均须按实机替换。在各节点相同位置建立工作目录：

```bash
export LAB=$HOME/gpu-lab
export CUDA_HOME=/usr/local/cuda
export PATH="$CUDA_HOME/bin:$PATH"
mkdir -p "$LAB"/{src,build,images,results}
```

示例中 `CUDA_VISIBLE_DEVICES=0,1` 是可见设备选择，不是权限隔离；容器也不是完整的 GPU 硬件隔离方案。

## 2. Phase 1.1 / 第一天：GPU 架构与 CUDA 功能

### 2.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | G1-01 架构与使用场景调研 | 区分 CPU/GPU、SIMT、显存与互连 | 查型号手册、Compute Capability、拓扑和应用模型 | 一张 CUDA GPU | 按数据并行与传输成本分析适用性，不将所有程序都视为 GPU 加速对象 |
| [ ] | G1-02 驱动与 CUDA 环境建立 | 建立可复现的编译运行环境 | 匹配驱动/Toolkit，查询设备并编译样例 | Linux 主机、受支持 GPU | 固定版本并分开验证驱动、编译器、runtime |
| [ ] | G1-03 单卡正确性与带宽验证 | 检查设备可用、内存访问和计算结果 | deviceQuery、bandwidthTest、vectorAdd、Compute Sanitizer | 同上 | 先验证正确性，再开展性能测试 |

### 2.2 G1-01：架构与场景

| 概念 | 内容及实验含义 |
| --- | --- |
| CPU 与 GPU | CPU 擅长复杂控制和低延迟串行任务；GPU 通过大量并行执行单元处理数据并行任务，收益依赖并行度和数据复用 |
| SM、warp、thread block | CUDA 线程映射到流式多处理器执行；warp 大小按 NVIDIA 架构查询，常见为 32，分支分歧影响执行效率 |
| 显存、cache、shared memory | 容量、带宽和访问延迟不同；shared memory 由 block 内线程协作使用，不是主机内存 |
| PCIe、NVLink、NVSwitch | CPU↔GPU、GPU↔GPU 的互连；有多卡不代表有 NVLink，也不代表所有 GPU 对支持 P2P |
| Tensor Core | 用于支持的矩阵运算与数据类型；数值精度、累加方式和算法均影响性能与误差 |
| 适用场景 | 矩阵计算、图像处理、科学计算和模型训练/推理；小任务或频繁主机传输可能受调度与拷贝限制 |

### 2.3 G1-02：环境建立

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

### 2.4 G1-03：功能和内存检查

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

## 3. Phase 1.2 / 第二天：GPU 虚拟化与镜像

### 3.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | G2-01 GPU 共享与虚拟化比较 | 区分独占、分区、时间共享和容器 | 对比 PCIe passthrough、vGPU、MIG、MPS、容器 | GPU；部分路线需特定型号与许可 | 按隔离和可调度资源选择，不把不同机制混称 SR-IOV |
| [ ] | G2-02 QEMU-KVM GPU 直通 | 在 VM 内运行真实 GPU 计算 | IOMMU、vfio-pci、QEMU/OVMF、客户机驱动 | 独立 IOMMU 组的 GPU；管理不依赖该卡 | 整卡独占直通路径清晰，适合作为虚拟化开销基线 |
| [ ] | G2-03 制作 GPU 工具镜像 | 固定客户机软件和测试程序 | 安装驱动、CUDA、样例、NCCL 工具，关机封装 | VM、镜像存储 | 避免不同 VM 的工具版本差异影响结果 |
| [ ] | G2-04 VM 计算与双 VM 通信 | 验证直通功能和后续通信基础 | VM 内运行样例；独立虚拟网卡双向 ping；可选两 VM NCCL | 两 VM；同时各用 GPU 需两张独立 GPU | 一张整卡不能同时直通两 VM；网络互通与 GPU 可用分别验证 |

### 3.2 G2-01：方案比较

| 方案 | 目的与优点 | 硬件/软件要求 | 限制及选择原因 |
| --- | --- | --- | --- |
| 整卡 PCIe 直通 | VM 独占真实设备，设备路径直接 | IOMMU、VFIO、适合直通的 GPU/固件和复位能力 | 一张卡只能由一个持有者使用，迁移和共享受限；本阶段主线 |
| 厂商 vGPU | 多 VM 共享，按 profile 分配资源 | 支持型号、Hypervisor、vGPU 软件和相应许可 | 不可按普通桌面驱动推导支持；具体实现不一定采用 SR-IOV |
| MIG | 支持型号上将 GPU 分割为不同计算/显存实例 | 型号、驱动、profile 支持 | 分区能力与组合有上限；MIG 不是自动将每个实例变成通用可直通 PCI VF |
| MPS | 多 CUDA 进程协作共享执行资源 | CUDA MPS 支持的设备和系统 | 不提供与独立 VM 等价的安全边界，不能代替设备隔离 |
| 容器 | 固定用户态工具与库，部署方便 | 宿主驱动、NVIDIA Container Toolkit、兼容 runtime | 共用宿主内核与 GPU 驱动；容器数量不等于硬件隔离实例数量 |

MIG、vGPU 和 MPS 为条件任务：只有型号与软件支持时才执行对应配置。变更 MIG 前停止所有 GPU 使用者，按型号文档评估复位/重启要求并记录原 profile；不在占用中的设备上试探模式切换。

### 3.3 G2-02：整卡直通步骤

先使用普通 virtio 磁盘与网络安装可从串口管理的 Linux VM。QEMU 镜像安装、独立写入层和 TAP 网络可参照 [DPU 第二天](../../DPU/phase1/README.md#3-phase-12--第二天虚拟化与虚拟机镜像)，GPU 实验使用独立镜像与网桥，不复用正在运行的磁盘。

在宿主机 BIOS 和 Linux 启动参数中启用 IOMMU，重启后核对 DMAR/IOMMU 日志。按实际地址设置：

```bash
export GPU_BDF=0000:81:00.0
lspci -nnk -s "$GPU_BDF"
readlink -f "/sys/bus/pci/devices/$GPU_BDF/iommu_group"
```

列出实际 IOMMU 组内全部设备。GPU 可能带音频、USB 或其他 PCI 功能；需确认可交付的完整组及复位要求，不能只绑定显示功能后忽略其他成员。组内含不可释放设备时停止本项，不使用 ACS override 或关闭 IOMMU 隔离。

确认该 GPU 不承担显示、没有 CUDA 进程、没有被其他 VM 使用；保留带外管理。每个待直通功能按精确 BDF 操作，以下只展示一个当前由 `nvidia` 驱动管理的计算功能：

```bash
sudo modprobe vfio-pci
echo vfio-pci | sudo tee "/sys/bus/pci/devices/$GPU_BDF/driver_override"
echo "$GPU_BDF" | sudo tee /sys/bus/pci/drivers/nvidia/unbind
echo "$GPU_BDF" | sudo tee /sys/bus/pci/drivers_probe
lspci -nnk -s "$GPU_BDF"
```

其他功能应按其实际驱动逐一处理，不向错误的 driver/unbind 写 BDF。若无法安全释放驱动，采用经审核的按 BDF 开机绑定方案；不要全局卸载所有 GPU 的驱动。

使用 Q35、KVM、UEFI 启动。OVMF 固件路径按发行版实际安装核对；每个 VM 使用私有且格式匹配的 VARS 副本：

```bash
sudo apt-get install qemu-system-x86 qemu-utils ovmf
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$LAB/images/gpu-a-vars.fd"
sudo qemu-system-x86_64 -name gpu-a -enable-kvm -machine q35 -cpu host \
  -smp 4 -m 8192 -nographic \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$LAB/images/gpu-a-vars.fd" \
  -drive file="$LAB/images/gpu-a.qcow2",format=qcow2,if=virtio \
  -device vfio-pci,host="$GPU_BDF" \
  -netdev tap,id=net0,ifname=gpu-tap-a,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=02:00:00:00:10:01
```

前置条件为镜像已按 UEFI 安装、串口已配置、`gpu-tap-a` 已创建并加入专用 OVS 或 Linux 桥。多功能设备需按已核对的 PCI 拓扑增加全部必需的 `vfio-pci` 参数。

大 BAR GPU 可能需要 Above 4G Decoding、足够的 64 位 MMIO 空间及额外 QEMU/固件设置；VM 枚举失败时按具体 GPU 的虚拟化指南处理，不复制未经验证的 BAR 或 ROM 参数。

### 3.4 G2-03/04：镜像与验证

客户机内安装与目标 GPU、CUDA 匹配的驱动和工具链，重复第一天的 `nvidia-smi`、`deviceQuery`、`vectorAdd`、memcheck。直通模式下客户机运行真实 GPU 驱动；宿主机该卡使用 vfio-pci，不要求同时在宿主 `nvidia-smi` 中可见。

镜像内加入固定版本 CUDA Samples、NCCL、MPI、nccl-tests、Nsight 工具；构建方法分别见第四/五天。保留源码 commit 与构建参数。清理临时凭据，按发行版通用化流程为每台 VM 生成独立 machine-id、SSH host key，关机后记录镜像散列及 `qemu-img check`。

若使用 backing file，每台 VM 创建自己的写入层，交付时导出独立 qcow2 或完整登记依赖链。镜像不包含固定 SSH 私钥，不提交到 Git；登记存储路径、散列、GPU 架构和版本清单。

第二台 VM 使用独立镜像、VARS 文件、TAP、MAC、名称及 GPU BDF。在两个客户机为数据网配置 `192.0.2.21/24`、`192.0.2.22/24`，双向 ping。使用两张 GPU 时可运行第四天的 MPI NCCL 测试，每台 VM 一张卡；只有一张卡时两 VM 网络互通仍可单独验证，但双 VM GPU 通信标为未执行。

阶段产物：共享方案对照、IOMMU 组及设备归属、启动参数、镜像清单、VM 功能检查与网络互通日志。

## 4. Phase 1.3 / 第三天：单卡计算、访存与性能分析

### 4.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | G3-01 主机与设备传输矩阵 | 量化小传输、带宽及内存页锁定影响 | pageable/pinned、同步/异步拷贝、不同长度 | 一张 GPU、足量主机内存 | 将传输瓶颈与 kernel 计算瓶颈分开 |
| [ ] | G3-02 计算规模与精度对照 | 测量计算效率及数值误差 | GEMM，固定 M/N/K、FP32/FP16 等模式、核对参考结果 | 支持对应类型的 GPU | 数据类型或 Tensor Core 改变时必须同时报告精度条件 |
| [ ] | G3-03 stream 与 kernel 优化 | 理解并发、访存和同步开销 | 固定工作量比较 1/2/4 stream、合并访问与流水线 | 同上 | 一次改变一个变量，避免把数据量变化当优化收益 |
| [ ] | G3-04 裸机与 VM 性能对照 | 判断直通与 CPU/NUMA 配置影响 | 同一卡先裸机后直通，固定版本、功耗和输入 | 可直通 GPU | 同一设备时分复用，不用不同型号机器推断虚拟化开销 |

### 4.2 G3-01：传输测试

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

### 4.3 G3-02：矩阵计算与正确性

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

### 4.4 G3-03：分析方法

对同一可参数化程序保存带行号信息的构建，Release 测量不启用 `-G`。性能采样与正式结果分别运行：

```bash
nsys profile --trace=cuda,nvtx,osrt -o "$LAB/results/timeline" ./gpu_bench
ncu --set basic -o "$LAB/results/kernel" ./gpu_bench
compute-sanitizer --tool memcheck ./gpu_bench
```

`gpu_bench` 为待编写的统一基准程序占位名，不是仓库已有程序；在程序及正确性检查完成前不执行这些命令。Nsight Compute 指标权限按管理员策略授予，不全局放宽 profiling 权限。不同版本 profiler 支持范围需核对。

先从 Nsight Systems 检查 CPU 空洞、H2D/D2H、同步与 stream 重叠，再从 Nsight Compute 检查 memory throughput、SM 利用、occupancy、寄存器压力与访存合并。高 occupancy 不自动等于高性能；每个改动需要相同工作量的前后数据。

### 4.5 G3-04：裸机/VM 与报告

同一 GPU 先在裸机完成矩阵，再释放并直通到 VM 重跑。两边保持驱动/库兼容版本、输入、GPU 时钟策略、功率上限、温度区间和 CPU/NUMA 位置一致；不支持完全一致时列出差异。不要为固定条件擅自修改生产环境功率或锁频。

| 路径 | 负载/规模 | 类型/模式 | pinned/stream | kernel 时间 | 端到端时间 | 带宽或 FLOP/s | 最大误差 | 温度/功率/时钟 | 日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | — | — | — | — | — | — |

报告至少包含重复值、均值和标准差。若报告 P95/P99，需保留每次样本、说明分位数算法并提供足够样本；样例仅提供平均值时不能补写尾延迟。虚拟化耗时开销为 `(VM时间-裸机时间)/裸机时间×100%`；吞吐与延迟分别用各自定义，不能混用方向。

## 5. Phase 1.4 / 第四天：同机多 GPU 通信

### 5.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | G4-01 多卡拓扑与 P2P 能力确认 | 确定通信经过 PCIe、NVLink 或主机内存 | topo、P2P 查询、带宽与延迟样例 | 同机两张 GPU；NVLink 为条件项 | 设备数量不代表具备直接互访能力 |
| [ ] | G4-02 NCCL 构建和集合通信 | 建立 AllReduce/AllGather 基线 | 固定 NCCL 与 nccl-tests，验证结果和带宽 | 至少两卡及兼容 CUDA | 标准集合通信便于观察消息规模与拓扑影响 |
| [ ] | G4-03 P2P 路径对照 | 量化直接互访与回退路径差异 | 默认配置对比 `NCCL_P2P_DISABLE=1`，保留日志 | 支持 P2P 的 GPU 对 | 只禁用一个传输能力，不把配置意图当实际路径 |
| [ ] | G4-04 多卡报告 | 识别小消息和大消息瓶颈 | 扫描长度、记录 algbw/busbw、正确性和拓扑 | 同上 | 区分算法带宽与换算后的总线带宽 |

### 5.2 G4-01：P2P 核查

GPU 需在宿主机 NVIDIA 驱动下使用；若刚完成直通实验，先关 VM 并按恢复流程重新绑定。不能在 VFIO 持有期间同时跑裸机 CUDA。

```bash
nvidia-smi topo -m
cd "$LAB/src/cuda-samples"
make -C Samples/5_Domain_Specific/p2pBandwidthLatencyTest -j"$(nproc)"
./Samples/5_Domain_Specific/p2pBandwidthLatencyTest/p2pBandwidthLatencyTest
```

查询每对 GPU 是否支持 peer access。相同 PCIe switch、跨 CPU socket、NVLink 连接分别记录；不支持 P2P 时保留回退测试，但不能生成 P2P 开/关收益。普通 CUDA IPC/P2P 不能假设跨 VM 可用。

### 5.3 G4-02：固定软件与单机 NCCL

按 NCCL 安装指南安装与 CUDA/驱动兼容的开发库，记录包版本与库路径。然后固定 nccl-tests commit：

```bash
cd "$LAB/src"
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests
# 将下列值替换为经过核对、适配所选 CUDA/NCCL 的完整 commit。
export NCCL_TESTS_COMMIT='<固定的完整提交哈希>'
git checkout "$NCCL_TESTS_COMMIT"
make -j"$(nproc)" CUDA_HOME="$CUDA_HOME" NCCL_HOME=/usr
CUDA_VISIBLE_DEVICES=0,1 NCCL_DEBUG=INFO \
  ./build/all_reduce_perf -b 128 -e 128M -f 2 -g 2 -w 10 -n 100 -c 1
```

此处 `-g 2` 是一个进程/线程使用两张卡。随后运行 `all_gather_perf`，保持参数一致。分别为两种集合通信补测必需长度 1500 B（按所选 datatype 的元素大小对齐）：

```bash
CUDA_VISIBLE_DEVICES=0,1 ./build/all_reduce_perf \
  -b 1500 -e 1500 -g 2 -w 10 -n 100 -c 1
CUDA_VISIBLE_DEVICES=0,1 ./build/all_gather_perf \
  -b 1500 -e 1500 -g 2 -w 10 -n 100 -c 1
```

`-b 128 -f 2` 覆盖 128、256、512 等倍增点，不会覆盖 1500。记录程序实际打印的 size，某些 collective 会按 rank/元素数调整请求长度。显存不足时降低上限并记录，不能关闭正确性检查来绕过失败。

### 5.4 G4-03：传输对照与判定

同一测试在两个独立进程环境运行：

```bash
# 默认路径：不继承先前的禁用项
env -u NCCL_P2P_DISABLE NCCL_DEBUG=INFO CUDA_VISIBLE_DEVICES=0,1 \
  ./build/all_reduce_perf -b 128 -e 128M -f 2 -g 2 -w 10 -n 100 -c 1
# 禁用 NCCL 的 P2P 路径，观察实际回退
NCCL_P2P_DISABLE=1 NCCL_DEBUG=INFO CUDA_VISIBLE_DEVICES=0,1 \
  ./build/all_reduce_perf -b 128 -e 128M -f 2 -g 2 -w 10 -n 100 -c 1
```

这不等于物理关闭 NVLink 或拆除 PCIe 链路。检查 NCCL 日志实际选择的传输通道；若原配置本就未使用 P2P，则两个结果不能称为 P2P 加速比较。进程退出后环境隔离，避免后续跨节点实验继承禁用项。

测试矩阵为 AllReduce/AllGather × 默认/P2P 禁用 × 消息长度，每格至少 3 轮，区分 in-place/out-of-place。正确性要求错误计数为 0；失败时保留日志并停止该格性能归纳。

### 5.5 G4-04：报告口径

`algbw` 是算法数据量与时间换算，`busbw` 是按 collective 和 rank 数换算的指标，不是硬件传感器直接测得的链路带宽。例如 N 个 rank 的 AllReduce 常用 `busbw = algbw × 2(N-1)/N`，AllGather 使用其对应公式；与所选 nccl-tests 版本说明核对，且不把两个指标相加。

| GPU 对/拓扑 | collective | 实际 size B | rank 数 | 默认/禁用 P2P | 实际传输 | 时间 | algbw | busbw | 错误数 | 日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | 待记录 | 待记录 | — | — | — | — | — |

NVLink 不存在时只分析 PCIe 路径；一张卡时本阶段多卡任务不执行，不将单 rank collective 当成双卡通信。

## 6. Phase 1.5 / 第五天：跨节点 NCCL、RDMA 与 GPUDirect

### 6.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | G5-01 跨节点网络基线 | 排除地址、路由和 CPU 网络瓶颈 | ping、受控网络吞吐测试、接口与 NUMA 检查 | 两节点，各一 GPU，独立数据网 | 先验证网络，再解释 GPU 集合通信性能 |
| [ ] | G5-02 MPI-NCCL Socket 基线 | 建立可工作的跨机集合通信 | MPI 版 nccl-tests，一节点一 rank/一 GPU | 两节点、可达 Ethernet 网络 | 固定 rank 与设备映射，先避免多卡调度复杂性 |
| [ ] | G5-03 RDMA/GPUDirect 条件实验 | 比较主机中转与 GPU 直接网络传输 | RDMA 连通检查、NCCL IB transport、GDR 证据 | 兼容 GPU/NIC/PCIe 拓扑/驱动及 IB 或 RoCE 网络 | 单独验证网络 RDMA 与 GPU 内存 RDMA，不把二者等同 |
| [ ] | G5-04 跨节点性能与专业方向报告 | 解释带宽、延迟、拓扑与瓶颈 | 长度扫描、Socket/RDMA/GDR 对照、重复统计 | 同上 | 以实际传输日志和数据归因，不用开关状态代替证据 |

### 6.2 G5-01：节点与网络准备

| 节点 | 数据网地址 | GPU | 执行目录 |
| --- | --- | --- | --- |
| gpu-a | 198.51.100.21/24 | 本节点设备 0 | 两节点相同的 `$LAB/src/nccl-tests` |
| gpu-b | 198.51.100.22/24 | 本节点设备 0 | 同上 |

`gpu-a`、`gpu-b` 应通过受控 DNS 或 hosts 配置解析到数据网络，管理网络另行配置。确认 MTU、路由、对端 ICMP 和数据端口策略一致。使用实验账户建立最小权限 SSH 信任，不关闭 host key 检查，不把私钥放入镜像或仓库。

固定节点 GPU/网卡/CPU 亲和性，使用 `nvidia-smi topo -m`、`numactl -H` 与 PCI sysfs 判断本地性。跨 NUMA 是独立变量，不应在 Socket 和 RDMA 组间偷偷变更。

MPI 启动控制连接和 NCCL 数据连接都必须被允许；按 MPI/NCCL 版本配置限定端口或仅在隔离实验网按对端 IP 放行，不全局关闭防火墙。

### 6.3 G5-02：编译 MPI 版与 Socket 测试

两节点安装相同 Open MPI 与开发库，NCCL、CUDA 和测试程序采用相同版本。为避免复用第四天对象文件，重新构建：

```bash
sudo apt-get install openmpi-bin libopenmpi-dev
cd "$LAB/src/nccl-tests"
make clean
make -j"$(nproc)" MPI=1 MPI_HOME=/usr \
  CUDA_HOME="$CUDA_HOME" NCCL_HOME=/usr
```

确认每个节点非交互 shell 都能找到相同库和二进制。以下采用 Open MPI 命令；`eno2` 替换为两节点实际数据接口，若命名不同则分别设置环境，不统一强套：

```bash
export NCCL_SOCKET_IFNAME='=eno2'
export NCCL_IB_DISABLE=1
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,NET,GRAPH
export CUDA_VISIBLE_DEVICES=0
mpirun -np 2 --host gpu-a:1,gpu-b:1 --map-by ppr:1:node \
  -x NCCL_SOCKET_IFNAME -x NCCL_IB_DISABLE -x NCCL_DEBUG \
  -x NCCL_DEBUG_SUBSYS -x CUDA_VISIBLE_DEVICES \
  "$LAB/src/nccl-tests/build/all_reduce_perf" \
  -b 128 -e 128M -f 2 -g 1 -w 10 -n 100 -c 1
```

此处总 rank 数为 2，每个进程 `-g 1` 使用本地一张 GPU；不能把 `-g` 当作跨节点 GPU 总数。测试以普通用户运行，不使用 root 绕过 MPI 安全限制。需要时依据所选 MPI 版本单独指定 MPI 的管理/数据网接口；`NCCL_SOCKET_IFNAME` 不控制所有 MPI 连接。

运行 AllGather 并单点补测 1500 B。保存 NCCL 日志，确认实际为 Socket transport。MPI 启动成功或两主机能 ping，不构成 NCCL 已连通的充分证据；要求 collective 完成且错误计数为 0。

### 6.4 G5-03：RDMA 与 GPUDirect

先检查网卡和网络：

```bash
rdma link show
ibv_devinfo
ibdev2netdev
nvidia-smi topo -m
```

这些命令依赖已安装的 rdma-core/厂商诊断工具；命令缺失时按选定驱动栈补齐，不混装另一套内核驱动。InfiniBand 需要有效的子网管理，RoCEv2 需要正确的 GID、地址、MTU 与交换网络配置。PFC/ECN、缓冲与拥塞策略由网络方案确定并记录，不在未知生产网络上盲目开启。

使用匹配版本 perftest，在 B 侧执行 `ib_write_bw -d mlx5_0`，A 侧执行 `ib_write_bw -d mlx5_0 198.51.100.22`；RoCE 按实际路由/GID 增加该版本要求的 `-R`、GID index 等参数。先查 `--help` 核对功能与默认端口，确认双方 port、GID、MTU 和测试类型一致。普通主机内存 RDMA 成功后，再做支持 GPU buffer 的诊断。

GPUDirect RDMA 还要求 GPU、NIC、PCIe 拓扑、驱动与内存注册路径兼容。按版本选用 DMA-BUF 或 `nvidia-peermem` 等支持路径，不能假设加载模块就一定启用。IOMMU 与地址转换条件需按厂商要求核对；与虚拟机实验平台设置冲突时，记录不支持并停止该项，不为追求性能擅自关闭隔离。

从 Socket 组切换至 RDMA 组：

```bash
export NCCL_IB_DISABLE=0
export NCCL_IB_HCA='=mlx5_0:1'
mpirun -np 2 --host gpu-a:1,gpu-b:1 --map-by ppr:1:node \
  -x NCCL_SOCKET_IFNAME -x NCCL_IB_DISABLE -x NCCL_IB_HCA \
  -x NCCL_DEBUG -x NCCL_DEBUG_SUBSYS -x CUDA_VISIBLE_DEVICES \
  "$LAB/src/nccl-tests/build/all_reduce_perf" \
  -b 128 -e 128M -f 2 -g 1 -w 10 -n 100 -c 1
```

`mlx5_0:1` 是示例 HCA/port；两节点映射不同应分别设置。`NCCL_IB_DISABLE=0` 只允许 IB/RoCE transport，不保证被选择；以 NCCL 日志中的 NET/IB、插件、GDR 相关信息和实际端口计数为准。未使用的传输标为回退，不归入 RDMA 结果。

若所选 NCCL 版本支持，以同一 RDMA 配置设置 `NCCL_NET_GDR_LEVEL=LOC` 作为禁用 GDR 的对照，另一组清除该变量采用默认自动策略。经版本文档核对后，将变量通过 `mpirun -x` 传给所有 rank；不能只在启动节点设置。分别确认：

1. Socket 网络；
2. RDMA transport，但 GPU 数据经主机内存中转；
3. RDMA transport 且 GPU buffer 直接注册/传输。

第三组需日志、受支持 GPU-buffer 诊断及 NIC/拓扑证据相互支持；仅看到 `NET/IB` 不足以证明 GPUDirect。若无法控制或确认 GDR，中转/直接两组标为“路径未确认”，不输出直接对比结论。该实验主线在裸机进行，不能假设同样的 GDR 路径可跨 VM 使用。

### 6.5 G5-04：矩阵与报告

对每种已确认路径执行 AllReduce/AllGather × 128/256/512/1500 B × 1/4/16/64 MiB 代表点（取这些长度的并集，不是二者相乘），并可增加倍增扫描；每格预热 10 次、正式至少 100 次，至少 3 轮。固定 2 rank、一节点一 GPU，更多节点或多卡另列扩展组。

| 运行编号 | collective / rank | 实际消息 B | 网络路径 | GDR 状态及证据 | 时间 | algbw | busbw | CPU/GPU/NIC 计数 | 错误数 | 原始日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | 待记录 | — | — | — | — | — | — |

分析小消息是否受启动/同步时延限制，大消息是否受 NIC、PCIe、NUMA 或 GPU 内存限制。比较 Socket 与 RDMA 时区分协议、CPU 与内存路径变化；比较 GDR 时确保网络 transport 不变。交换机与网卡拥塞、链路降速、软件插件缺失和错误恢复均需记录。

性能增益按同口径吞吐计算 `(新路径-基线)/基线×100%`；延迟降低按 `(基线-新路径)/基线×100%`。不从 NCCL 算法带宽推断公网性能，也不从利用率推断功耗。无实际测量时仅保留表格与操作方法。

## 7. 交付清单、报告结构与恢复

### 7.1 阶段交付物

| 阶段 | 状态 | 交付物 |
| --- | --- | --- |
| Phase 1.1 | 待执行 | GPU 能力与拓扑表、驱动/工具版本、样例正确性与内存检查日志 |
| Phase 1.2 | 待执行 | 虚拟化方式对比、IOMMU 与直通记录、镜像清单/散列、VM 功能与网络日志 |
| Phase 1.3 | 待执行 | 单卡测试矩阵、输入与数值容差、profiler 文件、裸机/VM 对照报告 |
| Phase 1.4 | 待执行 | 多卡拓扑、P2P 能力、NCCL 配置及实际传输日志、同机通信报告 |
| Phase 1.5 | 待执行 | 网络/RDMA/GDR 证据、跨节点日志、性能统计与瓶颈报告 |

每份报告包含环境、拓扑、问题定义、变量与控制条件、操作命令、原始数据路径、统计方法、正确性、性能比较、限制及结论。镜像与大型 profiler 文件存放实验存储，在本文登记路径、软件版本和散列，不提交 Git。

无设备时只完成知识调研、参数规划和方法文档，执行状态保持未执行；不填写通过、加速比、带宽或错误率。

### 7.2 恢复顺序

停止 MPI/NCCL/CUDA 进程并正常关闭 VM；确认设备无使用者后，从 vfio-pci 解绑每个实验 GPU 功能，清除 `driver_override`，再由原驱动探测。部分设备不支持可靠复位时按产品要求在维护窗口重启，不反复强制 reset。

恢复原 MIG profile、MPS 服务状态、功率/时钟策略、CPU/NUMA 亲和性和网络配置；仅清理实验 TAP/桥及临时环境变量，不中止其他 GPU 作业。检查宿主机 `nvidia-smi`、设备归属、管理通路及已保留的配置。

## 8. 名词与缩写

| 缩写/术语 | 全称 | 本阶段含义 |
| --- | --- | --- |
| GPU / CPU | Graphics Processing Unit / Central Processing Unit | 图形/通用并行处理器与中央处理器 |
| CUDA | Compute Unified Device Architecture | NVIDIA GPU 编程与运行生态 |
| SIMT / SM | Single Instruction Multiple Threads / Streaming Multiprocessor | 单指令多线程执行模型与流式多处理器 |
| warp / block / kernel | 线程束 / 线程块 / 设备执行函数 | CUDA 调度、协作与执行单元 |
| Compute Capability | 计算能力版本 | GPU 架构对应的指令与功能级别，不等同于性能分数 |
| HBM / GDDR | High Bandwidth Memory / Graphics Double Data Rate | GPU 常见显存技术 |
| PCIe / BDF / BAR | Peripheral Component Interconnect Express / Bus:Device.Function / Base Address Register | 设备互连、地址和资源窗口 |
| MMIO | Memory-Mapped I/O | CPU 地址空间映射的设备寄存器/资源 |
| NVLink / NVSwitch | NVIDIA GPU 互连 / 互连交换芯片 | 具体型号支持的 GPU 通信链路与交换结构 |
| P2P / IPC | Peer-to-Peer / Inter-Process Communication | 设备直接互访与进程间资源共享 |
| NUMA | Non-Uniform Memory Access | CPU、内存和设备的非均匀访问拓扑 |
| IOMMU / DMA | Input-Output Memory Management Unit / Direct Memory Access | I/O 地址转换隔离与设备直接访存 |
| VFIO / KVM / QEMU | Virtual Function I/O / Kernel-based Virtual Machine / Quick Emulator | 设备访问框架、Linux 虚拟化与设备模型 |
| UEFI / OVMF | Unified Extensible Firmware Interface / Open Virtual Machine Firmware | 固件接口与虚拟机 UEFI 实现 |
| TAP / virtio | 二层虚拟接口 / Virtual I/O | 客户机软件网络入口与半虚拟化接口 |
| vGPU / MIG / MPS | Virtual GPU / Multi-Instance GPU / Multi-Process Service | GPU 虚拟化、硬件实例分区与多进程共享机制 |
| SR-IOV | Single Root I/O Virtualization | PCIe 单根 I/O 虚拟化，不能泛指所有 GPU 共享 |
| CUDA stream / event | 命令流 / 事件 | 异步工作排序与完成/计时机制 |
| pinned / pageable | 页锁定 / 可换页主机内存 | 主机内存分配类型，影响 DMA 与异步传输 |
| H2D / D2H / D2D | Host-to-Device / Device-to-Host / Device-to-Device | 主机与设备间的拷贝方向 |
| GEMM / cuBLAS | General Matrix Multiply / CUDA Basic Linear Algebra Subprograms | 通用矩阵乘及 CUDA 线性代数库 |
| FP16 / BF16 / FP32 / FP64 | Floating Point 16 / Brain Floating Point 16 / Floating Point 32 / Floating Point 64 | 不同位宽与数值范围/精度的浮点格式 |
| TF32 / Tensor Core | TensorFloat-32 / 张量计算核心 | 特定硬件数值/矩阵计算路径，不能与严格 FP32 结果等同 |
| FLOP/s | Floating Point Operations Per Second | 浮点运算吞吐，G/T 分别表示十亿/万亿级 |
| ECC | Error Correcting Code | 显存等资源的错误检测纠正机制 |
| NCCL | NVIDIA Collective Communications Library | GPU 集合通信库 |
| MPI / rank | Message Passing Interface / 进程编号 | 分布式进程通信接口与参与者编号 |
| AllReduce / AllGather | 全体归约 / 全体收集 | 所有参与者获得归约结果/各参与者数据的集合操作 |
| algbw / busbw | Algorithm Bandwidth / Bus Bandwidth | nccl-tests 算法带宽与按算法模型换算的总线带宽 |
| RDMA / GDR | Remote Direct Memory Access / GPUDirect RDMA | 网络直接访存与 GPU 显存直接网络传输路径 |
| HCA / IB | Host Channel Adapter / InfiniBand | RDMA 适配器与互连技术 |
| RoCE / GID | RDMA over Converged Ethernet / Global Identifier | 以太网上的 RDMA 与 RDMA 地址标识 |
| DMA-BUF | DMA Buffer Sharing Framework | Linux 可用于跨设备共享/注册内存的框架 |
| PFC / ECN | Priority-based Flow Control / Explicit Congestion Notification | 按优先级流控与显式拥塞通知 |
| MTU / UUID | Maximum Transmission Unit / Universally Unique Identifier | 最大传输单元与设备唯一标识 |
| P95 / P99 | 95th / 99th Percentile | 样本的第 95/99 百分位 |

## 9. 参考资料

执行时使用与实际工具版本对应的章节和兼容表。

- [CUDA 安装指南](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)
- [CUDA 兼容性](https://docs.nvidia.com/deploy/cuda-compatibility/)
- [CUDA C++ 编程指南](https://docs.nvidia.com/cuda/cuda-c-programming-guide/)
- [CUDA Samples](https://github.com/NVIDIA/cuda-samples)
- [Compute Sanitizer](https://docs.nvidia.com/compute-sanitizer/)
- [cuBLAS 文档](https://docs.nvidia.com/cuda/cublas/)
- [Nsight Systems](https://docs.nvidia.com/nsight-systems/)
- [Nsight Compute](https://docs.nvidia.com/nsight-compute/)
- [MIG 用户指南与支持型号](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [NVIDIA vGPU 文档](https://docs.nvidia.com/vgpu/)
- [NCCL 使用指南与环境变量](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [nccl-tests 构建与参数](https://github.com/NVIDIA/nccl-tests)
- [nccl-tests 性能指标定义](https://github.com/NVIDIA/nccl-tests/blob/master/doc/PERFORMANCE.md)
- [GPUDirect RDMA](https://docs.nvidia.com/cuda/gpudirect-rdma/)
- [Linux VFIO](https://docs.kernel.org/driver-api/vfio.html)
