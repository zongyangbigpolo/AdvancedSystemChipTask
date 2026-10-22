# GPU Phase 5：跨节点 NCCL、RDMA 与 GPUDirect

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | GPU-P5-01 跨节点网络基线 | 排除地址、路由和 CPU 网络瓶颈 | ping、受控网络吞吐测试、接口与 NUMA 检查 | 两节点，各一 GPU，独立数据网 | 先验证网络，再解释 GPU 集合通信性能 |
| [ ] | GPU-P5-02 MPI-NCCL Socket 基线 | 建立可工作的跨机集合通信 | MPI 版 nccl-tests，一节点一 rank/一 GPU | 两节点、可达 Ethernet 网络 | 固定 rank 与设备映射，先避免多卡调度复杂性 |
| [ ] | GPU-P5-03 RDMA/GPUDirect 条件实验 | 比较主机中转与 GPU 直接网络传输 | RDMA 连通检查、NCCL IB transport、GDR 证据 | 兼容 GPU/NIC/PCIe 拓扑/驱动及 IB 或 RoCE 网络 | 单独验证网络 RDMA 与 GPU 内存 RDMA，不把二者等同 |
| [ ] | GPU-P5-04 跨节点性能与专业方向报告 | 解释带宽、延迟、拓扑与瓶颈 | 长度扫描、Socket/RDMA/GDR 对照、重复统计 | 同上 | 以实际传输日志和数据归因，不用开关状态代替证据 |

## 2. GPU-P5-01：节点与网络准备

| 节点 | 数据网地址 | GPU | 执行目录 |
| --- | --- | --- | --- |
| gpu-a | 198.51.100.21/24 | 本节点设备 0 | 两节点相同的 `$LAB/src/nccl-tests` |
| gpu-b | 198.51.100.22/24 | 本节点设备 0 | 同上 |

`gpu-a`、`gpu-b` 应通过受控 DNS 或 hosts 配置解析到数据网络，管理网络另行配置。确认 MTU、路由、对端 ICMP 和数据端口策略一致。使用实验账户建立最小权限 SSH 信任，不关闭 host key 检查，不把私钥放入镜像或仓库。

固定节点 GPU/网卡/CPU 亲和性，使用 `nvidia-smi topo -m`、`numactl -H` 与 PCI sysfs 判断本地性。跨 NUMA 是独立变量，不应在 Socket 和 RDMA 组间偷偷变更。

MPI 启动控制连接和 NCCL 数据连接都必须被允许；按 MPI/NCCL 版本配置限定端口或仅在隔离实验网按对端 IP 放行，不全局关闭防火墙。

## 3. GPU-P5-02：编译 MPI 版与 Socket 测试

两节点安装相同 Open MPI 与开发库，NCCL、CUDA 和测试程序采用相同版本。为避免复用 Phase 4 对象文件，重新构建：

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

## 4. GPU-P5-03：RDMA 与 GPUDirect

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

## 5. GPU-P5-04：矩阵与报告

对每种已确认路径执行 AllReduce/AllGather × 128/256/512/1500 B × 1/4/16/64 MiB 代表点（取这些长度的并集，不是二者相乘），并可增加倍增扫描；每格预热 10 次、正式至少 100 次，至少 3 轮。固定 2 rank、一节点一 GPU，更多节点或多卡另列扩展组。

| 运行编号 | collective / rank | 实际消息 B | 网络路径 | GDR 状态及证据 | 时间 | algbw | busbw | CPU/GPU/NIC 计数 | 错误数 | 原始日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | 待记录 | — | — | — | — | — | — |

分析小消息是否受启动/同步时延限制，大消息是否受 NIC、PCIe、NUMA 或 GPU 内存限制。比较 Socket 与 RDMA 时区分协议、CPU 与内存路径变化；比较 GDR 时确保网络 transport 不变。交换机与网卡拥塞、链路降速、软件插件缺失和错误恢复均需记录。

性能增益按同口径吞吐计算 `(新路径-基线)/基线×100%`；延迟降低按 `(基线-新路径)/基线×100%`。不从 NCCL 算法带宽推断公网性能，也不从利用率推断功耗。无实际测量时仅保留表格与操作方法。
