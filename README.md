# 硬件加速与虚拟化实验

| 方向 | 第一阶段文档 | 内容 |
| --- | --- | --- |
| DPU | [DPU/phase1/README.md](DPU/phase1/README.md) | SR-IOV、ConnectX-5、OVS、虚拟机直通、VXLAN、DPDK 与流表卸载 |
| GPU | [GPU/phase1/README.md](GPU/phase1/README.md) | CUDA、GPU 虚拟化、计算与访存性能、多卡通信、跨节点通信 |

每个方向的 `phase1/README.md` 包含五个子阶段，使用 Phase 1.1 至 Phase 1.5 标识。后续阶段使用独立的 `phase2/README.md` 等目录，不与第一阶段混写。

文档中的命令为实验操作步骤，不表示已经执行。硬件配置、固件更新、驱动切换、设备直通及性能测试须在具备对应设备的隔离实验环境中进行；未执行的项目保留“待执行”，不生成性能结论。
