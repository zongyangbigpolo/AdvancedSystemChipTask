# Storage Phase 2：io_uring 异步引擎与数据校验

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

复用已通过校验的普通实验文件。初始模式不开 SQPOLL、IOPOLL 或固定 buffer；先完成通用提交/完成状态机，再增加优化。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | ST-P2-01 io_uring 异步引擎 | 正确管理并发请求与完成 | liburing、SQE/CQE、请求池、显式 offset | 支持 io_uring 的 Linux 主机 | 用户态库不等于内核支持，需明确探测与失败 |
| [ ] | ST-P2-02 数据与异常回归 | 防止重用 buffer、错配完成和错误吞没 | generation/CRC、短 I/O、超时/取消、资源清理 | 普通实验文件 | 高吞吐前先证明每个请求有唯一终态 |
| [ ] | ST-P2-03 队列深度矩阵 | 寻找并发与尾延迟拐点 | QD=1/8/32，4/16/128 KiB，与 fio 同条件对照 | 专用 SSD；VM 可做功能 | 把增加负载与真正降低单次开销分开 |
| [ ] | ST-P2-04 批提交与 CPU 分析 | 量化 syscall 摊销和吞吐代价 | 批量 1/8、相同 QD、CPU/延迟直方图 | 同上 | 一次改变一个优化项，不同时启用多种轮询模式 |

## 2. ST-P2-01：请求状态机

参考固定版本 [liburing 示例](https://github.com/axboe/liburing/tree/master/examples)，在 `$LAB/src/uring_io.c` 实现与同步程序相同的数据格式和读写语义。新增 `--qd`、`--submit-batch`、`--timeout-ms` 参数，不默认回退到同步引擎。

```text
free → prepared(SQE) → submitted → completed/failed → free
```

为每个请求保留 ID、operation、offset、剩余长度、buffer、generation、起止时间及终态。使用 `user_data` 将 CQE 精确映射回请求，不假设完成顺序等于提交顺序。SQE 准备数量、实际提交返回数量和在途数量分别记账，短提交不能当作全部提交。

`cqe->res < 0` 表示负 errno，不从无关的全局 `errno` 取错误；正的短读写按剩余区间处理，意外 EOF 或零进展终止该请求。每个 CQE 只消费一次，buffer 只有在相关 I/O 确认完成后才能重用。

```bash
cc -std=c11 -O2 -g -Wall -Wextra -Werror \
  "$LAB/src/uring_io.c" -o "$LAB/build/uring_io" \
  $(pkg-config --cflags --libs liburing)
```

程序应记录 ring 初始化特性和相关错误。内核或策略不允许时返回明确的“不支持/被拒绝”，不要求 root 或全局降低限制来掩盖问题。

## 3. ST-P2-02：正确性与资源生命周期

先单请求，后 QD=8/32。每个写请求使用不重叠且已分配的区间，读回比较同步程序的参考数据。不同格式的 fio 数据不能直接喂给自写 CRC 解码。

| 用例 | 构造 | 判定 |
| --- | --- | --- |
| 完成乱序 | 多 offset 并发 | 每块 ID/CRC 正确，无错位 |
| 短 I/O | 包装层限定每次最多处理部分长度 | 补齐剩余部分，不重复覆盖起始偏移 |
| 边界和对齐 | 非法 offset/长度、超范围、buffer 对齐不足 | 在接口或 CQE 中明确失败，无静默回退 |
| 超时/取消竞争 | 独立请求槽、有限超时 | 取消 CQE 与原请求 CQE 分开处理；取消成功不代表原 buffer 可提前释放 |
| 提前退出 | 收到终止请求后停止提交 | 排空或完成取消并回收，不留下仍引用用户内存的请求 |

普通文件 I/O 可能过快，无法稳定触发超时；此时用受控包装层验证状态机并注明未覆盖真实内核取消竞争，不编造“已通过”。错误注入不得通过阻塞共享设备完成。

用单元测试检查 `submitted = success + failed + inflight` 等计数不变量；退出时 inflight=0，无双重完成、丢失 CQE、buffer 越界或 fd 泄漏。CPU 侧可使用 ASan/UBSan 独立构建检查内存和整数错误，计时不使用 sanitizer。

## 4. ST-P2-03：同条件 fio 对照

使用 Phase 1 已初始化的 fio 文件，只读性能示例：

```bash
fio --readonly --name=uring-randread --filename="$TESTFILE" --size=1G \
  --allow_file_create=0 --ioengine=io_uring --rw=randread --bs=4k \
  --direct=1 --iodepth=32 --numjobs=1 \
  --time_based=1 --ramp_time=10 --runtime=60 \
  --randrepeat=1 --randseed=2026 \
  --output-format=json+ --output="$LAB/results/p2-uring-4k-q32-r1.json"
```

数据格式不参与纯性能读取时可比较吞吐，但自写校验运行仍用自己的数据文件。对齐文件大小、访问范围、CPU、direct、随机分布、block size、QD 和同步语义；只设置相同 seed 不保证两个发生器访问序列完全一致。需要严格序列时，先导出固定 offset 列表，让两者按各自支持的 trace/iolog 入口回放并核对。

基础矩阵为随机读/顺序读 × 4/16/128 KiB × QD 1/8/32，单 worker，每格三轮。写性能作为独立、限量的扩展，先排除同一块并发覆盖造成的校验歧义。不要用 `numjobs × iodepth` 代替实际在途分布，记录 fio 深度统计和自写计数。

## 5. ST-P2-04：批提交和报告

固定 QD=32，分别每次提交 1 和最多 8 个准备好的请求；buffer、offset 集、完成收割和 CPU 不变。测平均/P95/P99 应用延迟、IOPS、MiB/s、CPU、syscall 数和实际 in-flight。批量等待引入的排队时间应算在预先定义的应用延迟中，不通过推迟“开始计时”隐藏。

分别采短运行 strace/perf 和无采样正式运行；SQPOLL、IOPOLL、注册 buffer/文件若扩展执行，独立列组，检查内核和文件系统要求，并统计内核轮询线程 CPU。

| 引擎 | bs/QD/批量 | direct/同步策略 | 实际 in-flight | IOPS/MiB/s | 平均/P99 us | CPU | 错误/校验 | 原始数据 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | — | — | — | — | — |

交付异步源码、请求状态图、异常测试与返回码、fio 配置、原始直方图和三轮结果。与 fio 有差异时先检查单位、计时边界及访问模型，不默认自写程序更快。
