# GPU：计算、虚拟化与跨节点通信

五个阶段分别存放于 `phase1` 至 `phase5` 目录，每个阶段使用独立的 README。公共环境、报告要求及恢复流程记录在本文件。

| 阶段 | 任务文档 |
| --- | --- |
| Phase 1 | [GPU 架构与 CUDA 功能](phase1/README.md) |
| Phase 2 | [GPU 虚拟化与镜像](phase2/README.md) |
| Phase 3 | [单卡计算、访存与性能分析](phase3/README.md) |
| Phase 4 | [同机多 GPU 通信](phase4/README.md) |
| Phase 5 | [跨节点 NCCL、RDMA 与 GPUDirect](phase5/README.md) |

名词定义统一见 [名词与缩写](../glossary/README.md)。

## 1. 范围与实验约定

本方向划分为 Phase 1 至 Phase 5，按照“单卡功能→虚拟化→单卡性能→同机多卡→跨节点通信”的顺序组织。每个任务均列出名称、目的、方法、硬件、方案及选择原因。

本阶段以 NVIDIA CUDA 生态为命令示例。AMD ROCm、Intel oneAPI 可作为不同实验路线，但必须重新核对硬件和 API，不能将 CUDA 命令直接用于其他厂商设备。GPU 计算加速、GPU 虚拟化、RDMA 网络和 DPU 流表卸载属于不同能力，不相互替代。

**执行边界：**本文件仅提供操作过程、测试矩阵与判定标准，不包含硬件执行结果。缺少 GPU、第二张卡、第二个节点、NVLink、支持 MIG/vGPU 的型号或 RDMA 网络时，相关项目保留“待执行”或“受硬件限制未执行”。不以 CPU、单卡或普通 TCP 结果替代对应硬件结果。

### 1.1 硬件与软件基线

| 项目 | 基线与用途 | 选择依据 |
| --- | --- | --- |
| 主机 | 两台 x86_64 Linux 服务器；建议每台至少 16 核、64 GiB 内存；直通需要 VT-d/AMD-Vi | 分离 GPU、MPI、网卡、监控与 VM 资源 |
| GPU | 单卡任务至少一张 CUDA 支持的 GPU；多卡任务至少同机两张；跨节点每节点至少一张 | 资源不足时按任务边界停止，不混淆单卡与多卡 |
| 型号示例 | A100/H100 等数据中心型号，或驱动/CUDA 兼容的实验 GPU | NVLink、MIG、vGPU、P2P、GPUDirect 支持须逐型号和拓扑核对；消费卡不默认支持这些能力 |
| 网络 | 管理网独立；Phase 5 可先测 Ethernet Socket，再选支持 RDMA 的 ConnectX 网卡和网络 | 先建立 TCP 基线，再判断 RDMA 收益 |
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

## 2. 交付清单、报告结构与恢复

### 2.1 阶段交付物

| 阶段 | 状态 | 交付物 |
| --- | --- | --- |
| Phase 1 | 待执行 | GPU 能力与拓扑表、驱动/工具版本、样例正确性与内存检查日志 |
| Phase 2 | 待执行 | 虚拟化方式对比、IOMMU 与直通记录、镜像清单/散列、VM 功能与网络日志 |
| Phase 3 | 待执行 | 单卡测试矩阵、输入与数值容差、profiler 文件、裸机/VM 对照报告 |
| Phase 4 | 待执行 | 多卡拓扑、P2P 能力、NCCL 配置及实际传输日志、同机通信报告 |
| Phase 5 | 待执行 | 网络/RDMA/GDR 证据、跨节点日志、性能统计与瓶颈报告 |

每份报告包含环境、拓扑、问题定义、变量与控制条件、操作命令、原始数据路径、统计方法、正确性、性能比较、限制及结论。镜像与大型 profiler 文件存放实验存储，在本文登记路径、软件版本和散列，不提交 Git。

无设备时只完成知识调研、参数规划和方法文档，执行状态保持未执行；不填写通过、加速比、带宽或错误率。

### 2.2 恢复顺序

停止 MPI/NCCL/CUDA 进程并正常关闭 VM；确认设备无使用者后，从 vfio-pci 解绑每个实验 GPU 功能，清除 `driver_override`，再由原驱动探测。部分设备不支持可靠复位时按产品要求在维护窗口重启，不反复强制 reset。

恢复原 MIG profile、MPS 服务状态、功率/时钟策略、CPU/NUMA 亲和性和网络配置；仅清理实验 TAP/桥及临时环境变量，不中止其他 GPU 作业。检查宿主机 `nvidia-smi`、设备归属、管理通路及已保留的配置。

## 3. 参考资料

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
