# DPU：虚拟化网络与硬件卸载

五个阶段分别存放于 `phase1` 至 `phase5` 目录，每个阶段使用独立的 README。公共环境、报告要求及恢复流程记录在本文件。

| 阶段 | 任务文档 |
| --- | --- |
| Phase 1 | [SR-IOV、OVS 与 namespace](phase1/README.md) |
| Phase 2 | [虚拟化与虚拟机镜像](phase2/README.md) |
| Phase 3 | [VF 直通性能与分段聚合卸载](phase3/README.md) |
| Phase 4 | [跨节点 VXLAN 与卸载](phase4/README.md) |
| Phase 5 | [OVS-DPDK 与 VF 硬件卸载](phase5/README.md) |

名词定义统一见 [名词与缩写](../glossary/README.md)。

## 1. 范围与实验约定

本方向包含五个阶段，依次覆盖同机网络、虚拟机网络、性能对照、跨节点 VXLAN、OVS-DPDK。各阶段独立编号，任务清单中的方框仅在操作记录与原始数据齐备后勾选。

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

## 2. 报告结构、交付物与恢复

### 2.1 统一报告内容

每个需要报告的阶段在对应阶段文档中记录以下内容；较大的原始日志或镜像放实验存储，只在文档中登记路径及散列，不把磁盘镜像提交到 Git：

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
| Phase 1 | 待执行 | SR-IOV 调研、PF/VF/rep 映射、OVS 编译与 namespace 互通日志 |
| Phase 2 | 待执行 | 虚拟化对比、镜像清单与散列、TAP/VF 启动配置及互通日志 |
| Phase 3 | 待执行 | 同机测试矩阵、实际卸载状态、原始日志、性能报告 |
| Phase 4 | 待执行 | 跨节点直连与 VXLAN 配置、双向卸载证据、性能报告 |
| Phase 5 | 待执行 | DPDK 构建、设备归属、PMD 规划、流卸载证据、性能报告 |

### 2.2 恢复顺序

停止所有发流和 netserver；正常关闭 VM 并确认 VF 不再被 QEMU 占用；仅删除实验桥、TAP 和空 namespace。对两个实验 VF 清除 `driver_override`，从 vfio-pci 解绑后重新由 mlx5_core 探测。保存流表后停止实验交换进程，恢复原 OVS 配置与服务，不能直接覆盖仍在使用的数据库。

若需要恢复 legacy 模式，先按驱动要求解绑全部实验 VF、切换 eSwitch，再恢复原 VF 数量及绑定；将 `sriov_numvfs` 清零仅限确认所有 VF 都已释放后执行。恢复原 MAC、MTU、IP/路由、ethtool 特性、CPU/IRQ 亲和性、大页数量和固件设置。大页仍被占用时不强制回收。最后检查管理通路和非实验业务。

## 3. 参考资料

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
