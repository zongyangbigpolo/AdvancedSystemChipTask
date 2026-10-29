# GPUOperator Phase 5：模型集成、编译兼容与交付

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

本阶段将前面的 kernel 变为可重复安装、可求导、可编译验证的算子包。未通过正确性与反向的融合算子只参与 inference，不自动用于训练。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | OP-P5-01 注册与梯度全面验收 | 区分 dispatcher 合约和数学正确性 | opcheck、fake、gradcheck/VJP、负向输入 | 单 GPU；部分 CPU 检查可独立执行 | 每种检查覆盖不同问题，不能一个通过即宣称全部正确 |
| [ ] | OP-P5-02 torch.compile 集成 | 检查图捕获、动态尺寸和实际 backend | eager/compile、fullgraph、重编译日志 | 兼容编译栈的 GPU | 编译成功不等于自定义 kernel 被融合或更快 |
| [ ] | OP-P5-03 模型前反向与性能 | 验证算子替换的真实端到端影响 | 固定小模型、初值/数据/梯度、训练步骤对照 | 单 GPU | kernel 微基准收益未必转化为模型收益 |
| [ ] | OP-P5-04 构建交付与回归报告 | 使结果能在独立环境复现 | wheel、依赖/架构清单、安装测试、综合报告 | 同型号 GPU；额外环境为条件项 | 不依赖开发机缓存和未登记文件 |

## 2. OP-P5-01：分别检查注册与数值

按固定 PyTorch 版本，对已注册算子执行 `torch.library.opcheck`。覆盖 CPU/CUDA、requires_grad 与合法 shape，检查 schema mutation/alias、autograd 注册及 fake 与真实输出元数据一致性。

示例在包实际实现后运行：

```python
import torch
import gpu_operator_lab

x = torch.randn(17, 33, device="cuda", requires_grad=True)
y = torch.randn_like(x, requires_grad=True)
torch.library.opcheck(torch.ops.labops.scale_add.default, (x, y, 0.25))
```

opcheck 不验证梯度数学公式。另对 FP64 CUDA scale_add/softmax 做 gradcheck；对 FP16/BF16/Triton 做独立解析梯度、VJP 和合理容差对照。需要二阶梯度时再做 gradgradcheck，否则明确能力边界。

检查输出新存储、不改输入；混合设备、错 shape、非连续、超行宽和未支持 dtype 应失败，错误说明与契约一致。空输出和 K=0 情况不应触发 CUDA launch 错误。测试跳过必须有实际能力依据，未实现项保留未完成。

## 3. OP-P5-02：编译与动态形状

构造包含 scale_add/row_softmax 的小函数，分别运行 PyTorch 原生 eager、原生 compile、自定义 eager、自定义 compile。使用 `torch.compile(fullgraph=True)` 检查图完整性，再按版本支持情况测试动态 shape。

输入序列 `[17,33] → [17,1001] → [1,33] → [0,33]` 都满足契约；4097 列应与 eager 同样拒绝。记录首次编译、每次重新编译、稳态时间与实际图/kernels。metadata 推导必须不依赖具体数据，不能通过把 Tensor 值拉回 CPU 决定输出 shape。

自定义 op 可能作为不透明节点留在图里，不一定与相邻算子融合；以图和 trace 说明，不能把 `fullgraph=True` 成功称为“所有算子融合”。Graph break、版本 API 不支持与硬件不支持分别记录。

AMP 和 CUDA Graph 捕获是条件扩展：显式规定 autocast 支持策略，不支持时明确错误；捕获前完成加载、编译与内存准备，并确认引用的 buffer 生命周期。不得用全局同步或禁用校验来换取通过。

## 4. OP-P5-03：小模型替换与训练闭环

模型采用 `Linear → scale_add(residual) → row_softmax`，隐藏宽度不超过契约上限，固定分类标签和输入。以相同权重创建独立两份模型，原生路径使用等价 PyTorch 操作，自定义路径明确选择 CUDA 或 Triton。

先做 inference 输出对照，再用相同非平凡上游 loss 做一步梯度和 optimizer 更新对照；比较每层梯度、参数及 loss，不能只检查 loss 下降。随后固定 100～200 步及数据顺序，验证多步数值和训练稳定性。

Phase 3 的 matmul/ReLU 融合若仅支持 inference，只在单独推理子图评估；不能在训练路径中静默 detach。可复用 [GPU AMP 训练实验](../../GPU/phase3/README.md) 的记录口径，但算子包支持的 dtype 与反向仍需单独验证。

性能报告同时列 kernel-only、模型前向、完整 forward/backward/update、内存峰值和 kernel 数。分配、编译、autotune、host 数据加载是否计入必须明确，不把不同 batch 或精度的结果视为单变量加速。

| 路径 | shape/dtype | 前向误差 | 梯度/参数误差 | kernel us | 模型/step ms | 内存峰值 | 实际 kernel/图 | 日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | — | — | — | — | — | 待记录 | — |

## 5. OP-P5-04：可重建交付与判定

使用完整依赖清单构建 wheel，记录源 commit、Python/PyTorch/CUDA/Triton、C++ ABI、GPU 架构与编译参数。普通扩展只声明实际验证过的兼容组合，不因 wheel 文件名宽泛就声称跨所有版本可用。

在独立环境安装**明确路径的一份 wheel**，不依赖 editable 源码、JIT 开发缓存或默认工作目录。运行包 import、schema、前向、梯度、stream、compile 和 sanitizer 回归；移走源码目录后仍能加载必要二进制和注册。

提交源码、构建文件、测试、基准、输入规范、依赖锁定、散列和使用说明；大型 trace 放实验存储并登记路径。官方样例派生代码保留原许可证，不能删除版权信息。

| 交付项 | 完成条件 |
| --- | --- |
| 算子实现 | 自写 CUDA/Triton 源码及可追踪 backend，不以库调用冒充手写 |
| 正确性 | 前向/反向、边界/特殊值、错误路径、stream 和 sanitizer 有原始结果 |
| 集成 | schema/fake/autograd、opcheck、compile 与模型替换在声明范围内一致 |
| 性能 | 至少三轮、多 shape、原生/库/compile 强基线，记录无收益和失败条件 |
| 可复现性 | 固定版本与架构，独立安装测试，未执行硬件能力如实标注 |

不要求预设加速百分比；没有满足数值和接口契约的结果不能作为有效优化。缺少设备、代码未完成或测试仍失败时，保留任务状态，不填写“全部通过”。
