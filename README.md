# 硬件加速、存储与算子开发实验

| 方向 | 阶段目录与公共环境 | 内容 |
| --- | --- | --- |
| DPU | [DPU/README.md](DPU/README.md) | SR-IOV、ConnectX-5、OVS、虚拟机直通、VXLAN、DPDK 与流表卸载 |
| GPU | [GPU/README.md](GPU/README.md) | CUDA 调试、访存与 Graph 优化、虚拟化、AMP、DDP、跨节点训练与恢复 |
| NPU | [NPU/README.md](NPU/README.md) | Ascend 环境、模型转换与推理、精度与性能、Ascend C、HCCL 与训练 |
| Storage | [Storage/README.md](Storage/README.md) | Linux 存储栈、同步/异步 I/O、SPDK bdev、NVMe-oF、WAL 与故障恢复 |
| GPUOperator | [GPUOperator/README.md](GPUOperator/README.md) | CUDA/Triton 算子、归约与 GEMM、数值梯度、PyTorch 集成与交付 |

名词、缩写、英文全称及概念边界统一记录在 [名词与缩写](glossary/README.md)，各阶段文档不重复维护术语表。

每个方向均包含五个独立阶段，分别使用 `phase1/README.md` 至 `phase5/README.md`，不按周或天重复命名。

| 阶段 | DPU | GPU | NPU | Storage | GPUOperator |
| --- | --- | --- | --- | --- | --- |
| Phase 1 | [SR-IOV、OVS 与 namespace](DPU/phase1/README.md) | [CUDA 功能、错误定位与转置优化](GPU/phase1/README.md) | [架构、环境与单卡验证](NPU/phase1/README.md) | [Linux 存储栈与同步 I/O](Storage/phase1/README.md) | [算子契约与参考工程](GPUOperator/phase1/README.md) |
| Phase 2 | [虚拟化与虚拟机镜像](DPU/phase2/README.md) | [虚拟化、容器交付与 NUMA](GPU/phase2/README.md) | [模型转换与离线推理](NPU/phase2/README.md) | [io_uring 异步引擎](Storage/phase2/README.md) | [CUDA 归约与反向](GPUOperator/phase2/README.md) |
| Phase 3 | [VF 直通性能与分段聚合卸载](DPU/phase3/README.md) | [单卡性能、CUDA Graph 与 AMP](GPU/phase3/README.md) | [精度、吞吐与性能定位](NPU/phase3/README.md) | [SPDK 与 bdev 开发](Storage/phase3/README.md) | [GEMM 与性能归因](GPUOperator/phase3/README.md) |
| Phase 4 | [跨节点 VXLAN 与卸载](DPU/phase4/README.md) | [多卡通信、DDP 与显存优化](GPU/phase4/README.md) | [Ascend C 算子开发与调优](NPU/phase4/README.md) | [NVMe-oF 远程块存储](Storage/phase4/README.md) | [Triton 融合与调优](GPUOperator/phase4/README.md) |
| Phase 5 | [OVS-DPDK 与 VF 硬件卸载](DPU/phase5/README.md) | [跨节点通信、训练恢复与诊断](GPU/phase5/README.md) | [多卡、跨节点通信与训练](NPU/phase5/README.md) | [WAL 与故障恢复](Storage/phase5/README.md) | [模型集成与交付](GPUOperator/phase5/README.md) |

文档中的命令为实验操作步骤，不表示已经执行。硬件配置、固件更新、驱动切换、设备直通、存储写入、故障注入及性能测试须在具备对应设备的隔离实验环境中进行；未执行的项目保留“待执行”，不生成性能结论。文档指定的待开发源码、脚本和接口不代表仓库已经提供对应实现。
