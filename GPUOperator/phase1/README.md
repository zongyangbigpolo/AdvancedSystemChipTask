# GPUOperator Phase 1：算子契约、参考实现与工程

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

本阶段交付定义、测试和可构建工程。CPU 单元测试可以无 GPU 执行，但不能据此勾选 CUDA 验收。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | OP-P1-01 数学与接口契约 | 消除后续数值和输入语义歧义 | 定义三个算子、schema、shape/dtype/alias | CPU 开发机即可 | 先明确支持范围再写 kernel，避免通过隐式拷贝掩盖问题 |
| [ ] | OP-P1-02 CPU 与框架参考 | 建立独立数值 oracle | CPU FP64、PyTorch 原生参考、固定数据 | CPU；GPU 参考需 CUDA 卡 | 参考代码不复用待测 kernel 的索引和归约实现 |
| [ ] | OP-P1-03 C++/CUDA 扩展工程 | 建立可重复构建与 dispatcher 注册 | CUDAExtension、TORCH_LIBRARY、版本记录 | 编译主机；CUDA 编译需匹配 Toolkit | 将框架契约和设备代码分层，不只靠 Python 包装 |
| [ ] | OP-P1-04 测试矩阵与计时器 | 统一边界、错误与测量口径 | pytest、JSON 结果、CPU/设备计时 | 功能可部分在 CPU；性能需 GPU | 先建立会失败的测试，再逐阶段实现使其通过 |

## 2. OP-P1-01：契约表

在实验项目 README 中为 `scale_add`、`row_softmax`、`matmul` 分别登记 schema。可使用 `labops::scale_add(Tensor x, Tensor y, float alpha) -> Tensor` 作为第一个接口；输出为新分配 Tensor，不修改或 alias 输入，没有隐含 broadcasting。

规定：

- FP32 为初始生产类型；FP64 路径用于后续 CUDA 数值梯度验证，FP16/BF16 只在实际实现与硬件支持后声明。
- 连续布局首版只支持 canonical contiguous，非连续明确拒绝；非零 storage offset 的连续视图要正确使用 Tensor 的实际 data pointer，不能假设指针总是分配基址。
- `row_softmax` 为 `[M,N]` 且 `N>0`，首版最大 N=4096；M=0 返回相同空形状但不 launch。范围外明确报错，不偷偷调用库。
- matmul 的 M/N=0 返回正确空输出，K=0 返回全零；不对空维做 modulo 或启动非法 grid。
- NaN/Inf、非有限 alpha 和精度容差均按预先定义的参考语义测试；不能只比较有限子集而忽略特殊值。

复杂 stride、in-place、out=、广播和二阶梯度不是默认能力，若扩展则单独写契约与测试。

## 3. OP-P1-02：参考数据

用 CPU FP64 实现清晰的定义，另用 `torch.add`、`torch.softmax`、`torch.matmul` 作独立框架参考。softmax 必须减去行最大值，比较 sum、非负性及实际输出，不仅检查总和为 1。

数据覆盖零、常数、正负交替、固定 seed 随机数、大幅值和极端尺度差。softmax 对“全 -Inf 行”“含 NaN/Inf 行”的结果按框架语义单列，允许其产生 NaN 时不能拿全有限断言误判。记录特殊值 mask 是否一致。

保存输入参数、种子、shape、dtype 和参考实现版本，不将大张量提交仓库。不能让测试双方意外读同一个输出 buffer 而总是相等。

## 4. OP-P1-03：工程结构与构建

在 `$OPLAB` 实现以下结构：

```text
pyproject.toml / setup.py
csrc/ops.cpp              schema、参数检查与 CPU 实现
csrc/elementwise.cu       逐元素 CUDA 实现
csrc/reduction.cu         归约 CUDA 实现
csrc/matmul.cu            GEMM
gpu_operator_lab/         加载扩展、fake、autograd 与 Triton 后端
tests/                   合约/数值/梯度/stream 测试
benchmarks/              可参数化性能与模型集成
```

先构建 CPU `scale_add` 并注册 CPU backend；CUDA 实现留待 Phase 2，调用未实现 backend 应明确报错，不能转 CPU 后宣称运行了 CUDA kernel。使用唯一 namespace，避免覆盖 PyTorch 自带算子。

通过 `torch.utils.cpp_extension.CUDAExtension` 和 `BuildExtension` 配置传统接口构建；CUDA 源码使用适配 PyTorch 版本的 C++ 标准与编译器，记录 `TORCH_CUDA_ARCH_LIST`、CUDA_HOME 和 ABI。不要把 CUDA Samples 的独立 nvcc 编译行当完整 PyTorch 扩展链接命令。

实现依赖清单及构建文件后执行：

```bash
python -m pip install --no-build-isolation -e "$OPLAB"
python -c 'import gpu_operator_lab; import torch; print(torch.ops.labops.scale_add)'
```

`--no-build-isolation` 要求当前独立环境已经安装固定的构建依赖与 PyTorch；缺少依赖应先补齐清单，不从任意下载源隐式拉取另一版框架。

## 5. OP-P1-04：测试与交付

制定 pytest 名称：`test_contract.py`、`test_forward.py`、`test_gradients.py`、`test_streams.py`、`test_compile.py`。不支持功能使用明确的 capability 条件 skip 并说明原因；不能把尚未开发的 CUDA 测试全部 skip 后记为通过。

初始 shape 覆盖：逐元素 0/1/31/32/33/1025/1000003 元素；softmax 行数 0/1/17，列数 1/31/32/33/1001/4096；matmul 用 1×1×1、32×32×32、127×65×33 和空维。

完成后执行 `python -m pytest "$OPLAB/tests/test_contract.py" -q`，保存收集、通过、失败和跳过数量。报告 JSON 包含配置、实际 backend、最大误差和错误信息。kernel 未实现时记录真实失败状态，后续阶段复用同一组测试。
