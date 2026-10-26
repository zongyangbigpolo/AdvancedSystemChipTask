# GPU Phase 4：同机多 GPU 通信

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | GPU-P4-01 多卡拓扑与 P2P 能力确认 | 确定通信经过 PCIe、NVLink 或主机内存 | topo、P2P 查询、带宽与延迟样例 | 同机两张 GPU；NVLink 为条件项 | 设备数量不代表具备直接互访能力 |
| [ ] | GPU-P4-02 NCCL 构建和集合通信 | 建立 AllReduce/AllGather 基线 | 固定 NCCL 与 nccl-tests，验证结果和带宽 | 至少两卡及兼容 CUDA | 标准集合通信便于观察消息规模与拓扑影响 |
| [ ] | GPU-P4-03 P2P 路径对照 | 量化直接互访与回退路径差异 | 默认配置对比 `NCCL_P2P_DISABLE=1`，保留日志 | 支持 P2P 的 GPU 对 | 只禁用一个传输能力，不把配置意图当实际路径 |
| [ ] | GPU-P4-04 多卡报告 | 识别小消息和大消息瓶颈 | 扫描长度、记录 algbw/busbw、正确性和拓扑 | 同上 | 区分算法带宽与换算后的总线带宽 |
| [ ] | GPU-P4-05 单机 DDP 与扩展效率 | 从集合通信进入真实反向传播 | torchrun、一进程一卡、全局 batch 固定和参数校验 | 同机两 GPU | 排除扩大 batch、重复采样或漏同步导致的假加速 |
| [ ] | GPU-P4-06 激活重计算与梯度累积 | 研究显存与吞吐的交换关系 | checkpoint、no_sync、相同有效 batch 对照 | 单/双 GPU，模型适度增大 | 区分重计算成本、通信次数和实际 optimizer step |

## 2. GPU-P4-01：P2P 核查

GPU 需在宿主机 NVIDIA 驱动下使用；若刚完成直通实验，先关 VM 并按恢复流程重新绑定。不能在 VFIO 持有期间同时跑裸机 CUDA。

```bash
nvidia-smi topo -m
cd "$LAB/src/cuda-samples"
make -C Samples/5_Domain_Specific/p2pBandwidthLatencyTest -j"$(nproc)"
./Samples/5_Domain_Specific/p2pBandwidthLatencyTest/p2pBandwidthLatencyTest
```

查询每对 GPU 是否支持 peer access。相同 PCIe switch、跨 CPU socket、NVLink 连接分别记录；不支持 P2P 时保留回退测试，但不能生成 P2P 开/关收益。普通 CUDA IPC/P2P 不能假设跨 VM 可用。

## 3. GPU-P4-02：固定软件与单机 NCCL

按 NCCL 安装指南安装与 CUDA/驱动兼容的开发库，记录包版本与库路径。然后固定 nccl-tests commit：

```bash
cd "$LAB/src"
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests
# 将下列值替换为经过核对、适配所选 CUDA/NCCL 的完整 commit。
export NCCL_TESTS_COMMIT='<固定的完整提交哈希>'
git checkout "$NCCL_TESTS_COMMIT"
make -j"$(nproc)" CUDA_HOME="$CUDA_HOME" NCCL_HOME=/usr
CUDA_VISIBLE_DEVICES=0,1 NCCL_DEBUG=INFO \
  ./build/all_reduce_perf -b 128 -e 128M -f 2 -g 2 -w 10 -n 100 -c 1
```

此处 `-g 2` 是一个进程/线程使用两张卡。随后运行 `all_gather_perf`，保持参数一致。分别为两种集合通信补测必需长度 1500 B（按所选 datatype 的元素大小对齐）：

```bash
CUDA_VISIBLE_DEVICES=0,1 ./build/all_reduce_perf \
  -b 1500 -e 1500 -g 2 -w 10 -n 100 -c 1
CUDA_VISIBLE_DEVICES=0,1 ./build/all_gather_perf \
  -b 1500 -e 1500 -g 2 -w 10 -n 100 -c 1
```

`-b 128 -f 2` 覆盖 128、256、512 等倍增点，不会覆盖 1500。记录程序实际打印的 size，某些 collective 会按 rank/元素数调整请求长度。显存不足时降低上限并记录，不能关闭正确性检查来绕过失败。

## 4. GPU-P4-03：传输对照与判定

同一测试在两个独立进程环境运行：

```bash
# 默认路径：不继承先前的禁用项
env -u NCCL_P2P_DISABLE NCCL_DEBUG=INFO CUDA_VISIBLE_DEVICES=0,1 \
  ./build/all_reduce_perf -b 128 -e 128M -f 2 -g 2 -w 10 -n 100 -c 1
# 禁用 NCCL 的 P2P 路径，观察实际回退
NCCL_P2P_DISABLE=1 NCCL_DEBUG=INFO CUDA_VISIBLE_DEVICES=0,1 \
  ./build/all_reduce_perf -b 128 -e 128M -f 2 -g 2 -w 10 -n 100 -c 1
```

这不等于物理关闭 NVLink 或拆除 PCIe 链路。检查 NCCL 日志实际选择的传输通道；若原配置本就未使用 P2P，则两个结果不能称为 P2P 加速比较。进程退出后环境隔离，避免后续跨节点实验继承禁用项。

测试矩阵为 AllReduce/AllGather × 默认/P2P 禁用 × 消息长度，每格至少 3 轮，区分 in-place/out-of-place。正确性要求错误计数为 0；失败时保留日志并停止该格性能归纳。

## 5. GPU-P4-04：报告口径

`algbw` 是算法数据量与时间换算，`busbw` 是按 collective 和 rank 数换算的指标，不是硬件传感器直接测得的链路带宽。例如 N 个 rank 的 AllReduce 常用 `busbw = algbw × 2(N-1)/N`，AllGather 使用其对应公式；与所选 nccl-tests 版本说明核对，且不把两个指标相加。

| GPU 对/拓扑 | collective | 实际 size B | rank 数 | 默认/禁用 P2P | 实际传输 | 时间 | algbw | busbw | 错误数 | 日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | 待记录 | 待记录 | — | — | — | — | — |

NVLink 不存在时只分析 PCIe 路径；一张卡时本阶段多卡任务不执行，不将单 rank collective 当成双卡通信。

## 6. GPU-P4-05：可审查的 DDP 训练程序

参考 [PyTorch DDP 官方教程](https://docs.pytorch.org/tutorials/intermediate/ddp_tutorial.html)，在 Phase 3 单卡训练基础上编写 `$LAB/src/ddp_train.py`。明确这是待完成的实验程序，需实现以下契约后才能运行启动命令：

1. 从 `LOCAL_RANK` 设置 CUDA device，从 torchrun 环境初始化 `nccl` 进程组；一进程一卡，设置有界 timeout，结束时销毁进程组。
2. 使用相同初始权重、数据集和 loss；DDP 包装模型。随机种子、每个 rank 的数据索引和样本数均可记录。
3. 使用 `DistributedSampler` 或等价的确定性分片，按 epoch 设置顺序；检查重复、遗漏和 padding。第一组固定样本总数可整除 world size，避免 sampler 补样本改变语义。
4. 支持单卡/双卡、全局 batch、累积步数、固定步数、输出目录；打印 global rank、local rank、GPU UUID/BDF、实际局部/全局 batch。
5. 每步检查 loss 与梯度有限性，在更新完成后比较各 rank 参数；不是只检查 loss 下降。

程序完成后运行，例如每次 optimizer step 的有效全局 batch 为 128：

```bash
torchrun --standalone --nproc-per-node=1 "$LAB/src/ddp_train.py" \
  --global-batch 128 --steps 200 --output "$LAB/results/ddp-one"
torchrun --standalone --nproc-per-node=2 "$LAB/src/ddp_train.py" \
  --global-batch 128 --steps 200 --output "$LAB/results/ddp-two"
```

这些参数是作业需要实现的接口，不是官方示例自带选项。单卡局部 batch=128，双卡各 64；使用相同样本顺序，预热和正式步骤分开。统计区间前 barrier 和设备同步，区间末再次同步，汇总最慢 rank 耗时；吞吐为全局有效样本总数/该时间。

另建“固定每卡 batch”的弱扩展组，但与固定全局 batch 的强扩展分表。强扩展效率按 `单卡时间 / (N × N卡时间)` 计算，要求相同总工作量。检查 CPU 数据供给与线程争用，不能只依据 NCCL 带宽推断模型扩展效率。

**验收：**同一批样本的一步更新与单卡参考在预设容差内，各 rank 参数一致；三轮吞吐与时间、数据分片证据、训练代码和通信 trace 齐全。普通 FP32 非确定性归约可能带来误差，使用容差而非强求跨硬件位级一致。

## 7. GPU-P4-06：显存换计算与减少无效通信

参考 [PyTorch activation checkpoint 文档](https://docs.pytorch.org/docs/2.5/checkpoint.html)，在相同模型上加入可开关的 checkpoint，显式指定所选版本支持的 `use_reentrant=False`，处理随机状态与有状态层。普通运行和重计算必须保持前向语义一致。

固定有效全局 batch=128，比较：

| 配置 | 每 rank microbatch | 累积步数 | 检查点 | 主要问题 |
| --- | --- | --- | --- | --- |
| A | `128 / world_size` | 1 | 关 | 原始基线 |
| B | `32 / world_size` | 4 | 关 | microbatch 与数据相同，但 optimizer 更新次数不变 |
| C | 同 B | 4 | 开 | 用重计算降低激活占用，记录额外计算 |

此矩阵仅在 microbatch 可整除且输入 shape 合法时使用。每次 microbatch loss 按等权累积归一化；最后一批样本数不同需按真实数量加权。DDP 的 `no_sync()` 必须同时包围前向和反向，仅前几次 microbatch 使用，最后一次正常同步。AMP 下一个有效 batch 只在完整累积后执行 scaler/optimizer update。

先比较相同有效 batch 的一步梯度与参数，确认没有把累积变成多次 optimizer step；再测 `max_memory_allocated`、ms/optimizer-step、样本/s和通信次数。checkpoint 是激活重计算，不是磁盘训练恢复文件。

交付三组配置、梯度/参数误差、内存峰值、时间线及解释。若基线 OOM，记录失败而不伪造时间；另选三组均可运行的规模比较性能。
