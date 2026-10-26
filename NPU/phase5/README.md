# NPU Phase 5：多卡、跨节点通信与训练

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

本阶段仅在支持 torch_npu/HCCL 和相应网络的产品上执行。先同机两设备，再两节点各一设备；普通推理卡不默认支持该训练路线。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | NPU-P5-01 同机 HCCL 正确性 | 核对 rank/设备映射与同步 | torchrun，一进程一设备，AllReduce 数值校验 | 同机至少两个受支持逻辑设备 | 单 rank 不能代表设备间通信 |
| [ ] | NPU-P5-02 跨节点通信矩阵 | 测量真实网络与集合通信 | 两节点 HCCL，长度扫描、同步计时及日志 | 每节点一设备和兼容数据网络 | rendezvous 可达不代表设备通信链路可用 |
| [ ] | NPU-P5-03 DDP 训练与扩展效率 | 将通信基准连接到实际训练 | 固定模型/数据，单卡与双卡、固定全局 batch | 支持训练的 NPU | 不把 collective 微基准带宽等同于训练吞吐 |
| [ ] | NPU-P5-04 训练恢复与通信诊断 | 验证可恢复性和慢 rank 定位 | checkpoint、重启恢复、短时受控延迟 | 隔离的双卡或双节点实验 | 使用应用层扰动，不影响其他作业的网络与设备 |

## 2. NPU-P5-01：最小通信程序

在 `$LAB/src/hccl_check.py` 中保存以下代码后运行；该路径是本任务需创建的实验文件，不是仓库预装程序：

```python
import os
from datetime import timedelta
import torch
import torch_npu
import torch.distributed as dist

local_rank = int(os.environ["LOCAL_RANK"])
torch.npu.set_device(local_rank)
dist.init_process_group("hccl", timeout=timedelta(seconds=120))
try:
    rank = dist.get_rank()
    world = dist.get_world_size()
    value = torch.tensor([float(rank + 1)], device=f"npu:{local_rank}")
    dist.all_reduce(value)
    torch.npu.synchronize()
    expected = torch.tensor([world * (world + 1) / 2.0])
    torch.testing.assert_close(value.cpu(), expected)
    print(f"rank={rank} device={local_rank} sum={value.item()}", flush=True)
finally:
    dist.destroy_process_group()
```

```bash
torchrun --standalone --nproc-per-node=2 "$LAB/src/hccl_check.py"
```

先确认设备 0/1 对应本实验可用设备；若使用可见性或分区机制，按该版本文档建立逻辑映射，不能抢占其他作业。保存所有 rank 输出，要求无错误且归约和正确。

## 3. NPU-P5-02：两节点与长度扫描

两节点安装相同软件、放置相同程序。示例 A=`198.51.100.31`，B=`198.51.100.32`；按实际主机、设备 IP、路由和 HCCL 版本要求配置实验网络。host rendezvous 与设备数据网用途不同；`MASTER_ADDR` 或 TCP 端口能通，不证明 HCCL 设备互连已就绪。

两端分别运行，A 设置 `NODE_RANK=0`，B 设置 `NODE_RANK=1`：

```bash
torchrun --nnodes=2 --nproc-per-node=1 \
  --node-rank="${NODE_RANK:?未设置节点编号}" \
  --master-addr=198.51.100.31 --master-port=29510 \
  "$LAB/src/hccl_check.py"
```

防火墙只按官方端口要求对实验对端放行；HCCL 的接口选择、rank table 和连接模式依版本核对，不照搬 NCCL 环境变量，也不假定所有版本必须手工编写 rank table。

将程序扩展为 AllReduce 和 AllGather，长度取 128/256/512/1500 B 及 1/4/16/64 MiB；按 FP32 元素大小换算 count，并打印实际字节数。AllGather 按 API 为每个 rank 准备独立输出，考虑总内存为 rank 数倍。

计时前 barrier、设备同步，循环前重设输入并移出计时窗口；重复原地归约而不重设会让值持续增长，影响正确性。测量后再次同步，汇总所有 rank 的时间，以最慢 rank 为集合操作耗时口径。实际带宽按明示算法字节量换算，不直接套用 nccl-tests 的 busbw 列名和公式。

## 4. NPU-P5-03/04：训练与恢复

按 [GPU Phase 4 的 DDP 实验要求](../../GPU/phase4/README.md) 编写等价训练程序，改用 `torch_npu`、`npu` 设备、`hccl` backend 及配套同步/内存 API；AMP 按 torch_npu 实际版本支持接口迁移，不全局替换所有 `cuda` 字符串。

使用固定数据与初始权重，比较单卡、同机双卡和跨节点双卡。固定全局 batch，将各 rank 的局部 loss 按真实样本数加权汇总；注明 DDP 的梯度平均语义和梯度累积次数，不能扩大总 batch 后把吞吐上升全算成扩展效率。

保存模型、优化器、调度器、AMP scaler（若启用）、全局 step、数据顺序与随机状态；在完整 step 边界保存。重启后比对后续 loss、参数误差和 step；如精确恢复受非确定性算子限制，预先定义容差并记录，不宣称位级一致。

只在自有进程给一个 rank 增加固定短暂等待，并采集配套 profiler；定位哪个 rank 最先停在计算/数据/通信处，再去掉扰动复测。出现超时保存最初的错误与所有 rank 日志，不能无限增大 timeout 掩盖问题。

| 拓扑/rank | 实际通信路径证据 | 字节或全局 batch | 操作 | 最慢 rank 时间 | 样本/s | 正确性/恢复误差 | 日志/trace |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | — | — | — | — |

交付通信代码、训练改动、启动参数、映射表、日志、checkpoint 清单、扩展效率和故障定位报告。设备链路/网络路径无法确认时明确标注，不推断已采用某种硬件直达路径。
