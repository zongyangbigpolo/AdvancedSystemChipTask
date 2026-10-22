# GPU Phase 2：GPU 虚拟化与镜像

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | GPU-P2-01 GPU 共享与虚拟化比较 | 区分独占、分区、时间共享和容器 | 对比 PCIe passthrough、vGPU、MIG、MPS、容器 | GPU；部分路线需特定型号与许可 | 按隔离和可调度资源选择，不把不同机制混称 SR-IOV |
| [ ] | GPU-P2-02 QEMU-KVM GPU 直通 | 在 VM 内运行真实 GPU 计算 | IOMMU、vfio-pci、QEMU/OVMF、客户机驱动 | 独立 IOMMU 组的 GPU；管理不依赖该卡 | 整卡独占直通路径清晰，适合作为虚拟化开销基线 |
| [ ] | GPU-P2-03 制作 GPU 工具镜像 | 固定客户机软件和测试程序 | 安装驱动、CUDA、样例、NCCL 工具，关机封装 | VM、镜像存储 | 避免不同 VM 的工具版本差异影响结果 |
| [ ] | GPU-P2-04 VM 计算与双 VM 通信 | 验证直通功能和后续通信基础 | VM 内运行样例；独立虚拟网卡双向 ping；可选两 VM NCCL | 两 VM；同时各用 GPU 需两张独立 GPU | 一张整卡不能同时直通两 VM；网络互通与 GPU 可用分别验证 |

## 2. GPU-P2-01：方案比较

| 方案 | 目的与优点 | 硬件/软件要求 | 限制及选择原因 |
| --- | --- | --- | --- |
| 整卡 PCIe 直通 | VM 独占真实设备，设备路径直接 | IOMMU、VFIO、适合直通的 GPU/固件和复位能力 | 一张卡只能由一个持有者使用，迁移和共享受限；本阶段主线 |
| 厂商 vGPU | 多 VM 共享，按 profile 分配资源 | 支持型号、Hypervisor、vGPU 软件和相应许可 | 不可按普通桌面驱动推导支持；具体实现不一定采用 SR-IOV |
| MIG | 支持型号上将 GPU 分割为不同计算/显存实例 | 型号、驱动、profile 支持 | 分区能力与组合有上限；MIG 不是自动将每个实例变成通用可直通 PCI VF |
| MPS | 多 CUDA 进程协作共享执行资源 | CUDA MPS 支持的设备和系统 | 不提供与独立 VM 等价的安全边界，不能代替设备隔离 |
| 容器 | 固定用户态工具与库，部署方便 | 宿主驱动、NVIDIA Container Toolkit、兼容 runtime | 共用宿主内核与 GPU 驱动；容器数量不等于硬件隔离实例数量 |

MIG、vGPU 和 MPS 为条件任务：只有型号与软件支持时才执行对应配置。变更 MIG 前停止所有 GPU 使用者，按型号文档评估复位/重启要求并记录原 profile；不在占用中的设备上试探模式切换。

## 3. GPU-P2-02：整卡直通步骤

先使用普通 virtio 磁盘与网络安装可从串口管理的 Linux VM。QEMU 镜像安装、独立写入层和 TAP 网络可参照 [DPU Phase 2](../../DPU/phase2/README.md)，GPU 实验使用独立镜像与网桥，不复用正在运行的磁盘。

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

## 4. GPU-P2-03/04：镜像与验证

客户机内安装与目标 GPU、CUDA 匹配的驱动和工具链，重复 Phase 1 的 `nvidia-smi`、`deviceQuery`、`vectorAdd`、memcheck。直通模式下客户机运行真实 GPU 驱动；宿主机该卡使用 vfio-pci，不要求同时在宿主 `nvidia-smi` 中可见。

镜像内加入固定版本 CUDA Samples、NCCL、MPI、nccl-tests、Nsight 工具；构建方法分别见 Phase 4 / Phase 5。保留源码 commit 与构建参数。清理临时凭据，按发行版通用化流程为每台 VM 生成独立 machine-id、SSH host key，关机后记录镜像散列及 `qemu-img check`。

若使用 backing file，每台 VM 创建自己的写入层，交付时导出独立 qcow2 或完整登记依赖链。镜像不包含固定 SSH 私钥，不提交到 Git；登记存储路径、散列、GPU 架构和版本清单。

第二台 VM 使用独立镜像、VARS 文件、TAP、MAC、名称及 GPU BDF。在两个客户机为数据网配置 `192.0.2.21/24`、`192.0.2.22/24`，双向 ping。使用两张 GPU 时可参照 [Phase 5 的 MPI NCCL 方法](../phase5/README.md)，将启动目标改为这两台 VM，每台 VM 一张卡；只有一张卡时两 VM 网络互通仍可单独验证，但双 VM GPU 通信标为未执行。

阶段产物：共享方案对照、IOMMU 组及设备归属、启动参数、镜像清单、VM 功能检查与网络互通日志。
