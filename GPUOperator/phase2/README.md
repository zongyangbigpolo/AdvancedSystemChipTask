# GPUOperator Phase 2：CUDA 逐元素、归约与反向

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

需要支持所选 CUDA/PyTorch 组合的单 GPU。先实现可验证的 FP32/FP64 CUDA 路径，再增加低精度，禁止在扩展内默认全设备同步掩盖 stream 问题。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | OP-P2-01 逐元素 CUDA kernel | 正确分配输出并启动线程 | grid-stride/尾部 guard、输入设备 guard、当前 stream | 单 CUDA GPU | 数据范围、设备与执行流均属于算子正确性 |
| [ ] | OP-P2-02 稳定 row softmax | 掌握并行归约和局部存储 | block max/sum、FP32 累加、尾部 mask | 同上 | 避免直接 exp 溢出与非法线程访问 |
| [ ] | OP-P2-03 反向与数值梯度 | 实现框架可用训练接口 | register_autograd、独立公式、FP64 gradcheck | 同上 | 前向数值正确不代表梯度正确，opcheck 不替代求导检查 |
| [ ] | OP-P2-04 stream 与内存安全 | 验证异步生命周期和尾块 | 非默认 stream、sanitizer、偏移视图、错误测试 | 同上；多设备测试需两卡 | 不靠默认流或逐次同步碰巧正确 |

## 2. OP-P2-01：scale_add 内核和封装

对 `out=x+alpha*y`，每个线程访问合法线性索引。采用足够位宽索引和安全的 grid 计算，空输出直接返回；先连续 FP32/FP64，再按明确的累加/转换策略支持 FP16/BF16。

C++ 入口检查 x/y 的设备、shape、dtype、布局和 scalar 参数，使用输入设备 guard，并在该设备的 PyTorch **current CUDA stream** 上 launch。输出通过框架分配，与输入同设备，不能硬编码 device 0 或 default stream。

使用所选 PyTorch 提供的 launch 错误检查；这仅能立即检查 launch 等错误，异步非法访问由测试同步或 sanitizer 暴露，不能声称检查宏保证所有运行时错误已经返回。

对非连续输入按首版契约拒绝；增加通用 stride 版本时使用独立入口/标签，记录额外开销。不能通过每次 `.contiguous()` 后测 kernel-only 来隐藏转换成本。

## 3. OP-P2-02：softmax 的归约

每行一个 block 的基础方案：计算 max，求 `exp(x-max)` 的 sum，再归一化。跨 warp 归约使用合法 mask 和 shared memory，同步前确保所有需要的线程一致参与；尾部 lane 用 max 的单位元 -Inf、sum 的单位元 0。

浮点指数和求和明确类型，FP16/BF16 输入可用 FP32 中间值，FP64 梯度路径使用真正 double 中间值，不能把 double 偷转成 float。

测列数 1/31/32/33/1001/4096，以及不支持的 4097；记录行宽上限内的寄存器/shared memory 使用。M=0 不 launch，N=0 按契约拒绝。特殊值输入按 Phase 1 定义与参考对比；全 -Inf 行不能把分母强制为 1 后给全零结果而不说明语义变化。

## 4. OP-P2-03：autograd 注册

在加载 C++ schema 和 CUDA backend 后，按固定版本的 `torch.library.register_autograd` 注册反向及必要的 context 保存：

| 算子 | 反向定义 |
| --- | --- |
| scale_add | `dx=grad_out`，`dy=alpha*grad_out`；alpha 是非 Tensor scalar，不提供其梯度 |
| row_softmax | 保存输出 y，`dx = y * (grad_out - sum(grad_out*y, dim=-1, keepdim=True))` |

基础反向可以用可求导 PyTorch 原生操作实现，后续再写融合 backward；不要在带梯度测试中从 Tensor 提取 scalar 数值造成图断开。

在 FP64 CUDA **实际待测路径**对小张量做 gradcheck，固定 seed、避免过于极端输入。检查随机 `grad_out` 的向量积，与独立公式一致；不能只使用全 1 上游梯度，因为 softmax 对该梯度可能全零，掩盖实现错误。

低精度路径和不支持 FP64 的后端另做解析梯度对照并报告类型，不能拿 CPU 的 gradcheck 通过宣称 CUDA/Triton 通过。二阶梯度若未实现/验证，明确列为不支持；训练中请求该功能时不能静默给零。

## 5. OP-P2-04：执行流、越界与验收

写测试在非默认 `torch.cuda.Stream` 上生成输入、调用算子、消费输出，再通过 event/stream wait 与检查流建立依赖。测试中同步发生在读取结果前，不在每个算子内部 `cudaDeviceSynchronize`。额外测试连续且 storage offset 非零的视图。

若有两卡，让当前设备与输入设备不同，确认 guard 后分配和 launch 仍属于输入设备；只有一张卡则明确跳过多设备项，保留单卡非默认流测试。

代码实现和重新构建后：

```bash
python -m pytest "$OPLAB/tests/test_forward.py" "$OPLAB/tests/test_gradients.py" \
  "$OPLAB/tests/test_streams.py" -q
compute-sanitizer --tool memcheck --error-exitcode 99 \
  python -m pytest "$OPLAB/tests/test_forward.py" -q
compute-sanitizer --tool racecheck --error-exitcode 99 \
  python -m pytest "$OPLAB/tests/test_streams.py" -q
```

按固定工具版本增加 synccheck；不同工具覆盖范围不同，racecheck 无报警不证明不存在任意 global memory 竞争。交付源码、前向/反向误差、FP64 检查、尾块和 stream 测试、sanitizer 日志；sanitizer 开销不用于性能结论。
