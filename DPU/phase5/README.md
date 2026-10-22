# DPU Phase 5：OVS-DPDK 与 VF 硬件卸载

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P5-01 DPDK 原理及网卡支持调研 | 理解 PMD、轮询、hugepage 和批处理 | 查对应版本 PMD 支持表，比较内核与用户态路径 | CX5；Intel/Broadcom 作对照 | 区分“有 PMD”与“支持 OVS 硬件流表卸载” |
| [ ] | DPU-P5-02 构建并初始化 OVS-DPDK | 建立用户态交换环境 | DPDK 源码构建、OVS 链接、hugepage、绑核、NUMA | 有可用大页和专用核心的主机 | 固定兼容版本，隔离 PMD 与 vCPU，减少跨 NUMA 访存 |
| [ ] | DPU-P5-03 VF 虚拟机接入 DPDK representor | 保留 VF 直通端点并更换交换后端 | mlx5 bifurcated 驱动、representor devargs、netdev 桥 | switchdev CX5、两个 VF VM | PF 留在 mlx5_core；只将交给 VM 的 VF 绑定 vfio-pci |
| [ ] | DPU-P5-04 DPDK 流卸载对照与报告 | 比较用户态软件交换与硬件 eSwitch | 复用矩阵，检查 rte_flow、PMD 与卸载计数 | 支持相应 rte_flow 动作的组合 | 与内核 TC 卸载分开取证，不能用 TC 表代替 DPDK 流表 |

## 2. DPU-P5-01：使用场景与设备支持

DPDK 在用户态通过 PMD 批量收发包，配合大页、内存池和 NUMA 亲和性降低每包处理开销。适用于 NFV、高 pps 交换、流量发生器等；代价包括专用 CPU、忙轮询功耗、内存规划及驱动兼容要求。它不是普通 TCP 应用的自动加速开关，netperf 在客户机内仍使用 Linux TCP/UDP 栈。

| 系列 | 常见 PMD | 绑定与能力边界 |
| --- | --- | --- |
| ConnectX-4/4 Lx/5/6/7、BlueField-2/3 | mlx5 | bifurcated 设计依赖 mlx5_core、mlx5_ib、ib_uverbs 和匹配 rdma-core；PF 不应解绑到 vfio-pci |
| Intel 82599/X520、X540/X550 | ixgbe | 通常使用 vfio-pci 等用户态设备访问方式；以具体 PMD 文档为准 |
| Intel X710/XL710、E810 | i40e、ice | PF/VF PMD、representor 和 flow offload 支持分别核对 |
| Broadcom NetXtreme-E | bnxt | 核对 PCI ID、固件、端口角色、rte_flow 支持 |

上表为系列示例，不保证所有 SKU、功能与软件组合均可用。绑定方法必须由 PMD 决定，不能套用“所有 DPDK 网卡都绑 vfio-pci”。

## 3. DPU-P5-02：构建、大页、绑核与启动

本例采用同一 NUMA 节点的 2 MiB 大页 2048 页（4 GiB）、CPU 2/3 作 PMD、CPU 1 作 DPDK lcore；这些编号必须根据 `lscpu -e`、`numactl -H` 和网卡 `numa_node` 调整。保证主机与 VM 剩余内存充足；CPU mask 不是 vCPU pinning 配置。

```bash
sudo apt-get install meson ninja-build python3-pyelftools libnuma-dev \
  libibverbs-dev librdmacm-dev rdma-core
sudo modprobe mlx5_core
sudo modprobe mlx5_ib
sudo modprobe ib_uverbs
cat "/sys/bus/pci/devices/$PF_BDF/numa_node"
numactl -H
lscpu -e
sudo mkdir -p /dev/hugepages
# 已挂载 hugetlbfs 时不重复 mount；NUMA 节点 0 仅作示例。
echo 2048 | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
sudo mount -t hugetlbfs -o pagesize=2M hugetlbfs /dev/hugepages
grep -i huge /proc/meminfo
```

确认实际分配数量与可用页数；内存碎片导致不足时在维护窗口配置启动预留后重启，不继续使用不足内存的测试环境。

```bash
cd "$LAB/src"
wget https://fast.dpdk.org/rel/dpdk-23.11.tar.xz
tar xf dpdk-23.11.tar.xz
cd dpdk-23.11
meson setup build --prefix=/opt/dpdk-23.11 -Dplatform=native
ninja -C build
sudo ninja -C build install
sudo ldconfig
```

核对构建摘要与日志中 mlx5 PMD 确实启用；安装路径按 Meson 的实际 `libdir` 设置，确保 `pkg-config` 和运行时动态链接器都能找到新库。例：

```bash
export PKG_CONFIG_PATH=/opt/dpdk-23.11/lib/x86_64-linux-gnu/pkgconfig:/opt/dpdk-23.11/lib/pkgconfig
pkg-config --modversion libdpdk
```

若实际库目录不同，调整上述路径及动态链接器配置。为 OVS 解压一份干净源码到独立构建目录，以免复用 Phase 1 的配置和对象文件：

```bash
cd "$LAB/src"
mkdir ovs-dpdk-build
tar xf openvswitch-3.3.0.tar.gz -C ovs-dpdk-build --strip-components=1
cd ovs-dpdk-build
./configure --prefix=/opt/ovs-dpdk-3.3.0 --localstatedir=/var \
  --sysconfdir=/etc --with-rundir=/var/run/openvswitch --with-dpdk=shared
make -j"$(nproc)"
sudo make install
```

先备份 OVSDB 和旧桥配置，停止测试及旧 `ovs-vswitchd`，移除实验端口的内核桥归属；OVSDB 可沿用同版本 schema，但不得并行运行两个交换进程。将后续命令 PATH 切换到 DPDK 构建：

```bash
export OVS_PREFIX=/opt/ovs-dpdk-3.3.0
export PATH="$OVS_PREFIX/bin:$OVS_PREFIX/sbin:$PATH"
sudo ovs-vsctl --no-wait set Open_vSwitch . \
  other_config:dpdk-init=true \
  other_config:dpdk-socket-mem=4096 \
  other_config:dpdk-lcore-mask=0x2 \
  other_config:pmd-cpu-mask=0xc \
  other_config:dpdk-extra="-a $PF_BDF" \
  other_config:hw-offload=false
sudo "$OVS_PREFIX/sbin/ovs-vswitchd" --pidfile --detach --log-file
sudo ovs-vsctl get Open_vSwitch . dpdk_initialized
sudo ovs-vsctl get Open_vSwitch . dpdk_version
```

`dpdk-socket-mem=4096` 仅对应单 socket/NUMA 0 示例，多 NUMA 应按实际节点配置。确认运行的是新二进制，日志无 PMD 探测或内存初始化失败。若所选版本不支持某配置项，依据该版本 man page 调整并记录，不忽略报错。

## 4. DPU-P5-03：设备归属与两个 VF VM

| 对象 | 宿主机驱动/接口类型 | 用途 |
| --- | --- | --- |
| CX5 PF | mlx5_core，保留 RDMA 相关依赖 | mlx5 PMD 探测与 eSwitch 管理 |
| VF0/VF1 PCI 功能 | 宿主机 vfio-pci | QEMU 直通 |
| 客户机 VF | 客户机 mlx5_core | Linux 协议栈和 netperf |
| VF representor | OVS `type=dpdk`，mlx5 PMD | 软件收发及 rte_flow 卸载入口 |

沿用 Phase 1 创建 SR-IOV 和 switchdev、Phase 2 直通方法；已经创建的 VF 不重复创建。旧内核桥不能继续持有这些 representor。添加 DPDK 桥及端口：

```bash
sudo ovs-vsctl add-br br-dpdk -- set Bridge br-dpdk \
  datapath_type=netdev fail_mode=secure
sudo ovs-vsctl add-port br-dpdk dpdk-rep0 -- \
  set Interface dpdk-rep0 type=dpdk ofport_request=1 \
  options:dpdk-devargs="$PF_BDF,representor=[0]" options:n_rxq=2
sudo ovs-vsctl add-port br-dpdk dpdk-rep1 -- \
  set Interface dpdk-rep1 type=dpdk ofport_request=2 \
  options:dpdk-devargs="$PF_BDF,representor=[1]" options:n_rxq=2
sudo ovs-vsctl --columns=name,type,ofport,error,options list Interface
sudo ovs-ofctl add-flow br-dpdk 'in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-dpdk 'in_port=2,actions=output:1'
sudo ovs-appctl dpif-netdev/pmd-rxq-show
sudo ovs-appctl dpif-netdev/pmd-stats-show
```

`representor=[0]`/`[1]` 为单 PF CX5 示例。多 PF、不同 DPDK 版本可能使用 `pf0vf0` 等语法；必须依据该版本 mlx5 文档及 probe 日志核对实际映射，确认两个端口不是同一个设备。需要时设置 `mtu_request=1600`，并保证客户机及所有路径一致。若旧内核实验使用更小 MTU，也可统一回退后重跑可比基线。

启动两个 VF VM，先双向 ping，再运行 netperf。VF 直通模型不使用 TAP 或 vhost-user。若额外比较 virtio/vhost-user，应另建实验组，设置共享内存与 vhost-user 端口，不能冒充 VF 直通组。

## 5. DPU-P5-04：用户态软件转发与硬件卸载

先在 `hw-offload=false` 下完成软件 PMD 基线；再切换为 `true` 并重启 DPDK 构建的 `ovs-vswitchd`。两组保持 hugepage、PMD 核心、RX 队列、NUMA、VM 与 netperf 参数不变。

```bash
sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
sudo ovs-appctl -t ovs-vswitchd exit
sudo "$OVS_PREFIX/sbin/ovs-vswitchd" --pidfile --detach --log-file
sudo ovs-appctl dpctl/dump-flows -m
sudo ovs-appctl dpctl/dump-flows type=offloaded
sudo ovs-appctl dpif-netdev/pmd-stats-show
sudo ovs-appctl dpif-netdev/pmd-rxq-show
```

本路径通过 DPDK `rte_flow` 而不是 Linux TC flower 下发硬件规则。`tc filter` 为空不构成 DPDK 卸载失败证据；应根据 OVS 卸载流标记、五元组计数、mlx5/端口硬件计数及日志判断。日志中的 `rte_flow` 创建失败、unsupported action 或资源耗尽必须记录为失败/部分卸载，不能仅凭开关值下结论。

执行 Phase 3 完整矩阵并出报告。使用四种明确标签区分：内核软件、内核 TC 硬件、DPDK 软件、DPDK rte_flow 硬件。跨后端比较需声明队列/CPU 分配是否相同，无法完全一致的配置列为限制。

PMD 可能在低流量甚至卸载后继续忙轮询，CPU 利用率不一定下降；同时记录 PMD cycles、包数、空轮询和吞吐。没有功耗实测不能据此断言更节能。
