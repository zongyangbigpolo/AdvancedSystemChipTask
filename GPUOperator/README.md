# GPUOperator：GPU 算子开发与框架集成

五个阶段分别放在 `phase1` 至 `phase5`，每阶段包含四项任务，共 20 项。该方向专注“从数学契约到可集成算子”，与 [GPU 通用实验](../GPU/README.md) 的虚拟化、多卡通信任务分开；名词统一见 [术语文档](../glossary/README.md)。

| 阶段 | 任务文档 | 核心交付物 |
| --- | --- | --- |
| Phase 1 | [算子契约、参考实现与工程](phase1/README.md) | schema、CPU 参考、用例矩阵、可构建扩展 |
| Phase 2 | [CUDA 逐元素、归约与反向](phase2/README.md) | CUDA kernel、边界/梯度测试、stream 与内存安全证据 |
| Phase 3 | [分块矩阵乘与性能归因](phase3/README.md) | naive/tiled GEMM、尾块、cuBLAS 对照、profiler |
| Phase 4 | [Triton 融合与自动调优](phase4/README.md) | 融合 softmax、受限 autotune、框架注册与数值回归 |
| Phase 5 | [模型集成、编译兼容与交付](phase5/README.md) | opcheck/梯度检查、compile 对照、训练闭环、wheel 与报告 |

## 1. 范围、负载与执行边界

开发环境采用 Linux、NVIDIA CUDA、PyTorch C++/CUDA Extension 和受支持的 Triton。AMD/其他 GPU 的适配为独立路线，不将本方向 NVIDIA 性能指标和编译参数直接迁移。

固定三个算子负载：

| 算子 | 语义 | 首版约束 | 扩展 |
| --- | --- | --- | --- |
| `scale_add(x, y, alpha)` | `out = x + alpha * y` | 两输入同 shape/dtype/device、连续、不广播、非原地 | FP16/BF16、特殊值、显式 stride 支持 |
| `row_softmax(x)` | 对二维输入最后一维做数值稳定 softmax | 连续、非空归约维度、非原地；明确行宽上限 | Triton 融合、受支持 dtype、反向 |
| `matmul(a, b)` | `[M,K] × [K,N] → [M,N]` | 二维连续、无 batch/转置参数、非原地 | tile、FP32 累加、受限融合 epilogue |

所有例子均要求明确不支持的输入并给出错误，而不是静默 `.contiguous()`、复制到 CPU 或调用 torch/cuBLAS 后把它算作自写 kernel 性能。若有意提供转换或库后端，使用单独标明的接口/结果标签。

**执行边界：**文档是任务和实现要求，不包含已完成的算子代码或硬件结果。`gpu_operator_lab`、`tests/`、`bench.py`、`train_compare.py` 等路径为实验中需开发的文件/包，不是当前仓库已有程序。缺少 CUDA GPU 时可编写 CPU 参考和测试规划，但 CUDA、Triton、性能与 sanitizer 结果均保持未执行。

### 1.1 环境和版本基线

| 项目 | 要求与原因 |
| --- | --- |
| GPU | 一张支持所选 CUDA 与 Triton 的 NVIDIA GPU；Tensor Core/BF16 属条件能力，不由设备存在自动推断 |
| 主机 | Linux、足量主机内存与编译资源；具备 Nsight/Compute Sanitizer 的授权使用条件 |
| 工具链 | 记录驱动、CUDA Toolkit、nvcc、host compiler、Python、PyTorch wheel、Triton、C++ ABI 与架构目标 |
| 框架组合 | 可参考 PyTorch 2.5.1 + CUDA 12.4 的历史实验组合；实际选取维护中且兼容的版本，Triton 遵循所选框架依赖 |
| 兼容约束 | 使用普通 ATen/LibTorch 扩展时按 PyTorch/Python/ABI 组合重新构建，不声称 wheel 跨版本稳定 |
| 资源范围 | 只使用获准 GPU、CPU 和实验目录；不修改其他作业的时钟、功率、驱动或 profiler 权限 |

在线自定义算子教程可能默认展示 PyTorch 2.10+ 的 Stable ABI；如果基线采用 2.5.1，应选择传统接口章节，不能复制新版头文件或把二者混用。Triton `main` 教程中的 runtime、metadata、autotune 接口也须核对固定版本。

```bash
export OPLAB=$HOME/gpu-operator-lab
mkdir -p "$OPLAB"/{csrc,gpu_operator_lab,tests,benchmarks,results}
nvidia-smi
nvcc --version
python -c 'import torch; print(torch.__version__); print(torch.version.cuda); print(torch.cuda.is_available())'
python -c 'import triton; print(triton.__version__)'
```

不要因文档中的检查命令缺包而升级共享框架；在独立环境按选定依赖安装。

## 2. 统一验收与报告

每个算子提交数学定义、schema、dtype/shape/stride/alias 契约、源码、构建依赖、CPU/框架参考、测试、性能脚本与原始结果。核心项是正确性和可集成性；相对库基线更慢仍可形成有效报告，不能删掉不利 shape。

| 维度 | 要求 |
| --- | --- |
| 数值 | 记录种子、输入范围、计算/累加类型、绝对/相对误差与容差；有限值和 NaN/Inf 分开比较 |
| 边界 | 空输出、尾块、非整齐 shape、偏移视图、非连续、dtype/device 不匹配、超出范围 |
| 梯度 | 前向、解析反向、数值梯度或独立向量积；opcheck 不等于数值梯度正确 |
| 执行 | 非默认 CUDA stream、输入所在设备、异步错误传播、buffer 生命周期与 sanitizer |
| 性能 | 编译/调优/预热单列；至少三轮、每轮预热 10 次、测量至少 100 次，使用设备事件与主机同步墙钟 |
| 基线 | PyTorch eager、可支持时的 torch.compile、库实现与自写 kernel 分别标识 |
| 证据 | 逐次时间/直方图、源码 commit、运行配置、kernel 数、内存峰值、profiler 与失败记录 |

不能把异步调用返回时间当 GPU 执行时间；kernel-only 不含主机拷贝、框架封装和编译，应与 end-to-end 分表。多个 shape 的收益同时列原值与加速比，不只保留最佳值。测试完成后停止实验进程、释放设备和临时构建，不删除原始失败证据。

## 3. 官方参考

资料核对日期：2026-10-29。固定依赖版本后使用其对应文档，原样例参考和派生代码保留许可证与来源。

- [PyTorch C++/CUDA 自定义算子](https://docs.pytorch.org/tutorials/advanced/cpp_custom_ops.html)
- [PyTorch Python 自定义算子](https://docs.pytorch.org/tutorials/advanced/python_custom_ops.html)
- [torch.library 2.5：opcheck、fake 与 autograd](https://docs.pytorch.org/docs/2.5/library.html)
- [gradcheck 原理](https://docs.pytorch.org/docs/2.5/notes/gradcheck.html)
- [Triton fused softmax](https://triton-lang.org/main/getting-started/tutorials/02-fused-softmax.html)
- [Triton matrix multiplication](https://triton-lang.org/main/getting-started/tutorials/03-matrix-multiplication.html)
- [Triton kernel 与 torch.compile](https://docs.pytorch.org/tutorials/recipes/torch_compile_user_defined_triton_kernel_tutorial.html)
- [CUDA C++ 最佳实践](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html)
- [Compute Sanitizer](https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html)
- [Nsight Compute 分析指南](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
