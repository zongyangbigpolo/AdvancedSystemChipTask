# DPU Phase 1：SR-IOV、OVS 与 namespace

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P1-01 SR-IOV 场景与网卡调研 | 区分 PF、VF、representor 和适用场景 | 查型号手册、PCI ID、驱动及特性矩阵 | CX5；其他系列作资料对照 | 按具体 SKU 和驱动核对，避免将系列名称等同于功能保证 |
| [ ] | DPU-P1-02 CX5 启用 SR-IOV | 创建可分配的 VF | BIOS、固件、sysfs、IOMMU 检查 | 支持 IOMMU 的主机与 CX5 | 同时检查平台和设备，避免仅创建 VF 而无法直通 |
| [ ] | DPU-P1-03 源码安装并启动 OVS | 建立可追溯的软件交换基线 | 固定源码版本、编译、初始化 OVSDB、启动守护进程 | 单节点服务器 | 独立安装前缀，避免与发行版 OVS 混用 |
| [ ] | DPU-P1-04 VF 分配 namespace 并接入 OVS | 建立受 OVS 控制的 VF 数据路径 | switchdev、VF netdev 移入 namespace、representor 加桥 | 一张 CX5、两个 VF | VF 留给端点，representor 留在宿主机承担交换控制 |
| [ ] | DPU-P1-05 两个 namespace 互通 | 检查地址、ARP、双向转发 | 静态 IPv4、双向 ping、流表及计数检查 | 同上 | 先完成最小二层闭环，再引入虚拟机和隧道 |

## 2. DPU-P1-01：原理与支持系列

SR-IOV 将同一 PCIe 设备暴露为一个或多个 PF 及多个 VF。PF 负责资源管理，VF 提供可独立分配的 PCIe 功能。适用场景包括云虚拟机高吞吐网络、NFV、容器专用 VF 和低延迟网络；限制包括设备资源配额、迁移约束、硬件依赖及可观测性变化。

| 系列示例 | SR-IOV 调研重点 | 与本实验的关系 |
| --- | --- | --- |
| NVIDIA / Mellanox ConnectX-4/4 Lx、5、6、7；BlueField-2/3 | 具体型号、固件、VF 上限、switchdev 与卸载动作支持 | CX5 为本阶段主线；其他型号不能默认支持相同隧道动作 |
| Intel 82599、X540/X550、X710/XL710、E810 | 对应 ixgbe/i40e/ice 驱动与 VF 驱动；交换与卸载能力因代际不同 | SR-IOV 支持不等于支持 CX5 的 representor 和配置方式 |
| Broadcom NetXtreme-E 等 | bnxt 驱动、SKU、固件、VF 与 representor 特性 | 仅作可选平台；需重新设计驱动与卸载验证步骤 |

核查入口：

```bash
lspci -nnk
ethtool -i "$PF"
cat "/sys/class/net/$PF/device/sriov_totalvfs"
devlink dev info "pci/$PF_BDF"
ip -d link show "$PF"
```

`sriov_totalvfs` 不存在时，应核对型号、驱动和固件，而不是直接写入 `sriov_numvfs`。VF 最大值还受 BIOS、固件和资源分配影响。

## 3. DPU-P1-02：启用 SR-IOV

1. BIOS/UEFI 开启 CPU 虚拟化、IOMMU、SR-IOV；需要时开启 Above 4G Decoding。保存原设置。
2. 通过发行版启动加载器启用 IOMMU：Intel 常用 `intel_iommu=on iommu=pt`，AMD 按平台使用 `amd_iommu=on iommu=pt`。更新启动配置并在维护窗口重启。
3. 检查 `dmesg` 中 DMAR/IOMMU 初始化信息及 `/sys/kernel/iommu_groups/`；出现错误须先解决。
4. 使用已安装且适配固件的 NVIDIA MFT 查询，再按需修改：

```bash
sudo mlxconfig -d "$PF_BDF" q
# 仅在查询确认需要变更、所有相关业务停止后执行。
sudo mlxconfig -d "$PF_BDF" set SRIOV_EN=1 NUM_OF_VFS=2
```

部分设备以其他设备路径访问 MFT；以 `mst status` 和对应产品手册为准。固件设置可能要求主机重启或冷启动，不能以命令返回成功代替生效检查。

创建两个 VF 前确认该 PF 没有正在使用的 VF。已有 VF 时先记录、关停持有者并解除分配，不能直接清零。

```bash
cat "/sys/class/net/$PF/device/sriov_numvfs"
echo 2 | sudo tee "/sys/class/net/$PF/device/sriov_numvfs"
ls -l "/sys/class/net/$PF/device"/virtfn*
ip link show "$PF"
readlink -f "/sys/class/net/$PF/device/virtfn0"
readlink -f "/sys/class/net/$PF/device/virtfn1"
```

根据 `virtfn0/1` 真实路径重新设置 `VF0_BDF`、`VF1_BDF`，并通过 `/sys/bus/pci/devices/<BDF>/net/` 查 VF netdev。不能假定 VF PCI 地址连续。

## 4. DPU-P1-03：源码安装并启动 OVS

以下使用独立前缀。已有 OVS 服务时，先确认没有其他业务依赖，再停止该实例；不允许两个 `ovs-vswitchd` 同时管理实验端口。后续涉及 `sudo ovs-*` 的命令须先确认 sudo 使用相同前缀的工具；可将命令名直接替换为 `$OVS_PREFIX/bin/ovs-vsctl`、`$OVS_PREFIX/bin/ovs-ofctl` 或 `$OVS_PREFIX/bin/ovs-appctl`，避免 sudo 的 secure_path 选中发行版旧版本。

```bash
sudo apt-get update
sudo apt-get install build-essential autoconf automake libtool \
  pkg-config python3 libssl-dev libcap-ng-dev wget \
  iproute2 ethtool pciutils sysstat numactl tcpdump
cd "$LAB/src"
wget https://www.openvswitch.org/releases/openvswitch-3.3.0.tar.gz
tar xf openvswitch-3.3.0.tar.gz
cd openvswitch-3.3.0
./configure --prefix="$OVS_PREFIX" --localstatedir=/var \
  --sysconfdir=/etc --with-rundir=/var/run/openvswitch
make -j"$(nproc)"
sudo make install
sudo modprobe openvswitch
sudo mkdir -p /etc/openvswitch /var/run/openvswitch /var/log/openvswitch
```

下载文件须按上游发布信息核对散列或签名，并记录散列。此处使用内核已有的 OVS 模块，不额外编译来源不同的模块。首次安装且 `/etc/openvswitch/conf.db` 尚不存在时：

```bash
sudo "$OVS_PREFIX/bin/ovsdb-tool" create /etc/openvswitch/conf.db \
  "$OVS_PREFIX/share/openvswitch/vswitch.ovsschema"
```

已有数据库不得覆盖；升级时按 OVS 文档备份与转换。启动：

```bash
sudo "$OVS_PREFIX/sbin/ovsdb-server" /etc/openvswitch/conf.db \
  --remote=punix:/var/run/openvswitch/db.sock \
  --pidfile --detach --log-file
sudo "$OVS_PREFIX/bin/ovs-vsctl" --no-wait init
sudo "$OVS_PREFIX/sbin/ovs-vswitchd" --pidfile --detach --log-file
ovs-vsctl --version
ovs-vswitchd --version
sudo ovs-vsctl show
sudo ovs-appctl -t ovs-vswitchd version
```

若命令通过 `sudo` 执行时 PATH 不包含安装前缀，使用完整路径。检查 OVSDB socket、两个进程和日志；启动失败时保留错误，不继续创建端口。

## 5. DPU-P1-04：switchdev、representor 与 namespace

切换模式前停止所有 VF 使用者，并确认 VF 当前绑定 `mlx5_core`。部分驱动要求先解绑 VF：

```bash
echo "$VF0_BDF" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
echo "$VF1_BDF" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
sudo devlink dev eswitch set "pci/$PF_BDF" mode switchdev
echo "$VF0_BDF" | sudo tee /sys/bus/pci/drivers/mlx5_core/bind
echo "$VF1_BDF" | sudo tee /sys/bus/pci/drivers/mlx5_core/bind
sudo devlink dev eswitch show "pci/$PF_BDF"
devlink port show
ip -d link show
```

若驱动规定不同的切换顺序，按该版本文档执行。切换后重新确认接口名；通过 `devlink port show` 的 `flavour pcivf`、`pfnum`、`vfnum` 和 `phys_switch_id/phys_port_name` 建立 PF、VF PCI 地址与 representor 的映射。

```bash
sudo ip link set "$PF" up
sudo ip link set "$PF" vf 0 mac 02:00:00:00:01:01
sudo ip link set "$PF" vf 1 mac 02:00:00:00:01:02
sudo ip netns add ns-a
sudo ip netns add ns-b
sudo ip link set "$VF0_NET" netns ns-a
sudo ip link set "$VF1_NET" netns ns-b
sudo ip -n ns-a link set "$VF0_NET" name eth0
sudo ip -n ns-b link set "$VF1_NET" name eth0
sudo ip -n ns-a link set lo up
sudo ip -n ns-b link set lo up
sudo ip -n ns-a addr add 192.0.2.11/24 dev eth0
sudo ip -n ns-b addr add 192.0.2.12/24 dev eth0
sudo ip -n ns-a link set eth0 up
sudo ip -n ns-b link set eth0 up
sudo ip link set "$REP0" up
sudo ip link set "$REP1" up
sudo ovs-vsctl add-br br-sriov -- set Bridge br-sriov fail_mode=secure
sudo ovs-vsctl add-port br-sriov "$REP0" -- set Interface "$REP0" ofport_request=1
sudo ovs-vsctl add-port br-sriov "$REP1" -- set Interface "$REP1" ofport_request=2
sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=false
```

`hw-offload` 的变更按版本要求重启 `ovs-vswitchd` 后生效，重启方法见 Phase 3。桥为本实验专用，确认实际 `ofport` 为 1、2 且 `error` 为空后安装双向规则：

```bash
sudo ovs-vsctl --columns=name,ofport,error list Interface
sudo ovs-ofctl add-flow br-sriov 'priority=100,in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-sriov 'priority=100,in_port=2,actions=output:1'
```

这里使用显式转发而不是依赖未知学习状态。VF netdev 被移动到 namespace，representor 不移动；不能将两者都加入 OVS。同机实验无需把物理上联端口接入该桥。

## 6. DPU-P1-05：双向连通与故障定位

```bash
sudo ip netns exec ns-a ping -c 10 192.0.2.12
sudo ip netns exec ns-b ping -c 10 192.0.2.11
sudo ip -n ns-a neigh show
sudo ip -n ns-b neigh show
sudo ovs-ofctl dump-flows br-sriov
sudo ovs-appctl dpctl/dump-flows -m
```

判定标准为双向 ping 无丢包、邻居解析正确、对应规则计数增长。失败时依次检查链路状态、VF MAC、地址掩码、representor 映射、端口错误、OpenFlow 规则和局部防火墙策略。仅为实验地址放行必要流量，不全局关闭防火墙。软件路径可在 representor 抓包；卸载路径中抓不到全部数据包不代表不通。

阶段产物：SR-IOV 支持对照、设备映射表、源码版本/构建记录、OVS 配置、双向 ping 日志。尚未执行时不填写成功结论。
