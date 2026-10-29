# GPUOperator Phase 4：Triton 融合与自动调优

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

保持与 CUDA row_softmax 相同的数学契约，以 Triton 提供第二种实现。Triton 不支持的 GPU 或版本组合保留未执行，不以 Python 循环替代。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | OP-P4-01 Triton fused softmax | 掌握 program、mask 与 reduction | 固定版本教程、自写 kernel、FP32 中间值 | 支持 Triton 的 GPU | 在一个 kernel 中减少中间张量，不只改 Python 调用名 |
| [ ] | OP-P4-02 有界 autotune | 选择合法执行配置并量化调优成本 | warp/block 参数网格、shape key、独立验证集 | 同上 | 调优时间和缓存必须与稳态执行区分 |
| [ ] | OP-P4-03 PyTorch 注册与反向 | 保持 CUDA/Triton 语义一致 | 独立 op 名称、fake、register_autograd | 兼容 PyTorch/Triton 环境 | Triton JIT 能运行不等于框架编译和训练均可用 |
| [ ] | OP-P4-04 融合真实收益对照 | 排除弱基线和隐藏转换 | CUDA/原生 softmax/eager 分解/compile 比较 | 单 GPU | 不只与多次 Python 操作的最弱基线比较 |

## 2. OP-P4-01：softmax 内核

参考 [官方 fused softmax](https://triton-lang.org/main/getting-started/tutorials/02-fused-softmax.html)，固定匹配版本并保留引用。首版每 program 处理一行，BLOCK_SIZE 为不小于 N 的二次幂，masked load 补 -Inf，使用行 max、exp、sum 和 masked store。

FP16/BF16/FP32 输入统一用 FP32 中间值，再转为输出 dtype；该 Triton 后端首版不声明 FP64。定义 N 范围与 CUDA 契约一致，对 M=0、N=0、N>4096 和非连续输入显式处理。

`tl.exp` 等实现与 CUDA/torch 可能有不同近似；测试固定种子、宽度 1/31/32/33/1001/4096、均匀/极端值，记录误差。不要把 mask 缺失造成的 padding 干扰误认为低精度误差。

## 3. OP-P4-02：调优矩阵

从少量合法 `num_warps=4/8` 配置开始，增加前核对所选 Triton/GPU 支持和资源占用。key 至少区分影响配置选择的 N、dtype、相关布局；更换设备/版本时不能无条件复用缓存结果。

对每个候选先验证输出，再在独立运行中测量；记录编译、autotune 首次总耗时、最终选中配置和稳态时间。对 M/N 不同的保留 shape 做验证，不能只在调优时见过的输入上给结论。

不在 autotune 内多次累积修改同一个有状态输出；若扩展涉及原地或累计操作，明确 reset/restore 策略。所有候选超资源或编译失败时明确报错，不以任意 fallback 结果伪装选中 kernel。

## 4. OP-P4-03：注册与梯度

使用独立的 `labops::row_softmax_triton`，不偷偷替换 CUDA 后端，便于确定实际执行路径。按实际 PyTorch 版本选择 `torch.library.custom_op` 等支持的注册方式，准确声明无输入 mutation、输出新分配。

提供 fake 实现，只使用 Tensor 元数据返回正确 shape/dtype/device，不访问 data pointer、`.item()` 或读取真实输入。fake 和真实入口共享可表达的 shape/类型约束，不能对编译路径放宽限制。

沿用 Phase 2 的解析反向并显式注册，随机上游梯度对比 PyTorch，FP32 与低精度分表。Triton 首版不支持 FP64，所以不声称通过 FP64 有限差分；可比较其 VJP 与 FP64 参考、误差敏感输入和 CUDA 已验证公式。反向若用 torch 原生操作，报告“融合前向、框架反向”，不是全自写反向。

先通过框架 registration 检查，再测 `torch.compile`。在线教程中的 `triton_op/wrap_triton` 等新 API 只有固定版本支持时才用，不能把其不存在当作硬件失败。

## 5. OP-P4-04：对照与交付

对 M=1/17/1024、N=31/1001/4096 比较以下路径，dtype 保持一致：

| 路径 | 用途 |
| --- | --- |
| PyTorch eager 分解 softmax | 显示多次读写与 launch 开销，不是唯一竞争基线 |
| PyTorch 原生 softmax | 实际库级基线 |
| 自写 CUDA row_softmax | 同语义实现对照 |
| 自写 Triton fused softmax | 调优配置及中间访存减少 |
| 可支持的 torch.compile 子图 | 检查编译器已提供的优化，排除首次编译时间 |

记录实际 kernel 数、逻辑读写量、设备时间和端到端时间。输入全在 GPU，结果比对移出测量区；若做主机输入实验，单独记录 H2D/D2H。不同精度/错误容差不满足约束的结果不能参与“最快”排名。

交付 Triton 源码、注册/fake/autograd、候选配置及调优日志、数值矩阵、真实 kernel trace 和所有基线结果。运行慢于原生库也应保留并解释行宽、资源限制或提交开销。
