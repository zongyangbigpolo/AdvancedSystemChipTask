# GPU：计算、虚拟化与跨节点通信

五个阶段分别存放于 `phase1` 至 `phase5` 目录，每个阶段使用独立的 README。公共环境、报告要求及恢复流程记录在本文件。

| 阶段 | 任务文档 |
| --- | --- |
| Phase 1 | [CUDA 功能、Sanitizer 错误定位与转置优化](phase1/README.md) |
| Phase 2 | [GPU 直通、镜像、容器交付与 NUMA](phase2/README.md) |
| Phase 3 | [单卡计算、CUDA Graph 与 AMP 训练](phase3/README.md) |
| Phase 4 | [同机 NCCL、DDP 与显存优化](phase4/README.md) |
| Phase 5 | [跨节点通信、训练恢复与慢 rank 诊断](phase5/README.md) |

名词定义统一见 [名词与缩写](../glossary/README.md)。

## 1. 范围与实验约定

本方向划分为 Phase 1 至 Phase 5，按照“单卡功能→虚拟化→单卡性能→同机多卡→跨节点通信”的顺序组织。每个任务均列出名称、目的、方法、硬件、方案及选择原因。

共 29 项任务，其中 10 项为面向实现、调试和性能归因的补充实验。要求提交自己编写的代码或对官方样例的修改、边界测试、原始测量与分析证据，不以读资料、单次跑通或截图代替实验闭环。文档中明确标注的 `sanitizer_lab.cu`、`graph_bench.cu`、`amp_train.py`、`ddp_train.py` 等是需在实验中实现的作业文件，仓库没有将其标为已完成程序；只有设备和程序就绪后才能执行对应命令模板。

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
| Phase 1 | 待执行 | 环境与拓扑、四类 CUDA 错误复现/修复、转置 kernel 与边界测试、访存指标 |
| Phase 2 | 待执行 | 直通与镜像、可重建容器配置、设备分配验证、NUMA 放置对照 |
| Phase 3 | 待执行 | 计算/传输矩阵、Graph 建图摊销、AMP 训练误差/显存、profiler 及裸机/VM 对照 |
| Phase 4 | 待执行 | P2P/NCCL 证据、DDP 数据分片与参数校验、强/弱扩展、激活重计算与累积对照 |
| Phase 5 | 待执行 | RDMA/GDR 证据、跨节点训练、完整 checkpoint 恢复、慢 rank 和 bucket 调优报告 |

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

### 3.1 补充实操任务的官方依据

资料核对日期：2026-10-26。CUDA C++ 样例沿用本方向的 `v12.4` tag；框架任务按实际安装版本核对 API，在线教程不自动等于已安装版本。官方样例需保留许可证，自写作业需说明参考来源。

| 实操任务 | 官方资料 | 采用内容与实验扩展 |
| --- | --- | --- |
| GPU-P1-04 | [Compute Sanitizer](https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html) | 四种工具的覆盖范围；增加最小故障、修复和回归 |
| GPU-P1-05 | [transpose v12.4](https://github.com/NVIDIA/cuda-samples/tree/v12.4/Samples/6_Performance/transpose)、[Nsight Compute 分析指南](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html) | 合并访问与 bank conflict；增加非方阵和尾块 |
| GPU-P2-05 | [Container Toolkit 运行样例](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/sample-workload.html) | runtime GPU 分配；增加固定 digest 构建与负向验证 |
| GPU-P2-06 | [CUDA 性能最佳实践](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html) | 数据传输与 NUMA 亲和性；增加四种位置组合 |
| GPU-P3-05 | [simpleCudaGraphs v12.4](https://github.com/NVIDIA/cuda-samples/tree/v12.4/Samples/3_CUDA_Features/simpleCudaGraphs) | 建图、capture、replay；增加固定工作量及成本回收测量 |
| GPU-P3-06 | [AMP 实操教程](https://docs.pytorch.org/tutorials/recipes/recipes/amp_recipe.html) | autocast/scaler；增加 loss、参数、峰值内存与规模对照 |
| GPU-P4-05、GPU-P5-05/06 | [DDP 教程](https://docs.pytorch.org/tutorials/intermediate/ddp_tutorial.html) | 一进程一卡、处理速度差异、保存恢复；增加全局 batch 与 rank 证据 |
| GPU-P4-06 | [Activation checkpoint](https://docs.pytorch.org/docs/2.5/checkpoint.html)、[DDP no_sync](https://docs.pytorch.org/docs/2.5/generated/torch.nn.parallel.DistributedDataParallel.html) | 激活重计算、梯度累积与通信同步；区别训练文件恢复 |
