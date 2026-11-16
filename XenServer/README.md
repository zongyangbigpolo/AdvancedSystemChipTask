# Citrix 服务器/VM 虚拟化（XenServer）带实验大作业

系统学习 Citrix 服务器虚拟化（XenServer / XCP-ng，基于 Xen 的 Type-1 hypervisor）：从虚拟化原理与架构，到主机/VM 管理、存储、网络、实时迁移与高可用。

真实 XenServer 是 x86 裸机 Type-1 产品，本机（Apple Silicon macOS）无法安装。因此每阶段分两层：
- **原理与 XenServer 操作**：以 `xe` CLI / XAPI 为准，完整给出命令与概念，涉及裸机/多主机/共享存储的部分标注**未执行（仅方法）**。
- **本机等价实验**：用 QEMU/qemu-img、libvirt test 驱动演示相同机制，亲自运行并截图。实验是概念等价物，不等于真实 XenServer。

| 阶段 | 任务 | 本机实验 | 工具 |
| --- | --- | --- | --- |
| [Phase 1](phase1/README.md) | 虚拟化原理与 XenServer 架构 | 虚拟化能力与工具栈探测 | sysctl / QEMU / virsh |
| [Phase 2](phase2/README.md) | 主机与 VM 生命周期管理（xe CLI / XAPI） | VM 定义/启停/挂起/恢复 | libvirt test 驱动 |
| [Phase 3](phase3/README.md) | 存储：SR / VDI / 快速克隆 / 快照 / 精简置备 | qcow2 精简置备/CoW 克隆/快照/导出 | qemu-img |
| [Phase 4](phase4/README.md) | 网络：虚拟交换、VLAN、绑定 | 虚拟网络与 VIF 后端枚举 | virsh / QEMU |
| [Phase 5](phase5/README.md) | XenMotion 实时迁移、HA、资源池、备份 | 内存状态序列化迁移 + 快照备份 | virsh save/restore / qemu-img |

## 环境

macOS 27.0、Apple Silicon（arm64）、10 核、16 GiB。工具：QEMU 11.1.3、libvirt 12.9.0（`virsh`）、Python 3.14，均 Homebrew 安装。`kern.hv_support=1`（支持 Hypervisor.framework）。未安装真实 XenServer（需 x86 裸机）。

## 复现

```bash
cd lab
./run_p1_caps.sh       # Phase 1
./run_p2_lifecycle.sh  # Phase 2
./run_p3_storage.sh    # Phase 3（生成 results/sr 工作区）
./run_p4_network.sh    # Phase 4
./run_p5_migrate.sh    # Phase 5（B 段需先跑 run_p3_storage.sh）
```

## 说明

- `lab/` 下脚本与 XML 为本作业自写；libvirt **test 驱动是纯内存模拟器**，用于演示工具栈操作，不启动真实客户机，其节点信息（i686、3 GiB 等）是驱动内置值。
- 截图为真实运行日志渲染的终端样式页面，非系统窗口直接截屏；原始日志在 `lab/results/*.log`。
- 真实 XenServer 的裸机安装、资源池、共享 SR、跨主机 XenMotion 与 HA 在本机不具备条件，相应章节保留为未执行，不编造结果。

## 名词

Xen、hypervisor、dom0/domU、PV/HVM/PVHVM、XAPI、`xe`、SR/VDI、PIF/VIF、XenMotion、HA 等见 [名词与缩写](../glossary/README.md) 的服务器虚拟化一节。
