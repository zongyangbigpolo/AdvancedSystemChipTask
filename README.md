# 硬件加速与虚拟化实验

| 方向 | 阶段目录与公共环境 | 内容 |
| --- | --- | --- |
| DPU | [DPU/README.md](DPU/README.md) | SR-IOV、ConnectX-5、OVS、虚拟机直通、VXLAN、DPDK 与流表卸载 |
| GPU | [GPU/README.md](GPU/README.md) | CUDA 调试、访存与 Graph 优化、虚拟化、AMP、DDP、跨节点训练与恢复 |
| NPU | [NPU/README.md](NPU/README.md) | Ascend 环境、模型转换与推理、精度与性能、Ascend C、HCCL 与训练 |

名词、缩写、英文全称及概念边界统一记录在 [名词与缩写](glossary/README.md)，各阶段文档不重复维护术语表。

每个方向均包含五个独立阶段，分别使用 `phase1/README.md` 至 `phase5/README.md`，不按周或天重复命名。

| 阶段 | DPU | GPU | NPU |
| --- | --- | --- | --- |
| Phase 1 | [SR-IOV、OVS 与 namespace](DPU/phase1/README.md) | [CUDA 功能、错误定位与转置优化](GPU/phase1/README.md) | [架构、环境与单卡验证](NPU/phase1/README.md) |
| Phase 2 | [虚拟化与虚拟机镜像](DPU/phase2/README.md) | [虚拟化、容器交付与 NUMA](GPU/phase2/README.md) | [模型转换与离线推理](NPU/phase2/README.md) |
| Phase 3 | [VF 直通性能与分段聚合卸载](DPU/phase3/README.md) | [单卡性能、CUDA Graph 与 AMP](GPU/phase3/README.md) | [精度、吞吐与性能定位](NPU/phase3/README.md) |
| Phase 4 | [跨节点 VXLAN 与卸载](DPU/phase4/README.md) | [多卡通信、DDP 与显存优化](GPU/phase4/README.md) | [Ascend C 算子开发与调优](NPU/phase4/README.md) |
| Phase 5 | [OVS-DPDK 与 VF 硬件卸载](DPU/phase5/README.md) | [跨节点通信、训练恢复与诊断](GPU/phase5/README.md) | [多卡、跨节点通信与训练](NPU/phase5/README.md) |

文档中的命令为实验操作步骤，不表示已经执行。硬件配置、固件更新、驱动切换、设备直通及性能测试须在具备对应设备的隔离实验环境中进行；未执行的项目保留“待执行”，不生成性能结论。
