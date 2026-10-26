# 名词与缩写

本文件集中记录 DPU、GPU、NPU 各阶段使用的名词与缩写。通用术语只保留一处定义，专用术语按方向分类；后续阶段新增术语时同步补充本表。产品名称、API 名称及普通技术术语不强行展开为缩写。

## 1. 通用硬件、系统与虚拟化

| 缩写/术语 | 英文全称或名称 | 含义与边界 |
| --- | --- | --- |
| CPU | Central Processing Unit | 中央处理器，承担通用计算与系统控制 |
| GPU | Graphics Processing Unit | 图形处理器，也用于数据并行计算 |
| DPU | Data Processing Unit | 承担网络、存储或安全数据处理的处理器/设备；具备网卡卸载能力不等于具备独立处理器 |
| NPU | Neural Processing Unit | 面向神经网络计算的处理单元；本仓库不以此缩写表示 Network Processing Unit |
| NIC | Network Interface Card | 网络接口卡 |
| PCIe | Peripheral Component Interconnect Express | CPU 与 GPU、网卡等设备之间的高速互连 |
| BDF | Bus:Device.Function | PCI 设备功能地址；Linux 完整地址还包含 domain，例如 `0000:41:00.0` |
| BAR | Base Address Register | PCI 设备描述内存或 I/O 资源窗口的寄存器 |
| MMIO | Memory-Mapped I/O | 将设备资源映射到 CPU 地址空间的访问方式 |
| DMA | Direct Memory Access | 设备直接访问内存的机制 |
| IOMMU | Input-Output Memory Management Unit | 提供 I/O 地址转换与隔离；IOMMU 组影响设备能否独立直通 |
| NUMA | Non-Uniform Memory Access | CPU、内存和设备之间访问代价不均匀的系统拓扑 |
| IRQ | Interrupt Request | 中断请求 |
| BIOS | Basic Input/Output System | 传统平台固件接口；实验中也常泛指主板固件设置界面 |
| UEFI | Unified Extensible Firmware Interface | 统一可扩展固件接口 |
| OVMF | Open Virtual Machine Firmware | 为虚拟机提供 UEFI 的固件实现 |
| VT-x / AMD-V | Intel Virtualization Technology / AMD Virtualization | CPU 硬件虚拟化能力 |
| VT-d / AMD-Vi | Intel Virtualization Technology for Directed I/O / AMD I/O Virtualization | 平台 I/O 虚拟化能力，与 CPU 虚拟化开关不同 |
| SR-IOV | Single Root I/O Virtualization | 将 PCIe 设备暴露为 PF 与多个 VF 的单根 I/O 虚拟化机制；不能泛指所有 GPU 共享方案 |
| PF / VF | Physical Function / Virtual Function | 物理功能负责设备资源管理，虚拟功能可按平台隔离条件分配给端点 |
| VFIO | Virtual Function I/O | Linux 用户态设备访问与直通框架，不仅适用于 SR-IOV VF |
| passthrough | Device Passthrough | 设备直通，使客户机直接使用所分配的硬件功能 |
| VM / VMM | Virtual Machine / Virtual Machine Monitor | 虚拟机与虚拟机监控器 |
| Hypervisor | Hypervisor | 管理虚拟机执行与资源隔离的虚拟化层 |
| vCPU | Virtual CPU | 分配给虚拟机的虚拟处理器；数量不等于独占的物理核心数 |
| QEMU | Quick Emulator | 设备模拟与虚拟机运行软件；无 KVM 时可使用软件 CPU 模拟 |
| KVM | Kernel-based Virtual Machine | Linux 内核提供的硬件辅助 CPU 虚拟化机制 |
| virtio | Virtual I/O | 半虚拟化 I/O 接口，用于虚拟磁盘、网络等设备 |
| TAP | TAP virtual network interface | 面向二层以太网帧的虚拟网络接口，不是 VF |
| namespace | Linux Namespace | Linux 资源视图隔离机制；network namespace 隔离接口、路由和网络栈等 |
| container | Container | 共用宿主内核的进程隔离与部署环境，不等同于完整虚拟机 |
| PV / HVM / PVH | Paravirtualization / Hardware Virtual Machine / PVH | Xen 的半虚拟化、硬件辅助虚拟化及结合硬件辅助与半虚拟化接口的模式 |
| Dom0 | Domain 0 | Xen 中承担设备及虚拟机管理职责的特权域 |
| HA | High Availability | 高可用 |
| ABI / API | Application Binary Interface / Application Programming Interface | 二进制接口与程序接口；驱动和库还需满足版本兼容条件 |
| SKU | Stock Keeping Unit | 具体产品型号单元；同系列不同 SKU 的能力可能不同 |
| ECC | Error Correcting Code | 内存等资源的错误检测与纠正机制 |
| qcow2 | QEMU Copy On Write version 2 | QEMU 磁盘镜像格式，可使用 backing file；写入层不一定是独立完整镜像 |
| ISO | ISO 9660 disk image | 实验中指安装介质镜像文件 |
| SSH | Secure Shell | 远程登录与命令执行协议；SSH host key 与用户认证密钥用途不同 |
| SHA-256 | Secure Hash Algorithm 256-bit | 文件完整性记录使用的散列算法；散列本身不提供发布者身份认证 |
| LTS | Long-Term Support | 长期支持版本，仍需核对具体维护期限 |

## 2. DPU、网络与数据面

| 缩写/术语 | 英文全称或名称 | 含义与边界 |
| --- | --- | --- |
| CX5 | ConnectX-5 | 实验使用的 NVIDIA/Mellanox 网卡系列，不等同于带独立 Arm 处理器的 BlueField DPU |
| MFT | NVIDIA Firmware Tools | 网卡固件查询与配置工具套件 |
| eSwitch | Embedded Switch | 网卡内部的嵌入式交换机 |
| switchdev | Linux switch device model | Linux 交换设备控制模型；支持范围取决于设备、驱动和固件 |
| representor / rep | Port Representor | 宿主机对 VF 等硬件端口的控制与数据面表示，不是 VF 本身 |
| netdev | Network Device | Linux 网络设备接口；OVS `datapath_type=netdev` 则指用户态 datapath 类型 |
| uplink | Uplink Port | 连接物理网络的上联端口 |
| OVS | Open vSwitch | 提供虚拟网络交换与控制接口的软件交换机 |
| OVSDB | Open vSwitch Database | OVS 配置数据库及相关管理协议 |
| datapath | Datapath | 实际数据转发路径；可由内核、用户态或硬件执行 |
| OpenFlow | OpenFlow | 定义交换匹配与动作的控制协议；逻辑流表不等同于硬件流表 |
| NFV | Network Functions Virtualization | 网络功能虚拟化 |
| MAC | Media Access Control | 链路层介质访问控制；MAC 地址用于标识以太网接口 |
| IP / IPv4 | Internet Protocol / Internet Protocol version 4 | 网络层寻址与路由协议及其第四版 |
| ARP | Address Resolution Protocol | IPv4 邻居地址解析协议 |
| ICMP | Internet Control Message Protocol | 网络控制与诊断协议，ping 通常使用其回显报文 |
| TCP / UDP | Transmission Control Protocol / User Datagram Protocol | 可靠字节流传输协议与数据报传输协议 |
| MTU | Maximum Transmission Unit | 接口可承载的最大网络层报文大小；不等同于应用有效载荷或线上以太网帧长 |
| MSS | Maximum Segment Size | TCP 数据段有效载荷上限，不含 IP/TCP 头 |
| TSO | TCP Segmentation Offload | 由网卡执行 TCP 发送分段 |
| GSO | Generic Segmentation Offload | 通用发送分段机制，常在软件路径完成 |
| LRO | Large Receive Offload | 大包接收聚合机制，支持及适用路径依驱动而定 |
| GRO | Generic Receive Offload | 通用接收聚合机制 |
| TOE | TCP Offload Engine | TCP 协议栈卸载引擎；TSO/GSO/LRO/GRO 不等于完整 TOE |
| RX / TX | Receive / Transmit | 接收与发送 |
| pps | Packets Per Second | 每秒包数 |
| Gbit/s | Gigabits Per Second | 每秒十亿比特，不等于 GB/s |
| RR / STREAM | Request-Response / Stream | netperf 的请求响应与流吞吐测试模型；STREAM 不直接给出尾延迟 |
| VLAN | Virtual Local Area Network | 虚拟局域网，常用于二层网络划分 |
| VXLAN | Virtual Extensible LAN | 在 UDP/IP 上承载二层 overlay 的封装，不自带加密或身份认证 |
| VTEP | VXLAN Tunnel Endpoint | VXLAN 封装与解封装端点 |
| VNI | VXLAN Network Identifier | VXLAN 的 24 位逻辑网络标识 |
| underlay / overlay | Underlay Network / Overlay Network | 承载隧道的底层网络与建立在其上的逻辑网络 |
| NAT | Network Address Translation | 网络地址转换，与 VXLAN 封装不同 |
| TC | Traffic Control | Linux 流量控制框架 |
| flower | flower classifier | TC 中按报文字段匹配的分类器，可结合驱动下发硬件规则 |
| DPDK | Data Plane Development Kit | 用户态数据面开发工具包，不自动加速普通 TCP 应用 |
| PMD | Poll Mode Driver | 轮询模式驱动；OVS PMD 线程负责用户态包处理 |
| hugepage | Huge Page | 大内存页，DPDK 常用于降低地址转换开销并组织数据面内存 |
| lcore | Logical Core | DPDK 逻辑执行核 |
| rte_flow | DPDK Flow API | DPDK 流匹配和动作接口；接口存在不代表所有动作均可卸载 |
| bifurcated driver | Bifurcated Driver | 内核与用户态协作的驱动模式；mlx5 PF 通常保留内核驱动，不应照搬其他 PMD 的解绑方式 |
| vhost-user | vhost-user protocol | QEMU virtio 与用户态交换机间的通信协议，常使用共享内存传递数据 |
| RDMA | Remote Direct Memory Access | 跨网络直接访问已注册内存的机制；主机内存 RDMA 不等于 GPU 内存 RDMA |
| HCA | Host Channel Adapter | RDMA 网络适配器 |
| IB | InfiniBand | 高性能网络互连技术；NCCL IB transport 也可经兼容 verbs 路径使用 RoCE |
| RoCE | RDMA over Converged Ethernet | 在以太网上承载 RDMA；RoCEv2 使用 UDP/IP |
| GID | Global Identifier | RDMA 端口使用的全局标识；RoCE 场景需结合地址类型和路由选择 |
| PFC | Priority-based Flow Control | 按优先级流量控制，不能在未知网络中盲目启用 |
| ECN | Explicit Congestion Notification | 显式拥塞通知 |
| ACS | Access Control Services | PCIe 访问控制服务；ACS override 不能替代真实硬件隔离能力 |

## 3. GPU 计算、分析与通信

| 缩写/术语 | 英文全称或名称 | 含义与边界 |
| --- | --- | --- |
| CUDA | Compute Unified Device Architecture | NVIDIA GPU 编程与运行生态 |
| SIMT | Single Instruction Multiple Threads | 单指令多线程执行模型 |
| SM | Streaming Multiprocessor | 流式多处理器 |
| warp / block / kernel | Warp / Thread Block / Kernel | 线程束、线程块与设备执行函数；kernel 在此不指 Linux 内核 |
| Compute Capability | Compute Capability | GPU 架构的指令及功能级别，不是性能分数 |
| HBM / GDDR | High Bandwidth Memory / Graphics Double Data Rate | GPU 常见显存技术 |
| shared memory | CUDA Shared Memory | 同一线程块内可协作访问的设备内存资源，不是主机共享内存 |
| NVLink / NVSwitch | NVIDIA NVLink / NVIDIA NVSwitch | GPU 互连与互连交换技术；有多卡不代表具有这些硬件 |
| P2P | Peer-to-Peer | GPU 间直接互访能力，取决于型号、拓扑与软件配置 |
| IPC | Inter-Process Communication | 进程间通信；CUDA IPC 不能默认跨 VM 使用 |
| vGPU | Virtual GPU | GPU 虚拟化产品或能力，具体实现、型号和许可条件须单独核对 |
| MIG | Multi-Instance GPU | 支持型号上的 GPU 硬件分区机制，不自动等同于独立 PCIe VF |
| MPS | Multi-Process Service | CUDA 多进程共享执行服务，不提供与独立 VM 等价的安全边界 |
| CUDA stream / event | CUDA Stream / CUDA Event | 异步命令排序与完成、依赖或设备计时机制 |
| pinned / pageable | Pinned / Pageable Host Memory | 页锁定与可换页主机内存，影响 DMA 和异步传输能力 |
| H2D / D2H / D2D | Host-to-Device / Device-to-Host / Device-to-Device | 主机到设备、设备到主机、设备到设备的拷贝方向 |
| GEMM | General Matrix Multiply | 通用矩阵乘，标准运算量常按 `2MNK` 计算 |
| cuBLAS / cuBLASLt | CUDA Basic Linear Algebra Subprograms / cuBLASLt | CUDA 线性代数库及提供灵活矩阵布局、类型和算法选择的接口 |
| FP16 / FP32 / FP64 | 16/32/64-bit Floating Point | 不同位宽的浮点格式，数值范围与精度不同 |
| BF16 | Brain Floating Point 16 | 16 位浮点格式，指数位与尾数位配置不同于 FP16 |
| TF32 | TensorFloat-32 | 支持型号上的矩阵计算格式，不能等同于严格 FP32 运算 |
| Tensor Core | Tensor Core | 执行支持类型矩阵运算的硬件单元 |
| FLOP/s | Floating Point Operations Per Second | 浮点运算吞吐；GFLOP/s、TFLOP/s 分别为十亿、万亿次每秒 |
| occupancy | CUDA Occupancy | 活跃 warp 与硬件可支持活跃 warp 上限的比值，高 occupancy 不保证高性能 |
| NVTX | NVIDIA Tools Extension | 在分析工具中标注程序区间与事件的接口 |
| Nsight Systems / Nsight Compute | NVIDIA Nsight Systems / NVIDIA Nsight Compute | 系统时间线与 kernel 指标分析工具；采样结果应与正式计时分开 |
| Compute Sanitizer | NVIDIA Compute Sanitizer | GPU 程序内存、同步等正确性检查工具，不用于正式性能计时 |
| NCCL | NVIDIA Collective Communications Library | GPU 集合通信库 |
| MPI | Message Passing Interface | 分布式进程通信接口 |
| rank | Rank | 通信参与者编号；MPI rank、NCCL rank 和 GPU 数量的对应由程序配置决定 |
| AllReduce / AllGather | All-Reduce / All-Gather | 全体获得归约结果、全体收集各参与者数据的集合通信操作 |
| algbw / busbw | Algorithm Bandwidth / Bus Bandwidth | nccl-tests 算法带宽与按算法模型换算的总线带宽；后者不是硬件传感器读数 |
| GDR | GPUDirect RDMA | GPU 显存直接参与网络 RDMA 的路径；仅看到 NET/IB 不能证明 GDR 已生效 |
| DMA-BUF | DMA Buffer Sharing Framework | Linux 内存共享框架，可在受支持组合中用于 GPU 内存注册 |
| nvidia-peermem | NVIDIA peer-memory kernel module | 部分 GPUDirect RDMA 组合使用的内存注册模块；加载成功不等于传输已采用 GDR |
| UUID | Universally Unique Identifier | 设备或实例唯一标识，比不稳定的枚举编号更适合实验记录 |
| P95 / P99 | 95th / 99th Percentile | 第 95/99 百分位，需保留样本并说明统计方法 |
| CUDA Graph | CUDA Graph | 预先定义/捕获计算依赖并重复提交的机制，需单独考虑建图与实例化成本 |
| capture / replay | Stream Capture / Graph Replay | 捕获 stream 操作构建图，与重复执行已实例化图 |
| bank conflict | Shared Memory Bank Conflict | shared memory 访问映射至相同 bank 导致的串行化，具体规则依架构 |
| coalescing | Memory Coalescing | 将线程的全局访存合并为高效内存事务，不等同于接收包聚合 |
| AMP | Automatic Mixed Precision | 按算子选择计算类型的混合精度机制，不等同于简单转换整个模型为 FP16 |
| autocast / GradScaler | Automatic Casting / Gradient Scaler | 自动精度选择与梯度缩放；是否需要缩放依数据类型及计算路径 |
| DDP | Distributed Data Parallel | 多进程数据并行训练，各模型副本通过通信同步梯度 |
| microbatch | Microbatch | 梯度累积中一次前向/反向使用的局部样本批 |
| gradient accumulation | Gradient Accumulation | 多个 microbatch 累积梯度后执行一次参数更新，需正确归一化与同步 |
| activation checkpoint | Activation Checkpointing | 反向时重算部分激活以减少显存；不同于保存到磁盘的训练恢复状态 |
| checkpoint / RNG | Training Checkpoint / Random Number Generator | 训练恢复状态与随机数生成器；完整恢复通常需要模型以外的优化器、数据和随机状态 |
| strong / weak scaling | Strong / Weak Scaling | 固定全局工作量/固定每设备工作量的扩展实验，二者效率不可混报 |
| bucket | Gradient Bucket | DDP 组织梯度通信的分组，实际划分与参数顺序、规模及版本有关 |
| straggler | Straggler Rank | 先因计算、数据或其他因素变慢的 rank，其他 rank 的等待不一定是根因 |
| rendezvous | Distributed Rendezvous | 分布式参与者建立作业成员与初始化连接的过程，不代表数据通信已成功 |
| OOM | Out Of Memory | 内存资源不足，需记录失败规模和分配条件，不编造失败运行的耗时 |

## 4. NPU、模型部署与算子开发

| 缩写/术语 | 英文全称或名称 | 含义与边界 |
| --- | --- | --- |
| Ascend | Ascend | 昇腾计算产品与软件生态，不泛指所有 NPU |
| SoC | System on Chip | 芯片系统；ATC 目标 SoC 标识不能直接由板卡营销名称猜测 |
| TOPS | Tera Operations Per Second | 每秒万亿次操作；必须注明数据类型、稀疏/稠密和运算计数口径，不直接代表应用吞吐 |
| CANN | Compute Architecture for Neural Networks | 昇腾异构计算软件栈，包含模型、算子及运行支持 |
| AscendCL / ACL | Ascend Computing Language | 昇腾设备、内存、stream、模型等运行时接口；此处 ACL 不指网络访问控制列表 |
| ATC | Ascend Tensor Compiler | 将受支持的模型编译为目标设备离线模型的工具 |
| ONNX | Open Neural Network Exchange | 模型交换格式，opset、算子语义与动态 shape 支持须核对 |
| opset | Operator Set Version | ONNX 算子集合版本，影响导出和编译兼容性 |
| OM | Offline Model | 昇腾离线模型产物，绑定相应编译目标与运行约束 |
| torch_npu / TorchNPU | Ascend Extension for PyTorch | PyTorch 的昇腾设备适配；安装包版本与产品发布版本要分别记录 |
| Ascend C | Ascend C | 昇腾自定义算子编程语言及配套开发接口，不是 CUDA C++ 的直接兼容实现 |
| AI Core / AI CPU | Ascend AI Core / AI CPU | 昇腾计算资源类型；实际算子执行位置和能力以产品与采集证据为准 |
| Cube / Vector | Matrix / Vector Compute Unit | 矩阵与向量计算路径，具体组织及数据类型依 SoC |
| GM / UB | Global Memory / Unified Buffer | 设备全局存储与片上缓冲资源；大小及可访问方式依产品 |
| tiling / tile | Tiling / Tile | 划分工作块及局部存储占用的方案，需同时处理尾块、对齐与并发 |
| double buffering | Double Buffering | 用两个独立缓冲组织搬运与计算流水，重叠与正确性需要依赖同步保证 |
| HCCL | Huawei Collective Communication Library | 昇腾集合通信库，不可直接套用 NCCL 环境变量或传输证据 |
| msProf | MindStudio Profiler | 昇腾性能采集工具，入口和指标按所选发布版本核对 |
| MLP | Multi-Layer Perceptron | 多层感知机，本实验采用小规模全连接模型作为部署和训练负载 |
| ReLU | Rectified Linear Unit | 整流线性激活，常见定义为 `max(0, x)` |
| dtype / shape / layout | Data Type / Tensor Shape / Memory Layout | 数据类型、张量维度和内存布局；逻辑形状正确不保证 buffer 编排正确 |
| calibration | Quantization Calibration | 使用代表数据确定量化参数的过程，校准集与独立评测集应分离 |
| INT8 | 8-bit Integer | 8 位整数计算类型；量化还包含缩放等数值映射，不是简单强制转型 |
| Top-1 | Top-1 Accuracy | 最高预测类别与真实标签一致的比例，无标签负载不能报告该指标 |

## 5. 单位与测量口径

| 符号/术语 | 名称 | 含义与边界 |
| --- | --- | --- |
| B / bit | Byte / Bit | 字节与比特，1 B = 8 bit |
| MB / GB | Megabyte / Gigabyte | 十进制容量单位，分别为 10^6、10^9 B |
| MiB / GiB | Mebibyte / Gibibyte | 二进制容量单位，分别为 2^20、2^30 B |
| GB/s / GiB/s | Gigabytes / Gibibytes Per Second | 字节带宽，需与 Gbit/s 区分，并注明十进制或二进制口径 |
| offered load | Offered Load | 发送端提供的负载，不等于接收端有效吞吐 |
| latency / throughput | Latency / Throughput | 延迟与吞吐；两者应分别测量，不能从流吞吐推算尾延迟 |

## 6. 文档入口

- [实验目录](../README.md)
- [DPU 阶段目录与公共环境](../DPU/README.md)
- [GPU 阶段目录与公共环境](../GPU/README.md)
- [NPU 阶段目录与公共环境](../NPU/README.md)
