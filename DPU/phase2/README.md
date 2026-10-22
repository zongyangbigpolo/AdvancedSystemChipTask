# DPU Phase 2：虚拟化与虚拟机镜像

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P2-01 虚拟化方案比较 | 明确 VMM、全虚拟化与半虚拟化的边界 | 比较 VMware、Xen、QEMU-KVM、容器 | 支持虚拟化的服务器 | 同时比较隔离、设备支持、迁移和运维成本，不只比较吞吐 |
| [ ] | DPU-P2-02 制作 netperf 基础镜像 | 固定客户机系统与发流工具 | 安装系统、编译 netperf、关机封装、创建写入层 | 宿主机磁盘及构建 VM | 共用只读基镜像，避免两台 VM 写同一 qcow2 |
| [ ] | DPU-P2-03 TAP/virtio 虚拟机互通 | 建立可观测的软件虚拟网络基线 | QEMU-KVM + TAP + virtio-net + OVS | 单节点、两台 VM | 先检查镜像与地址配置，避免直通问题与镜像问题混淆 |
| [ ] | DPU-P2-04 VF 直通及虚拟机互通 | 建立 Phase 3 至 Phase 5 所需 VF 网络 | IOMMU、vfio-pci、QEMU vfio-pci、representor 交换 | CX5、独立 IOMMU 组的两个 VF | 端点使用 VF，宿主机仍通过 representor 控制转发 |

## 2. DPU-P2-01：虚拟化方式对比

| 方式 | 结构与优点 | 局限 | 适用场景 |
| --- | --- | --- | --- |
| VMware ESXi | 裸机 Hypervisor，集中管理、HA、成熟的商业支持与迁移工具 | 许可和生态成本；硬件兼容清单约束；直通影响迁移能力 | 企业生产虚拟化 |
| VMware Workstation/Fusion | 宿主型桌面虚拟化，便于开发调试 | 不等同于 ESXi；宿主资源竞争，设备直通能力受平台限制 | 桌面实验，不作为本阶段 CX5 卸载基线 |
| Xen | 裸机 Hypervisor，Dom0 管理；支持 PV、HVM、PVH | 管理域及驱动模型增加运维复杂度；兼容性需核对 | 云平台、隔离域研究 |
| QEMU-KVM | KVM 提供内核 CPU 虚拟化，QEMU 提供设备模型，virtio 提供半虚拟化 I/O；开源且便于追踪数据路径 | 需管理镜像、网络、NUMA、IOMMU；直通仍受设备迁移限制 | Linux 网络与设备直通实验 |
| Linux 容器/namespace | 共用宿主内核，启动快，资源开销小 | 不是完整硬件虚拟机；内核隔离边界和驱动环境不同 | Phase 1 的最小网络功能验证 |

QEMU 可以不使用 KVM 进行软件模拟，但该模式的 CPU 开销不适合作为本实验性能基线。VF 直通不保证热迁移；必须核对具体设备与管理栈支持。

## 3. DPU-P2-02：制作含 netperf 的镜像

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

## 4. DPU-P2-03：TAP 与 virtio 基线

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

## 5. DPU-P2-04：VF 直通

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
