# DPU Phase 3：VF 直通性能与分段聚合卸载

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P3-01 建立测试矩阵 | 统一报文、并发与测量口径 | 固定 TCP/UDP、128/256/512/1500 B、1/4/8 并发 | 单节点 CX5、两台 VF VM | 分清应用消息长度和线上帧长，避免错误比较 |
| [ ] | DPU-P3-02 OVS 软件与硬件转发对照 | 测量 eSwitch 流表卸载影响 | 同一拓扑切换 hw-offload，收集流表和 CPU | 同上 | 拓扑、规则、CPU 和客户机卸载状态保持一致 |
| [ ] | DPU-P3-03 TSO/LRO/GRO/GSO 对照 | 区分分段聚合与交换卸载收益 | 客户机和相关宿主接口检查 ethtool，分组启停 | 支持相应特性的 VF/驱动 | 不把分段聚合统称为完整 TOE |
| [ ] | DPU-P3-04 专业方向分析 | 定位小包、队列、CPU 或硬件瓶颈 | 对照 pps、吞吐、丢包、CPU、NUMA 与流命中 | 同上 | 用观测结果解释路径开销，而非预设结论 |

## 2. DPU-P3-01：长度、并发与结果口径

| 维度 | 取值 |
| --- | --- |
| 协议/测试 | `TCP_STREAM`、`UDP_STREAM`；延迟单独增加 `TCP_RR`/`UDP_RR`，不从 STREAM 推算 |
| 应用发送长度 | 128、256、512、1500 字节；TCP 为每次发送长度，UDP 为数据报有效载荷 |
| 并发 | 1、4、8 个 netperf 进程，称为并发流；不是一个 netperf 进程中的多线程 |
| OVS 卸载 | 关闭、开启；每组都确认实际路径 |
| 分段聚合配置 | 全关、可支持项全开；再按需逐项对照 |
| 时间/重复 | 每条流预热 10 秒，正式 60 秒，每格至少 3 次；轮换 A/B 顺序减小热状态偏差 |
| 方向 | A→B、B→A 分别测量；双向同时发送另列，不与单向混合 |

基础全因子矩阵为 `2 × 4 × 3 × 2 × 2 = 96` 格，每方向至少 288 次重复；单项卸载诊断与预热额外计时。顺序执行已约需数小时，须预留配置切换、失败重试和分析时间。

**1500 字节的定义：**1500 B UDP payload 加 IPv4/UDP 头为 1528 B，超过 MTU 1500。若测无分片数据报，同机可将 VM、VF、representor 及相关路径 MTU 设为 1600，Phase 4 将 underlay 至少设为 1650（示例 1700）并核对交换机支持。若硬件只能 MTU 1500，保留该测试但明确记录 IP 分片及重组，不能称为“1500 B 以太网帧”。TCP 的 `-m` 不能保证 TCP segment 或线速帧长；若要求固定线速帧长，另加 TRex/MoonGen/testpmd 等包发生器测试，不替代 netperf 数据。

## 3. DPU-P3-02：切换 OVS 卸载与证据

在无发流、允许短暂中断时切换。以下为本文件直接启动的 OVS 实例重启方式：

```bash
sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=false
sudo ovs-appctl -t ovs-vswitchd exit
sudo "$OVS_PREFIX/sbin/ovs-vswitchd" --pidfile --detach --log-file
sudo ovs-vsctl get Open_vSwitch . other_config
```

开启组将 `false` 改为 `true`。按驱动要求为 representor/上联开启 `hw-tc-offload`，并检查实际值：

```bash
sudo ethtool -K "$REP0" hw-tc-offload on
sudo ethtool -K "$REP1" hw-tc-offload on
ethtool -k "$REP0"
ethtool -k "$REP1"
sudo ovs-appctl dpctl/dump-flows -m
sudo ovs-appctl dpctl/dump-flows type=offloaded
sudo tc -s filter show dev "$REP0" ingress
sudo tc -s filter show dev "$REP1" ingress
sudo ovs-ofctl dump-flows br-sriov
```

部分特性由 PF/驱动统一控制；不支持的 `ethtool` 命令应记录返回错误及驱动说明，不能忽略。开启组需检查与测试五元组对应的 `offloaded:yes`、TC `in_hw` 及命中计数增长；关闭组确认重启后无遗留卸载流，流量经过软件 datapath。OpenFlow 逻辑表本身不提供硬件落表的充分证据。

不要用 `tc-policy=skip_sw` 作为常规对照设置：不支持卸载的流会丢失软件回退条件，改变测试语义。硬件组出现未卸载流应标记为“部分卸载/卸载失败”，分析动作、资源和日志，不计作完整卸载组。

## 4. 发流、监控与数据保存

在接收 VM 上启动 netserver，数据网络只允许实验对端访问控制端口和数据端口。netperf 数据连接可能使用动态端口；若需固定范围，应按所选版本参数配置或仅在隔离数据网按对端 IP 放行。

```bash
# 接收客户机
sudo netserver -L 192.0.2.12 -p 12865
```

发送客户机示例；每个测试组合创建独立目录，目录名应含 OVS 卸载、TSO 等状态、协议、长度、并发、方向和重复编号：

```bash
export PEER=192.0.2.12
export OUT=$HOME/netperf-results/kernel-sw/features-off/TCP_STREAM/128/n4/repeat1
mkdir -p "$OUT"
netperf -H "$PEER" -p 12865 -t TCP_STREAM -l 10 -- -m 128 > "$OUT/warmup.log" 2>&1
PIDS=()
for i in 1 2 3 4; do
  netperf -H "$PEER" -p 12865 -t TCP_STREAM -l 60 -- -m 128 \
    > "$OUT/flow-$i.log" 2>&1 &
  PIDS+=("$!")
done
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=1
done
test "$FAILED" -eq 0
```

此段在 Bash 中运行，启动的是有界测量进程；例中单流预热仅演示参数。正式矩阵须将预热也改为与测量相同的并发数，等待其全部完成后再正式发流。UDP 将命令中的 `TCP_STREAM` 改为 `UDP_STREAM`，并同步更新输出目录；按矩阵替换 `-m`，并发 1、8 对应实际进程数。每个进程返回值和日志都要保留；任一失败时该格标为失败，不聚合成成功结果。测反向时在 VM-a 启动服务，将对端地址改为 `192.0.2.11`。

UDP 同时记录发送端 offered load、接收端 throughput 和包数，丢包率以包数计算；不能只相加发送端结果。多流总吞吐相加接收侧同一时间窗口的吞吐；并发启动偏差需记录，严格同步时使用统一开始屏障。TCP 重传从客户机 `nstat`/`ss -ti` 和抓包辅助分析；UDP 用 netperf 接收统计及网卡丢弃计数交叉核对。

在宿主机与两个客户机的独立终端采样，文件名按实际运行编号设置：

```bash
mpstat -P ALL 1 70 > cpu.log
pidstat -t -p "$(pidof ovs-vswitchd)" 1 70 > ovs-cpu.log
```

两条命令分别启动，覆盖同一发流时间窗；客户机采集 `mpstat`，不运行没有 OVS 进程的 `pidstat` 命令。发流前后保存 `ip -s link`、`ethtool -S`、`nstat`、OVS/TC 流表。记录 vCPU、QEMU、IRQ 的 CPU 亲和性与 NUMA；监控进程不要与发流进程争用同一隔离核。初次测试保持相同默认绑核，后续 NUMA/IRQ 调整单列实验。

## 5. DPU-P3-03：分段与聚合卸载

TSO/GSO 负责发送分段，LRO/GRO 负责接收聚合，和 OVS 流表卸载是两个维度。TOE 严格指 TCP Offload Engine，完整卸载 TCP 协议栈；不能把 CX5 的 TSO、LRO、GRO、GSO 测试描述为完整 TOE 测试。

两个客户机先对实际 VF 接口保存：

```bash
ethtool -k eth0 > features-before.txt
sudo ethtool -K eth0 tso off gso off gro off lro off
ethtool -k eth0 > features-off.txt
```

`eth0` 必须替换为客户机实际数据接口名。开启组仅开启查询显示可修改且驱动支持的项：

```bash
sudo ethtool -K eth0 tso on gso on gro on
# lro 仅在非 fixed、驱动支持且拓扑允许时单独开启。
sudo ethtool -K eth0 lro on
ethtool -k eth0 > features-on.txt
```

某项为 `[fixed]` 或命令返回不支持时，记录“不可切换”，用实际状态命名该组，不写“全部开启”。如一组命令部分成功，逐项查询与设置，避免把部分状态当成完整结果。宿主机相关接口也需保存状态；若一并修改，作为明确的端到端配置组，不能偷偷改变其他变量。TSO 对 UDP 不等同于 UDP segmentation offload，不应据此推断 UDP 分段效果。

在固定 OVS 卸载状态下，以“可支持项全关”为起点，分别测试仅 GSO、仅 GRO、TSO+其必需依赖、LRO+其必需依赖；记录驱动自动调整的依赖项。一次只引入一个有效配置差异。

## 6. DPU-P3-04：分析任务与报告表

专业方向分析聚焦三个问题：小消息是否受 CPU/pps 限制；并发是否改善队列利用或只增加争用；硬件落表后软件 CPU 降低是否转化为吞吐/丢包改善。比较时说明 PCIe、NUMA、CPU 频率和网卡速率限制。

| 运行编号 | OVS 实际路径 | TSO/GSO/GRO/LRO 实际值 | 协议 | 消息 B | 流数 | 接收 Gbit/s | 接收 pps | UDP 丢包率/TCP 重传 | 主机与 VM CPU | 原始日志 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 待执行 | 待记录 | 待记录 | 待记录 | 待记录 | 待记录 | — | — | — | — | — |

每组报告至少给出重复值、均值、标准差及异常原因。吞吐增益为 `(开启-关闭)/关闭×100%`，CPU 降幅为 `(关闭-开启)/关闭×100%`；分母为零时不计算。CPU 需说明“一核 100%”或“全机归一化”等口径。没有延迟测试就不报告延迟百分位；没有功耗计就不报告能效。
