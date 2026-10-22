# DPU 方向第一阶段：虚拟化网络与硬件卸载

## 1. 范围与实验约定

本阶段包含五个子阶段，依次覆盖同机网络、虚拟机网络、性能对照、跨节点 VXLAN、OVS-DPDK。各子阶段独立编号，任务清单中的方框仅在操作记录与原始数据齐备后勾选。

ConnectX-5（CX5）是具备嵌入式交换与流表卸载能力的网卡，不等同于带独立 Arm 处理器的 BlueField DPU。本阶段以 CX5 学习 DPU 数据面所涉及的技术，不包含在 DPU Arm 操作系统上部署服务。若改用 BlueField，须另行记录 NIC/DPU 模式、主机与 Arm 侧的设备归属，不能直接照搬 PCI 地址及端口拓扑。

**执行边界：**以下均为方法和命令模板，未附带实测结果。没有 CX5、第二台服务器或对应驱动能力时，该项记录为“待执行”或“受硬件限制未执行”，不以软件模拟结果替代硬件卸载结果。

### 1.1 硬件与软件基线

| 项目 | 基线及用途 | 选择依据 |
| --- | --- | --- |
| 计算节点 | 两台 x86_64 Linux 服务器；支持 VT-x/AMD-V、VT-d/AMD-Vi；建议每台至少 8 核、32 GiB 内存 | 同时容纳两台虚拟机、OVS、流量进程及独立监控核 |
| 数据网卡 | 每节点一张支持 switchdev 的 CX5 Ethernet 网卡；匹配速率的线缆、模块及交换机 | 提供 SR-IOV、representor、eSwitch 和硬件流表 |
| 管理网卡 | 与实验 PF 分离的管理接口，另配带外管理 | 切换 switchdev、重绑 VF 或重启时避免丢失管理通路 |
| 系统 | 示例采用 Ubuntu 22.04 LTS；记录内核、iproute2、ethtool、QEMU 具体版本 | 提供可复现的 Linux 命令环境，不要求替换已有合规发行版 |
| OVS / DPDK | 一组固定版本，例如 OVS 3.3.0 + DPDK 23.11；按所选 OVS 分支兼容表核对 | 不能任意拼接两个项目的最新版；示例版本用于隔离实验，部署时需评估维护与安全更新 |
| 驱动与固件 | 与网卡型号、内核匹配的固件及 mlx5 驱动；内核自带驱动或厂商驱动选择其一 | 混装不同来源的内核模块、rdma-core 和用户态库容易导致 ABI 不兼容 |
| 虚拟机 | 每台 2～4 vCPU、4 GiB 内存；独立 qcow2 写入层 | 隔离磁盘状态；固定 vCPU 和 NUMA 位置以控制变量 |

系统安装、内核参数及网卡固件变更由实验环境维护流程执行。命令中的 PCI 地址、接口名、CPU 编号、路径必须先替换为实际值。禁止将管理接口作为实验 PF；禁止对未知 IOMMU 组执行解绑。

### 1.2 拓扑与参数

同机拓扑：

```text
namespace-a / VM-a -- VF0 -- rep0 \
                                 OVS -- eSwitch / 数据面
namespace-b / VM-b -- VF1 -- rep1 /
```

跨节点拓扑：

```text
VM-a -- VF0 -- rep0 -- OVS-A -- VXLAN/VNI 100 -- OVS-B -- rep0 -- VF0 -- VM-b
                                物理 underlay 网络
```

每次实验先建立参数记录，再在对应节点设置变量。例如：

```bash
export PF=enp65s0f0
export PF_BDF=0000:41:00.0
export VF0_BDF=0000:41:00.2
export VF1_BDF=0000:41:00.3
export REP0=enp65s0f0_0
export REP1=enp65s0f0_1
export VF0_NET=enp65s0f0v0
export VF1_NET=enp65s0f0v1
export LAB=$HOME/dpu-lab
export OVS_PREFIX=/opt/ovs-3.3.0
export PATH="$OVS_PREFIX/bin:$OVS_PREFIX/sbin:$PATH"
mkdir -p "$LAB"/{src,images,results}
```

接口名只作示例；`REP0` 必须与 `VF0_BDF` 对应，不能根据名称后缀猜测。命令默认在有相应权限的实验主机运行；标注“客户机”的命令只在客户机内运行。重开终端需重新加载参数。`/opt/ovs-3.3.0` 的安装、运行目录及日志由实验管理员授权创建，文档不要求关闭系统安全机制。

### 1.3 统一记录与验收规则

记录主机型号、CPU/NUMA、内存、PCIe 链路、网卡序列/型号、固件、驱动、内核、软件 tag/commit、端口速率、MTU、队列数、CPU 亲和性、流规则、命令、开始时间及返回码。测量前保存配置，改变一个变量后重新检查实际生效值。

“配置了 `hw-offload=true`”不等于“流已经卸载”；必须同时具有流表卸载标记、命中计数增长及端口计数等证据。性能差异可以为零或负值，不能预设硬件卸载一定提高吞吐。

## 2. Phase 1.1：SR-IOV、OVS 与 namespace

### 2.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P1.1-01 SR-IOV 场景与网卡调研 | 区分 PF、VF、representor 和适用场景 | 查型号手册、PCI ID、驱动及特性矩阵 | CX5；其他系列作资料对照 | 按具体 SKU 和驱动核对，避免将系列名称等同于功能保证 |
| [ ] | DPU-P1.1-02 CX5 启用 SR-IOV | 创建可分配的 VF | BIOS、固件、sysfs、IOMMU 检查 | 支持 IOMMU 的主机与 CX5 | 同时检查平台和设备，避免仅创建 VF 而无法直通 |
| [ ] | DPU-P1.1-03 源码安装并启动 OVS | 建立可追溯的软件交换基线 | 固定源码版本、编译、初始化 OVSDB、启动守护进程 | 单节点服务器 | 独立安装前缀，避免与发行版 OVS 混用 |
| [ ] | DPU-P1.1-04 VF 分配 namespace 并接入 OVS | 建立受 OVS 控制的 VF 数据路径 | switchdev、VF netdev 移入 namespace、representor 加桥 | 一张 CX5、两个 VF | VF 留给端点，representor 留在宿主机承担交换控制 |
| [ ] | DPU-P1.1-05 两个 namespace 互通 | 检查地址、ARP、双向转发 | 静态 IPv4、双向 ping、流表及计数检查 | 同上 | 先完成最小二层闭环，再引入虚拟机和隧道 |

### 2.2 DPU-P1.1-01：原理与支持系列

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

### 2.3 DPU-P1.1-02：启用 SR-IOV

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

### 2.4 DPU-P1.1-03：源码安装并启动 OVS

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

### 2.5 DPU-P1.1-04：switchdev、representor 与 namespace

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

`hw-offload` 的变更按版本要求重启 `ovs-vswitchd` 后生效，重启方法见Phase 1.3。桥为本实验专用，确认实际 `ofport` 为 1、2 且 `error` 为空后安装双向规则：

```bash
sudo ovs-vsctl --columns=name,ofport,error list Interface
sudo ovs-ofctl add-flow br-sriov 'priority=100,in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-sriov 'priority=100,in_port=2,actions=output:1'
```

这里使用显式转发而不是依赖未知学习状态。VF netdev 被移动到 namespace，representor 不移动；不能将两者都加入 OVS。同机实验无需把物理上联端口接入该桥。

### 2.6 DPU-P1.1-05：双向连通与故障定位

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

## 3. Phase 1.2：虚拟化与虚拟机镜像

### 3.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P1.2-01 虚拟化方案比较 | 明确 VMM、全虚拟化与半虚拟化的边界 | 比较 VMware、Xen、QEMU-KVM、容器 | 支持虚拟化的服务器 | 同时比较隔离、设备支持、迁移和运维成本，不只比较吞吐 |
| [ ] | DPU-P1.2-02 制作 netperf 基础镜像 | 固定客户机系统与发流工具 | 安装系统、编译 netperf、关机封装、创建写入层 | 宿主机磁盘及构建 VM | 共用只读基镜像，避免两台 VM 写同一 qcow2 |
| [ ] | DPU-P1.2-03 TAP/virtio 虚拟机互通 | 建立可观测的软件虚拟网络基线 | QEMU-KVM + TAP + virtio-net + OVS | 单节点、两台 VM | 先检查镜像与地址配置，避免直通问题与镜像问题混淆 |
| [ ] | DPU-P1.2-04 VF 直通及虚拟机互通 | 建立Phase 1.3 至 Phase 1.5 所需 VF 网络 | IOMMU、vfio-pci、QEMU vfio-pci、representor 交换 | CX5、独立 IOMMU 组的两个 VF | 端点使用 VF，宿主机仍通过 representor 控制转发 |

### 3.2 DPU-P1.2-01：虚拟化方式对比

| 方式 | 结构与优点 | 局限 | 适用场景 |
| --- | --- | --- | --- |
| VMware ESXi | 裸机 Hypervisor，集中管理、HA、成熟的商业支持与迁移工具 | 许可和生态成本；硬件兼容清单约束；直通影响迁移能力 | 企业生产虚拟化 |
| VMware Workstation/Fusion | 宿主型桌面虚拟化，便于开发调试 | 不等同于 ESXi；宿主资源竞争，设备直通能力受平台限制 | 桌面实验，不作为本阶段 CX5 卸载基线 |
| Xen | 裸机 Hypervisor，Dom0 管理；支持 PV、HVM、PVH | 管理域及驱动模型增加运维复杂度；兼容性需核对 | 云平台、隔离域研究 |
| QEMU-KVM | KVM 提供内核 CPU 虚拟化，QEMU 提供设备模型，virtio 提供半虚拟化 I/O；开源且便于追踪数据路径 | 需管理镜像、网络、NUMA、IOMMU；直通仍受设备迁移限制 | Linux 网络与设备直通实验 |
| Linux 容器/namespace | 共用宿主内核，启动快，资源开销小 | 不是完整硬件虚拟机；内核隔离边界和驱动环境不同 | Phase 1.1 的最小网络功能验证 |

QEMU 可以不使用 KVM 进行软件模拟，但该模式的 CPU 开销不适合作为本实验性能基线。VF 直通不保证热迁移；必须核对具体设备与管理栈支持。

### 3.3 DPU-P1.2-02：制作含 netperf 的镜像

安装 QEMU/KVM、镜像工具及 ISO 制作依赖：

```bash
sudo apt-get install qemu-system-x86 qemu-utils ovmf
test -c /dev/kvm
qemu-img create -f qcow2 "$LAB/images/base.qcow2" 20G
```

从发行版官方渠道取得服务器安装 ISO 并验证校验值，在构建 VM 中完成安装。可用图形控制台或串口安装；ISO 必须位于下列实际路径：

```bash
qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 2 -m 4096 \
  -drive file="$LAB/images/base.qcow2",format=qcow2,if=virtio \
  -cdrom "$LAB/images/ubuntu-server.iso" -boot d \
  -nic user,model=virtio-net-pci
```

客户机内安装网络工具，源码构建 netperf：

```bash
sudo apt-get update
sudo apt-get install build-essential autoconf automake libtool git \
  iproute2 ethtool iputils-ping sysstat tcpdump openssh-server
git clone https://github.com/HewlettPackard/netperf.git
cd netperf
git checkout netperf-2.7.0
./autogen.sh
./configure --enable-demo
make -j"$(nproc)"
sudo make install
netperf -V
netserver -V
```

若该发行版使用其他维护分支，固定并记录实际 commit、补丁和编译参数。确保 initramfs 包含 virtio 磁盘驱动，客户机内核具备 `mlx5_core` VF 驱动。数据接口不配置默认路由；另用独立管理接口安装软件。串口启动需要客户机配置 `console=ttyS0` 和对应串口登录服务。

封装前清除构建期间的临时密钥和持久化网络身份；使用 cloud-init 或发行版通用化流程在首次启动生成各自的 machine-id、SSH host key 与主机名，不将固定凭据打包。关机后：

```bash
qemu-img check "$LAB/images/base.qcow2"
sha256sum "$LAB/images/base.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$LAB/images/base.qcow2" "$LAB/images/vm-a.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$LAB/images/base.qcow2" "$LAB/images/vm-b.qcow2"
```

基镜像生成后保持不变。交付镜像时，要么连同 backing chain、相对路径和清单一起打包，要么在 VM 关机后用 `qemu-img convert -O qcow2` 导出各自的独立镜像；不能仅复制依赖 backing file 的写入层。清单包含系统、内核、netperf commit、工具版本、散列和启动参数。

### 3.4 DPU-P1.2-03：TAP 与 virtio 基线

使用独立桥，避免和 VF 路径混合：

```bash
sudo ip tuntap add dev tap-a mode tap user "$(id -un)"
sudo ip tuntap add dev tap-b mode tap user "$(id -un)"
sudo ip link set tap-a up
sudo ip link set tap-b up
sudo ovs-vsctl add-br br-tap -- set Bridge br-tap fail_mode=secure
sudo ovs-vsctl add-port br-tap tap-a -- set Interface tap-a ofport_request=1
sudo ovs-vsctl add-port br-tap tap-b -- set Interface tap-b ofport_request=2
sudo ovs-ofctl add-flow br-tap 'in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-tap 'in_port=2,actions=output:1'
```

分别在两个终端启动。若当前账户不能访问 `/dev/kvm` 或 TAP，使用管理员授权的权限配置，不放宽设备权限至所有用户。

```bash
qemu-system-x86_64 -name vm-a -enable-kvm -machine q35 -cpu host \
  -smp 2 -m 4096 -nographic \
  -drive file="$LAB/images/vm-a.qcow2",format=qcow2,if=virtio \
  -netdev tap,id=data,ifname=tap-a,script=no,downscript=no \
  -device virtio-net-pci,netdev=data,mac=02:00:00:00:02:01
```

VM-b 使用 `vm-b.qcow2`、`tap-b`、名称 `vm-b` 和 MAC `02:00:00:00:02:02`。客户机通过 `ip -br link` 按 MAC 找到数据接口；分别配置 `192.0.2.11/24`、`192.0.2.12/24`，开启接口后双向 ping。串口未配置时改用图形控制台，不能将无串口输出误判为 KVM 故障。

### 3.5 DPU-P1.2-04：VF 直通

先关闭 TAP 模式 VM。退出 namespace 中的所有进程，将两个 VF netdev 移回宿主机，再删除空 namespace：

```bash
sudo ip netns exec ns-a ip link set eth0 netns 1
sudo ip netns exec ns-b ip link set eth0 netns 1
sudo ip netns del ns-a
sudo ip netns del ns-b
sudo modprobe vfio-pci
readlink -f "/sys/bus/pci/devices/$VF0_BDF/iommu_group"
readlink -f "/sys/bus/pci/devices/$VF1_BDF/iommu_group"
```

列出这两个组内的 `devices/`，核对所有成员。组内若含管理网卡、存储设备或其他业务设备，停止本项并调整插槽/平台；不使用 ACS override 绕过隔离问题。两个 VF 若位于同一不可拆分组，也不能分别交给两台 VM。

每个 VF 使用精确 BDF 绑定，不按厂商设备 ID 批量绑定：

```bash
echo vfio-pci | sudo tee "/sys/bus/pci/devices/$VF0_BDF/driver_override"
echo "$VF0_BDF" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
echo "$VF0_BDF" | sudo tee /sys/bus/pci/drivers_probe
echo vfio-pci | sudo tee "/sys/bus/pci/devices/$VF1_BDF/driver_override"
echo "$VF1_BDF" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
echo "$VF1_BDF" | sudo tee /sys/bus/pci/drivers_probe
lspci -nnk -s "$VF0_BDF"
lspci -nnk -s "$VF1_BDF"
```

保持宿主机 PF 和 representor 由 mlx5 驱动管理，保持 `br-sriov` 及双向规则。启动 VF 模式 VM-a：

```bash
sudo qemu-system-x86_64 -name vm-a-vf -enable-kvm -machine q35 -cpu host \
  -smp 2 -m 4096 -nographic -nic none \
  -drive file="$LAB/images/vm-a.qcow2",format=qcow2,if=virtio \
  -device vfio-pci,host="$VF0_BDF"
```

VM-b 使用独立镜像、名称和 `VF1_BDF`。不要同时启动使用同一镜像或同一 VF 的其他 QEMU 进程。客户机根据 PCI 驱动与 MAC 识别 VF，加载 `mlx5_core`，配置上述两个数据 IP，双向 ping，并检查宿主机 representor 流量计数。VF 直通不是“把 representor 直通给 VM”。

阶段产物：方案比较、独立镜像及清单、TAP 和 VF 两组启动命令、IOMMU 分组记录、两种路径的互通日志。

## 4. Phase 1.3：VF 直通性能与分段聚合卸载

### 4.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P1.3-01 建立测试矩阵 | 统一报文、并发与测量口径 | 固定 TCP/UDP、128/256/512/1500 B、1/4/8 并发 | 单节点 CX5、两台 VF VM | 分清应用消息长度和线上帧长，避免错误比较 |
| [ ] | DPU-P1.3-02 OVS 软件与硬件转发对照 | 测量 eSwitch 流表卸载影响 | 同一拓扑切换 hw-offload，收集流表和 CPU | 同上 | 拓扑、规则、CPU 和客户机卸载状态保持一致 |
| [ ] | DPU-P1.3-03 TSO/LRO/GRO/GSO 对照 | 区分分段聚合与交换卸载收益 | 客户机和相关宿主接口检查 ethtool，分组启停 | 支持相应特性的 VF/驱动 | 不把分段聚合统称为完整 TOE |
| [ ] | DPU-P1.3-04 专业方向分析 | 定位小包、队列、CPU 或硬件瓶颈 | 对照 pps、吞吐、丢包、CPU、NUMA 与流命中 | 同上 | 用观测结果解释路径开销，而非预设结论 |

### 4.2 DPU-P1.3-01：长度、并发与结果口径

| 维度 | 取值 |
| --- | --- |
| 协议/测试 | `TCP_STREAM`、`UDP_STREAM`；延迟单独增加 `TCP_RR`/`UDP_RR`，不从 STREAM 推算 |
| 应用发送长度 | 128、256、512、1500 字节；TCP 为每次发送长度，UDP 为数据报有效载荷 |
| 并发 | 1、4、8 个 netperf 进程，称为并发流；不是一个 netperf 进程中的多线程 |
| OVS 卸载 | 关闭、开启；每组都确认实际路径 |
| 分段聚合配置 | 全关、可支持项全开；再按需逐项对照 |
| 时间/重复 | 每条流预热 10 秒，正式 60 秒，每格至少 3 次；轮换 A/B 顺序减小热状态偏差 |
| 方向 | A→B、B→A 分别测量；双向同时发送另列，不与单向混合 |

基础全因子矩阵为 `2 × 4 × 3 × 2 × 2 = 96` 格，每方向至少 288 次重复；单项卸载诊断与预热额外计时。顺序执行已约需数小时，须预留配置切换、失败重试和分析时间。

**1500 字节的定义：**1500 B UDP payload 加 IPv4/UDP 头为 1528 B，超过 MTU 1500。若测无分片数据报，同机可将 VM、VF、representor 及相关路径 MTU 设为 1600，Phase 1.4 将 underlay 至少设为 1650（示例 1700）并核对交换机支持。若硬件只能 MTU 1500，保留该测试但明确记录 IP 分片及重组，不能称为“1500 B 以太网帧”。TCP 的 `-m` 不能保证 TCP segment 或线速帧长；若要求固定线速帧长，另加 TRex/MoonGen/testpmd 等包发生器测试，不替代 netperf 数据。

### 4.3 DPU-P1.3-02：切换 OVS 卸载与证据

在无发流、允许短暂中断时切换。以下为本文件直接启动的 OVS 实例重启方式：

```bash
sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=false
sudo ovs-appctl -t ovs-vswitchd exit
sudo "$OVS_PREFIX/sbin/ovs-vswitchd" --pidfile --detach --log-file
sudo ovs-vsctl get Open_vSwitch . other_config
```

开启组将 `false` 改为 `true`。按驱动要求为 representor/上联开启 `hw-tc-offload`，并检查实际值：

```bash
sudo ethtool -K "$REP0" hw-tc-offload on
sudo ethtool -K "$REP1" hw-tc-offload on
ethtool -k "$REP0"
ethtool -k "$REP1"
sudo ovs-appctl dpctl/dump-flows -m
sudo ovs-appctl dpctl/dump-flows type=offloaded
sudo tc -s filter show dev "$REP0" ingress
sudo tc -s filter show dev "$REP1" ingress
sudo ovs-ofctl dump-flows br-sriov
```

部分特性由 PF/驱动统一控制；不支持的 `ethtool` 命令应记录返回错误及驱动说明，不能忽略。开启组需检查与测试五元组对应的 `offloaded:yes`、TC `in_hw` 及命中计数增长；关闭组确认重启后无遗留卸载流，流量经过软件 datapath。OpenFlow 逻辑表本身不提供硬件落表的充分证据。

不要用 `tc-policy=skip_sw` 作为常规对照设置：不支持卸载的流会丢失软件回退条件，改变测试语义。硬件组出现未卸载流应标记为“部分卸载/卸载失败”，分析动作、资源和日志，不计作完整卸载组。

### 4.4 发流、监控与数据保存

在接收 VM 上启动 netserver，数据网络只允许实验对端访问控制端口和数据端口。netperf 数据连接可能使用动态端口；若需固定范围，应按所选版本参数配置或仅在隔离数据网按对端 IP 放行。

```bash
# 接收客户机
sudo netserver -L 192.0.2.12 -p 12865
```

发送客户机示例；每个测试组合创建独立目录，目录名应含 OVS 卸载、TSO 等状态、协议、长度、并发、方向和重复编号：

```bash
export PEER=192.0.2.12
export OUT=$HOME/netperf-results/kernel-sw/features-off/TCP_STREAM/128/n4/repeat1
mkdir -p "$OUT"
netperf -H "$PEER" -p 12865 -t TCP_STREAM -l 10 -- -m 128 > "$OUT/warmup.log" 2>&1
PIDS=()
for i in 1 2 3 4; do
  netperf -H "$PEER" -p 12865 -t TCP_STREAM -l 60 -- -m 128 \
    > "$OUT/flow-$i.log" 2>&1 &
  PIDS+=("$!")
done
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=1
done
test "$FAILED" -eq 0
```

此段在 Bash 中运行，启动的是有界测量进程；例中单流预热仅演示参数。正式矩阵须将预热也改为与测量相同的并发数，等待其全部完成后再正式发流。UDP 将命令中的 `TCP_STREAM` 改为 `UDP_STREAM`，并同步更新输出目录；按矩阵替换 `-m`，并发 1、8 对应实际进程数。每个进程返回值和日志都要保留；任一失败时该格标为失败，不聚合成成功结果。测反向时在 VM-a 启动服务，将对端地址改为 `192.0.2.11`。

UDP 同时记录发送端 offered load、接收端 throughput 和包数，丢包率以包数计算；不能只相加发送端结果。多流总吞吐相加接收侧同一时间窗口的吞吐；并发启动偏差需记录，严格同步时使用统一开始屏障。TCP 重传从客户机 `nstat`/`ss -ti` 和抓包辅助分析；UDP 用 netperf 接收统计及网卡丢弃计数交叉核对。

在宿主机与两个客户机的独立终端采样，文件名按实际运行编号设置：

```bash
mpstat -P ALL 1 70 > cpu.log
pidstat -t -p "$(pidof ovs-vswitchd)" 1 70 > ovs-cpu.log
```

两条命令分别启动，覆盖同一发流时间窗；客户机采集 `mpstat`，不运行没有 OVS 进程的 `pidstat` 命令。发流前后保存 `ip -s link`、`ethtool -S`、`nstat`、OVS/TC 流表。记录 vCPU、QEMU、IRQ 的 CPU 亲和性与 NUMA；监控进程不要与发流进程争用同一隔离核。初次测试保持相同默认绑核，后续 NUMA/IRQ 调整单列实验。

### 4.5 DPU-P1.3-03：分段与聚合卸载

TSO/GSO 负责发送分段，LRO/GRO 负责接收聚合，和 OVS 流表卸载是两个维度。TOE 严格指 TCP Offload Engine，完整卸载 TCP 协议栈；不能把 CX5 的 TSO、LRO、GRO、GSO 测试描述为完整 TOE 测试。

两个客户机先对实际 VF 接口保存：

```bash
ethtool -k eth0 > features-before.txt
sudo ethtool -K eth0 tso off gso off gro off lro off
ethtool -k eth0 > features-off.txt
```

`eth0` 必须替换为客户机实际数据接口名。开启组仅开启查询显示可修改且驱动支持的项：

```bash
sudo ethtool -K eth0 tso on gso on gro on
# lro 仅在非 fixed、驱动支持且拓扑允许时单独开启。
sudo ethtool -K eth0 lro on
ethtool -k eth0 > features-on.txt
```

某项为 `[fixed]` 或命令返回不支持时，记录“不可切换”，用实际状态命名该组，不写“全部开启”。如一组命令部分成功，逐项查询与设置，避免把部分状态当成完整结果。宿主机相关接口也需保存状态；若一并修改，作为明确的端到端配置组，不能偷偷改变其他变量。TSO 对 UDP 不等同于 UDP segmentation offload，不应据此推断 UDP 分段效果。

在固定 OVS 卸载状态下，以“可支持项全关”为起点，分别测试仅 GSO、仅 GRO、TSO+其必需依赖、LRO+其必需依赖；记录驱动自动调整的依赖项。一次只引入一个有效配置差异。

### 4.6 DPU-P1.3-04：分析任务与报告表

专业方向分析聚焦三个问题：小消息是否受 CPU/pps 限制；并发是否改善队列利用或只增加争用；硬件落表后软件 CPU 降低是否转化为吞吐/丢包改善。比较时说明 PCIe、NUMA、CPU 频率和网卡速率限制。

| 运行编号 | OVS 实际路径 | TSO/GSO/GRO/LRO 实际值 | 协议 | 消息 B | 流数 | 接收 Gbit/s | 接收 pps | UDP 丢包率/TCP 重传 | 主机与 VM CPU | 原始日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | 待记录 | 待记录 | — | — | — | — | — |

每组报告至少给出重复值、均值、标准差及异常原因。吞吐增益为 `(开启-关闭)/关闭×100%`，CPU 降幅为 `(关闭-开启)/关闭×100%`；分母为零时不计算。CPU 需说明“一核 100%”或“全机归一化”等口径。没有延迟测试就不报告延迟百分位；没有功耗计就不报告能效。

## 5. Phase 1.4：跨节点 VXLAN 与卸载

### 5.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P1.4-01 VXLAN 场景与封装调研 | 区分 underlay 和 overlay | 分析 VTEP、VNI、UDP 4789、封装与 MTU | 两节点、可达物理网络 | 理解二层租户网络如何跨越三层网络 |
| [ ] | DPU-P1.4-02 两节点 VF 虚拟机直连基线 | 排除物理网络和 VF 基础问题 | rep↔uplink，VM 配同一测试子网后打流 | 每节点 CX5、一个 VF、一个 VM | 先测无隧道路径，后续才可区分封装开销 |
| [ ] | DPU-P1.4-03 VXLAN 跨节点通信 | 构造 overlay 数据路径 | 两侧 OVS 配固定 VNI、local/remote IP、静态转发 | 同上，underlay MTU 足够 | 使用最小静态拓扑，减少控制面变量 |
| [ ] | DPU-P1.4-04 隧道卸载对照与报告 | 判断封装/解封装是否落硬件 | 复用Phase 1.3 矩阵、流表和物理口计数 | 支持对应动作的 CX5/固件/驱动组合 | VXLAN 互通不代表 VXLAN 已卸载，必须检查封装动作和命中 |

### 5.2 DPU-P1.4-01/02：物理网络与无隧道基线

VXLAN 常用于跨机架租户二层网络与云虚拟网络。VNI 为 24 位逻辑网络标识，VTEP 执行封装与解封装。VXLAN 本身不提供加密或身份认证，不能把它作为安全边界。

两台主机分别完成 SR-IOV、switchdev、VF 直通与 OVS 安装。A、B 各保留一个实验 VF 和对应 representor，关闭Phase 1.1 / Phase 1.2 仍占用资源的其他端点。

通过 `devlink port show` 找到各自主机的**物理上联 representor/netdev**，记为 `UPLINK`；某些 CX5 配置下即为 `$PF`。不能把数据 VF 接口当作 uplink。先使用一张专用 `br-direct`，配置 rep↔uplink 的双向流，让两台 VM 在物理二层实验网中使用 `192.0.2.11/24`、`192.0.2.12/24` 互通：

```bash
export UPLINK=enp65s0f0
sudo ovs-vsctl add-br br-direct -- set Bridge br-direct fail_mode=secure
sudo ovs-vsctl add-port br-direct "$REP0" -- set Interface "$REP0" ofport_request=1
sudo ovs-vsctl add-port br-direct "$UPLINK" -- set Interface "$UPLINK" ofport_request=2
sudo ip link set "$REP0" up
sudo ip link set "$UPLINK" up
sudo ovs-ofctl add-flow br-direct 'in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-direct 'in_port=2,actions=output:1'
```

执行前从旧桥移除这两个端口，确认没有 IP/路由依赖；一个接口不能同时属于两个桥。物理交换机为两端配置同一隔离实验 VLAN。先 ping，再按Phase 1.3 方法测无隧道基线，保存速率、丢包、CPU、端口及流表证据。

### 5.3 DPU-P1.4-03：配置 underlay 与 VXLAN

完成直连基线后停止发流，从 `br-direct` 移除实验端口。示例采用 OVS internal 端口承载 underlay IP，物理口加入 `br-underlay` 后不再保留主机 IP。该网段不得和管理网或其他路由冲突。

| 节点 | underlay / VTEP IP | VM overlay IP | VNI |
| --- | --- | --- | --- |
| A | 198.51.100.11/24 | 192.0.2.11/24 | 100 |
| B | 198.51.100.12/24 | 192.0.2.12/24 | 100 |

两节点分别设置 `LOCAL` 和 `REMOTE`。A 侧如下，B 侧交换两个 underlay 地址：

```bash
export LOCAL=198.51.100.11
export REMOTE=198.51.100.12
sudo ovs-vsctl add-br br-underlay -- set Bridge br-underlay fail_mode=secure
sudo ovs-vsctl add-port br-underlay "$UPLINK"
sudo ip link set "$UPLINK" up
sudo ovs-vsctl set Interface "$UPLINK" mtu_request=1700
sudo ovs-vsctl set Interface br-underlay mtu_request=1700
sudo ip link set br-underlay up
sudo ip addr add "$LOCAL/24" dev br-underlay
sudo ovs-ofctl add-flow br-underlay 'priority=0,actions=NORMAL'
ping -c 10 "$REMOTE"
ip route get "$REMOTE"
ip neigh show dev br-underlay
```

物理交换机端口也须支持相应 MTU；用 `ping -M do -s 1672 "$REMOTE"` 检查 1700 B IPv4 路径 MTU，失败时先排除中间 MTU、防火墙和 ICMP 策略。不允许仅调宿主机而忽略交换机限制。

```bash
sudo ovs-vsctl add-br br-overlay -- set Bridge br-overlay fail_mode=secure
sudo ovs-vsctl add-port br-overlay "$REP0" -- set Interface "$REP0" ofport_request=1
sudo ovs-vsctl set Interface "$REP0" mtu_request=1600
sudo ovs-vsctl add-port br-overlay vxlan100 -- \
  set Interface vxlan100 type=vxlan ofport_request=2 \
  options:local_ip="$LOCAL" options:remote_ip="$REMOTE" \
  options:key=100 options:dst_port=4789
sudo ovs-ofctl add-flow br-overlay 'priority=100,in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-overlay 'priority=100,in_port=2,actions=output:1'
```

客户机 VF MTU 设置为 1600，保留 overlay IP，确保 PF/硬件 vport 最大 MTU 允许。overlay 与 underlay 网段相互独立。放行仅两台 VTEP 之间的 UDP 4789 和实验所需 ICMP，保留其他防火墙策略。

验证客户机双向 ping，再在软件转发组使用：

```bash
sudo tcpdump -ni "$UPLINK" udp port 4789
sudo ovs-vsctl --columns=name,ofport,error,options list Interface
sudo ovs-appctl dpctl/dump-flows -m
```

核对外层 VTEP IP、UDP 4789、VNI 100 与内层 VM 地址。这里“出网为 VXLAN”指 VM 跨节点流量以 VXLAN 形式从物理口发出，不包含公网 NAT/Internet 出口。若题目另需 Internet 出口，应独立设计网关、路由及安全策略，不能与本项混为一谈。

### 5.4 DPU-P1.4-04：开关卸载与报告

按Phase 1.3 流程分别关闭/开启 `hw-offload` 并重启。保持 underlay、overlay、VNI、MTU、VM CPU、消息长度和客户机分段聚合配置不变，执行 TCP/UDP、四种消息长度、1/4/8 并发。

检查两端：

```bash
sudo ovs-appctl dpctl/dump-flows type=offloaded
sudo tc -s filter show dev "$REP0" ingress
sudo tc -s filter show dev "$UPLINK" ingress
sudo ethtool -S "$UPLINK"
```

卸载证据应覆盖 VM→隧道封装和隧道→VM 解封装两个方向；只有 rep↔rep 或普通 L2 动作卸载，不足以证明 VXLAN 卸载。若当前 CX5/固件/驱动不支持某动作，保留软件路径实测并列出限制，不手动添加绕过 OVS 的规则伪造卸载。

报告按Phase 1.3 表增加：节点、VTEP、VNI、underlay/overlay MTU、封装开销、分片状态、两端 CPU、封装/解封装卸载证据。分别比较“跨节点无隧道软件路径”“VXLAN 软件路径”“VXLAN 硬件路径”，不把不同拓扑的差异全部归因于卸载。硬件 TC 统计可能不含以太网头，字节计数应按同一层归一化再比较。

## 6. Phase 1.5：OVS-DPDK 与 VF 硬件卸载

### 6.1 Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P1.5-01 DPDK 原理及网卡支持调研 | 理解 PMD、轮询、hugepage 和批处理 | 查对应版本 PMD 支持表，比较内核与用户态路径 | CX5；Intel/Broadcom 作对照 | 区分“有 PMD”与“支持 OVS 硬件流表卸载” |
| [ ] | DPU-P1.5-02 构建并初始化 OVS-DPDK | 建立用户态交换环境 | DPDK 源码构建、OVS 链接、hugepage、绑核、NUMA | 有可用大页和专用核心的主机 | 固定兼容版本，隔离 PMD 与 vCPU，减少跨 NUMA 访存 |
| [ ] | DPU-P1.5-03 VF 虚拟机接入 DPDK representor | 保留 VF 直通端点并更换交换后端 | mlx5 bifurcated 驱动、representor devargs、netdev 桥 | switchdev CX5、两个 VF VM | PF 留在 mlx5_core；只将交给 VM 的 VF 绑定 vfio-pci |
| [ ] | DPU-P1.5-04 DPDK 流卸载对照与报告 | 比较用户态软件交换与硬件 eSwitch | 复用矩阵，检查 rte_flow、PMD 与卸载计数 | 支持相应 rte_flow 动作的组合 | 与内核 TC 卸载分开取证，不能用 TC 表代替 DPDK 流表 |

### 6.2 DPU-P1.5-01：使用场景与设备支持

DPDK 在用户态通过 PMD 批量收发包，配合大页、内存池和 NUMA 亲和性降低每包处理开销。适用于 NFV、高 pps 交换、流量发生器等；代价包括专用 CPU、忙轮询功耗、内存规划及驱动兼容要求。它不是普通 TCP 应用的自动加速开关，netperf 在客户机内仍使用 Linux TCP/UDP 栈。

| 系列 | 常见 PMD | 绑定与能力边界 |
| --- | --- | --- |
| ConnectX-4/4 Lx/5/6/7、BlueField-2/3 | mlx5 | bifurcated 设计依赖 mlx5_core、mlx5_ib、ib_uverbs 和匹配 rdma-core；PF 不应解绑到 vfio-pci |
| Intel 82599/X520、X540/X550 | ixgbe | 通常使用 vfio-pci 等用户态设备访问方式；以具体 PMD 文档为准 |
| Intel X710/XL710、E810 | i40e、ice | PF/VF PMD、representor 和 flow offload 支持分别核对 |
| Broadcom NetXtreme-E | bnxt | 核对 PCI ID、固件、端口角色、rte_flow 支持 |

上表为系列示例，不保证所有 SKU、功能与软件组合均可用。绑定方法必须由 PMD 决定，不能套用“所有 DPDK 网卡都绑 vfio-pci”。

### 6.3 DPU-P1.5-02：构建、大页、绑核与启动

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

若实际库目录不同，调整上述路径及动态链接器配置。为 OVS 解压一份干净源码到独立构建目录，以免复用Phase 1.1 的配置和对象文件：

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

### 6.4 DPU-P1.5-03：设备归属与两个 VF VM

| 对象 | 宿主机驱动/接口类型 | 用途 |
| --- | --- | --- |
| CX5 PF | mlx5_core，保留 RDMA 相关依赖 | mlx5 PMD 探测与 eSwitch 管理 |
| VF0/VF1 PCI 功能 | 宿主机 vfio-pci | QEMU 直通 |
| 客户机 VF | 客户机 mlx5_core | Linux 协议栈和 netperf |
| VF representor | OVS `type=dpdk`，mlx5 PMD | 软件收发及 rte_flow 卸载入口 |

沿用Phase 1.1 创建 SR-IOV 和 switchdev、Phase 1.2 直通方法；已经创建的 VF 不重复创建。旧内核桥不能继续持有这些 representor。添加 DPDK 桥及端口：

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

### 6.5 DPU-P1.5-04：用户态软件转发与硬件卸载

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

执行Phase 1.3 完整矩阵并出报告。使用四种明确标签区分：内核软件、内核 TC 硬件、DPDK 软件、DPDK rte_flow 硬件。跨后端比较需声明队列/CPU 分配是否相同，无法完全一致的配置列为限制。

PMD 可能在低流量甚至卸载后继续忙轮询，CPU 利用率不一定下降；同时记录 PMD cycles、包数、空轮询和吞吐。没有功耗实测不能据此断言更节能。

## 7. 报告结构、交付物与恢复

### 7.1 统一报告内容

每个需要报告的阶段在本文对应小节记录以下内容；较大的原始日志或镜像放实验存储，只在文档中登记路径及散列，不把磁盘镜像提交到 Git：

| 部分 | 必填内容 |
| --- | --- |
| 环境 | 硬件、固件、驱动、软件版本、NUMA/CPU、MTU、网卡队列、拓扑 |
| 操作 | 参数替换后的命令、执行节点、时间、返回值、实际状态 |
| 数据 | 每流日志、重复结果、接收吞吐、pps、丢包/重传、CPU、流表和命中证据 |
| 对照 | 同一拓扑、同一负载的卸载开/关比较，公式及统计口径 |
| 解释 | 瓶颈证据、软件回退、无法支持的特性、测量扰动 |
| 结论 | 仅依据实际数据填写；未执行项明确说明设备/能力限制 |

| 阶段 | 执行状态 | 记录/产物 |
| --- | --- | --- |
| Phase 1.1 | 待执行 | SR-IOV 调研、PF/VF/rep 映射、OVS 编译与 namespace 互通日志 |
| Phase 1.2 | 待执行 | 虚拟化对比、镜像清单与散列、TAP/VF 启动配置及互通日志 |
| Phase 1.3 | 待执行 | 同机测试矩阵、实际卸载状态、原始日志、性能报告 |
| Phase 1.4 | 待执行 | 跨节点直连与 VXLAN 配置、双向卸载证据、性能报告 |
| Phase 1.5 | 待执行 | DPDK 构建、设备归属、PMD 规划、流卸载证据、性能报告 |

### 7.2 恢复顺序

停止所有发流和 netserver；正常关闭 VM 并确认 VF 不再被 QEMU 占用；仅删除实验桥、TAP 和空 namespace。对两个实验 VF 清除 `driver_override`，从 vfio-pci 解绑后重新由 mlx5_core 探测。保存流表后停止实验交换进程，恢复原 OVS 配置与服务，不能直接覆盖仍在使用的数据库。

若需要恢复 legacy 模式，先按驱动要求解绑全部实验 VF、切换 eSwitch，再恢复原 VF 数量及绑定；将 `sriov_numvfs` 清零仅限确认所有 VF 都已释放后执行。恢复原 MAC、MTU、IP/路由、ethtool 特性、CPU/IRQ 亲和性、大页数量和固件设置。大页仍被占用时不强制回收。最后检查管理通路和非实验业务。

## 8. 名词与缩写

| 缩写/术语 | 全称 | 本阶段含义 |
| --- | --- | --- |
| DPU | Data Processing Unit | 承担网络、存储或安全数据处理的处理器/设备 |
| NIC | Network Interface Card | 网络接口卡 |
| CX5 | ConnectX-5 | 本阶段采用的网卡系列 |
| PCIe / BDF | Peripheral Component Interconnect Express / Bus:Device.Function | 设备总线及 PCI 功能地址 |
| SR-IOV | Single Root I/O Virtualization | 单根 I/O 虚拟化 |
| PF / VF | Physical Function / Virtual Function | 物理功能及虚拟功能 |
| IOMMU | Input-Output Memory Management Unit | DMA 地址转换与隔离 |
| VFIO | Virtual Function I/O | Linux 安全用户态设备访问与直通框架 |
| eSwitch / switchdev | Embedded Switch / Linux switch device model | 网卡嵌入式交换机及 Linux 交换设备控制模型 |
| representor / rep | Port Representor | 宿主机对 VF/物理端口的控制与数据面表示，不是 VF 本身 |
| OVS / OVSDB | Open vSwitch / Open vSwitch Database | 虚拟交换机及配置数据库 |
| datapath / OpenFlow | 数据转发路径 / 流控制协议 | 实际转发实现与逻辑规则，不能等同于硬件表 |
| namespace / TAP | Linux network namespace / 二层虚拟网络接口 | 轻量网络隔离与 QEMU 软件网络入口 |
| VMM / VM | Virtual Machine Monitor / Virtual Machine | 虚拟机监控器与虚拟机 |
| QEMU / KVM | Quick Emulator / Kernel-based Virtual Machine | 设备模型与 Linux CPU 虚拟化机制 |
| virtio | Virtual I/O | 半虚拟化设备接口 |
| PV / HVM / PVH | Paravirtualization / Hardware Virtual Machine / PV 与硬件虚拟化组合 | Xen 虚拟化模式 |
| HA / NFV | High Availability / Network Functions Virtualization | 高可用与网络功能虚拟化 |
| ABI | Application Binary Interface | 驱动、库与程序之间的二进制接口 |
| NUMA | Non-Uniform Memory Access | CPU、内存与设备的非均匀访问拓扑 |
| IRQ / RX / TX | Interrupt Request / Receive / Transmit | 中断请求、接收、发送 |
| TSO / GSO | TCP Segmentation Offload / Generic Segmentation Offload | TCP 硬件分段与通用软件分段 |
| LRO / GRO | Large Receive Offload / Generic Receive Offload | 接收端聚合机制，不能等同于完整 TCP 卸载 |
| TOE | TCP Offload Engine | 完整或更广泛的 TCP 协议栈硬件卸载引擎 |
| TCP / UDP | Transmission Control Protocol / User Datagram Protocol | 传输控制协议与用户数据报协议 |
| ARP / ICMP | Address Resolution Protocol / Internet Control Message Protocol | IPv4 邻居解析与控制报文 |
| MTU / MSS | Maximum Transmission Unit / Maximum Segment Size | 链路 IP 包上限与 TCP 数据段上限 |
| pps / Gbit/s | Packets Per Second / Gigabits Per Second | 包速率与比特吞吐单位 |
| RR / STREAM | Request-Response / 单向流测试 | netperf 请求响应与流吞吐模型 |
| VXLAN | Virtual Extensible LAN | 在 UDP/IP 上承载二层 overlay 的封装 |
| VTEP / VNI | VXLAN Tunnel Endpoint / VXLAN Network Identifier | 隧道端点与逻辑网络标识 |
| TC / flower | Traffic Control / flower classifier | Linux 流量控制与流分类机制 |
| DPDK / PMD | Data Plane Development Kit / Poll Mode Driver | 用户态数据面工具包与轮询模式驱动 |
| hugepage / lcore | 大页 / Logical Core | DPDK 内存页与逻辑执行核 |
| rte_flow | DPDK Flow API | PMD 的流匹配及动作接口，不保证所有动作可由硬件执行 |
| vhost-user | 用户态 vhost 协议 | QEMU virtio 与用户态交换机间的共享内存通信 |
| MFT / SKU | NVIDIA Firmware Tools / Stock Keeping Unit | 固件工具与具体硬件型号单元 |

## 9. 参考资料

以下入口用于核对功能及操作，执行时选择与实验版本对应的文档，不以 `latest` 页面代替版本兼容检查。

- [OVS 源码安装](https://docs.openvswitch.org/en/latest/intro/install/general/)
- [OVS 与 Linux TC 硬件卸载](https://docs.openvswitch.org/en/latest/howto/tc-offload/)
- [OVS-DPDK 构建](https://docs.openvswitch.org/en/latest/intro/install/dpdk/)
- [OVS-DPDK 使用方法](https://docs.openvswitch.org/en/latest/howto/dpdk/)
- [OVS / DPDK 版本兼容表](https://docs.openvswitch.org/en/latest/faq/releases/)
- [OVS 隧道](https://docs.openvswitch.org/en/latest/howto/tunneling/)
- [DPDK mlx5 PMD 与支持设备](https://doc.dpdk.org/guides/nics/mlx5.html)
- [Linux mlx5 switchdev](https://docs.kernel.org/networking/device_drivers/ethernet/mellanox/mlx5/switchdev.html)
- [Linux VFIO 与 IOMMU 组](https://docs.kernel.org/driver-api/vfio.html)
- [QEMU VFIO 设备](https://www.qemu.org/docs/master/system/devices/vfio.html)
- [netperf 源码与手册](https://github.com/HewlettPackard/netperf)
- [VXLAN RFC 7348](https://www.rfc-editor.org/rfc/rfc7348)
