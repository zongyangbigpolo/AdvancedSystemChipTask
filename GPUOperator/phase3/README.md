# GPUOperator Phase 3：分块矩阵乘与性能归因

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

本阶段从朴素 CUDA GEMM 到共享内存分块，库实现仅作独立基线。Tensor Core 和多级流水为条件扩展，不要求无对应硬件也实现。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | OP-P3-01 朴素 GEMM | 建立可审查索引和数值基线 | 一线程算输出元素，CPU/torch 参考 | 单 CUDA GPU | 先保证 M/N/K、布局和空维正确 |
| [ ] | OP-P3-02 shared memory 分块 | 提高输入复用并支持尾块 | 合法 tile、协作搬运、同步与边界 guard | 同上 | 通过复用减少全局读，而不是少算元素 |
| [ ] | OP-P3-03 库和硬件指标对照 | 解释性能上限与资源瓶颈 | cuBLAS/torch、Nsight、FLOP/s 和 roofline | GPU、分析权限 | 数学模式一致时再谈速度，不能拿不同精度当单优化收益 |
| [ ] | OP-P3-04 epilogue 融合 | 降低中间结果写读与 launch | `relu(A@B+bias)`，融合/分步对照 | 同上 | 同时评估整个子图，区分自动融合与手写收益 |

## 2. OP-P3-01：输入布局和基线

实现二维 row-major `[M,K] × [K,N]`，按 Phase 1 契约处理 K=0、M/N=0、设备与 dtype。内积累加顺序和类型明确；不能通过调用 `at::matmul` 后将函数命名为 naive CUDA 实现。

测试 `(M,N,K)` 为 `(1,1,1)`、`(32,32,32)`、`(127,65,33)`、`(256,256,256)`、`(1024,1024,1024)`、`(4096,256,1024)`。大 shape 依显存预算调整，失败/不适用单列。随机数范围、种子、权重与精度模式固定。

先 FP32，CPU FP64 作误差参考；长 K 的累加误差需要相对与绝对容差，不用单一绝对阈值覆盖所有规模。

## 3. OP-P3-02：分块实现

基础 tile 可从 16×16 起步。每 block 协作搬 A/B 子块到 shared memory，越界搬入零，所有参与线程一致执行需要的 barrier，然后累计并写回合法输出。

绘制每个线程负责的全局坐标、shared memory 索引和循环 K 区间。尾块 guard 必须同时覆盖 M/N/K；只 guard 最后 store 不能阻止越界 load。不得在部分线程提前 return 后让其余线程进入 block barrier。

增加 32×32 等其他合法 tile 前计算线程数、shared memory 与寄存器需求。使用 compiler 资源报告与 profiler 检查 spill/occupancy；保留更慢或不合法配置的记录。不支持 FP16 Tensor Core 时保持普通标量/向量路径，不声称开启了 Tensor Core。

## 4. OP-P3-03：正确基线和性能测量

对相同张量比较 naive、tiled、`torch.matmul` 或显式 cuBLAS。记录 TF32、FP16/BF16、累加类型、允许的数学模式和实际算法，未对齐精度时分表报告。调优库的最快数值不自动等同于严格 FP32 参考。

kernel 时间用输入驻留设备的事件测量；端到端包含框架检查/分配，分别标记。预热排除首次模块加载，正式至少三轮，每轮 100 次；总量太大时减少次数但说明。

完成 `benchmarks/bench_matmul.py` 后运行其自定义接口：

```bash
python "$OPLAB/benchmarks/bench_matmul.py" --backend tiled \
  --m 1024 --n 1024 --k 1024 --dtype float32 \
  --warmup 10 --iters 100 --output "$OPLAB/results/gemm-tiled.json"
```

该脚本与参数需在实验中实现。用 `2MNK/time` 计算 GEMM FLOP/s；加入 bias/ReLU 后明确仍沿用 GEMM 计数约定。Nsight Compute 分析内存、计算吞吐、寄存器、shared memory 与 occupancy；采样运行与正式计时分开。

绘制算术强度与带宽/算力限制的估计，注明算法逻辑字节量与硬件实测事务不同。不只凭“GPU 利用率 100%”判断已经算力满载。

## 5. OP-P3-04：融合 epilogue

在结果仍位于寄存器时加每列 bias 并 ReLU，再写出；bias shape `[N]`、dtype 和精度转换必须定义。非方阵、尾块和接近零的值重新测试。

比较：手写 GEMM 后两次独立操作、手写融合版本、框架 eager、可支持时的 compile 子图；如 cuBLASLt 提供融合 epilogue，也可作独立库基线。确认实际 kernel 数与中间张量，不把框架已经融合的路径描述为未融合。

本阶段融合可先限定 inference，显式标注不支持 autograd，不能在训练中自动返回无梯度结果。训练集成优先使用 Phase 2 已验证反向的算子；若扩展 fused matmul backward，再增加对应梯度测试。

交付索引图、两类 GEMM 源码、边界与 sanitizer 结果、数学模式、性能 JSON/trace、融合前后真实 kernel 数和失败配置。
