# DPU Phase 4：跨节点 VXLAN 与卸载

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前核对方向入口中的硬件、软件基线、公共参数和权限约定。本文件仅记录方法，任务状态保持待执行，直至具备对应操作记录和原始数据。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | DPU-P4-01 VXLAN 场景与封装调研 | 区分 underlay 和 overlay | 分析 VTEP、VNI、UDP 4789、封装与 MTU | 两节点、可达物理网络 | 理解二层租户网络如何跨越三层网络 |
| [ ] | DPU-P4-02 两节点 VF 虚拟机直连基线 | 排除物理网络和 VF 基础问题 | rep↔uplink，VM 配同一测试子网后打流 | 每节点 CX5、一个 VF、一个 VM | 先测无隧道路径，后续才可区分封装开销 |
| [ ] | DPU-P4-03 VXLAN 跨节点通信 | 构造 overlay 数据路径 | 两侧 OVS 配固定 VNI、local/remote IP、静态转发 | 同上，underlay MTU 足够 | 使用最小静态拓扑，减少控制面变量 |
| [ ] | DPU-P4-04 隧道卸载对照与报告 | 判断封装/解封装是否落硬件 | 复用 Phase 3 矩阵、流表和物理口计数 | 支持对应动作的 CX5/固件/驱动组合 | VXLAN 互通不代表 VXLAN 已卸载，必须检查封装动作和命中 |

## 2. DPU-P4-01/02：物理网络与无隧道基线

VXLAN 常用于跨机架租户二层网络与云虚拟网络。VNI 为 24 位逻辑网络标识，VTEP 执行封装与解封装。VXLAN 本身不提供加密或身份认证，不能把它作为安全边界。

两台主机分别完成 SR-IOV、switchdev、VF 直通与 OVS 安装。A、B 各保留一个实验 VF 和对应 representor，关闭 Phase 1 / Phase 2 仍占用资源的其他端点。

通过 `devlink port show` 找到各自主机的**物理上联 representor/netdev**，记为 `UPLINK`；某些 CX5 配置下即为 `$PF`。不能把数据 VF 接口当作 uplink。先使用一张专用 `br-direct`，配置 rep↔uplink 的双向流，让两台 VM 在物理二层实验网中使用 `192.0.2.11/24`、`192.0.2.12/24` 互通：

```bash
export UPLINK=enp65s0f0
sudo ovs-vsctl add-br br-direct -- set Bridge br-direct fail_mode=secure
sudo ovs-vsctl add-port br-direct "$REP0" -- set Interface "$REP0" ofport_request=1
sudo ovs-vsctl add-port br-direct "$UPLINK" -- set Interface "$UPLINK" ofport_request=2
sudo ip link set "$REP0" up
sudo ip link set "$UPLINK" up
sudo ovs-ofctl add-flow br-direct 'in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-direct 'in_port=2,actions=output:1'
```

执行前从旧桥移除这两个端口，确认没有 IP/路由依赖；一个接口不能同时属于两个桥。物理交换机为两端配置同一隔离实验 VLAN。先 ping，再按 Phase 3 方法测无隧道基线，保存速率、丢包、CPU、端口及流表证据。

## 3. DPU-P4-03：配置 underlay 与 VXLAN

完成直连基线后停止发流，从 `br-direct` 移除实验端口。示例采用 OVS internal 端口承载 underlay IP，物理口加入 `br-underlay` 后不再保留主机 IP。该网段不得和管理网或其他路由冲突。

| 节点 | underlay / VTEP IP | VM overlay IP | VNI |
| --- | --- | --- | --- |
| A | 198.51.100.11/24 | 192.0.2.11/24 | 100 |
| B | 198.51.100.12/24 | 192.0.2.12/24 | 100 |

两节点分别设置 `LOCAL` 和 `REMOTE`。A 侧如下，B 侧交换两个 underlay 地址：

```bash
export LOCAL=198.51.100.11
export REMOTE=198.51.100.12
sudo ovs-vsctl add-br br-underlay -- set Bridge br-underlay fail_mode=secure
sudo ovs-vsctl add-port br-underlay "$UPLINK"
sudo ip link set "$UPLINK" up
sudo ovs-vsctl set Interface "$UPLINK" mtu_request=1700
sudo ovs-vsctl set Interface br-underlay mtu_request=1700
sudo ip link set br-underlay up
sudo ip addr add "$LOCAL/24" dev br-underlay
sudo ovs-ofctl add-flow br-underlay 'priority=0,actions=NORMAL'
ping -c 10 "$REMOTE"
ip route get "$REMOTE"
ip neigh show dev br-underlay
```

物理交换机端口也须支持相应 MTU；用 `ping -M do -s 1672 "$REMOTE"` 检查 1700 B IPv4 路径 MTU，失败时先排除中间 MTU、防火墙和 ICMP 策略。不允许仅调宿主机而忽略交换机限制。

```bash
sudo ovs-vsctl add-br br-overlay -- set Bridge br-overlay fail_mode=secure
sudo ovs-vsctl add-port br-overlay "$REP0" -- set Interface "$REP0" ofport_request=1
sudo ovs-vsctl set Interface "$REP0" mtu_request=1600
sudo ovs-vsctl add-port br-overlay vxlan100 -- \
  set Interface vxlan100 type=vxlan ofport_request=2 \
  options:local_ip="$LOCAL" options:remote_ip="$REMOTE" \
  options:key=100 options:dst_port=4789
sudo ovs-ofctl add-flow br-overlay 'priority=100,in_port=1,actions=output:2'
sudo ovs-ofctl add-flow br-overlay 'priority=100,in_port=2,actions=output:1'
```

客户机 VF MTU 设置为 1600，保留 overlay IP，确保 PF/硬件 vport 最大 MTU 允许。overlay 与 underlay 网段相互独立。放行仅两台 VTEP 之间的 UDP 4789 和实验所需 ICMP，保留其他防火墙策略。

验证客户机双向 ping，再在软件转发组使用：

```bash
sudo tcpdump -ni "$UPLINK" udp port 4789
sudo ovs-vsctl --columns=name,ofport,error,options list Interface
sudo ovs-appctl dpctl/dump-flows -m
```

核对外层 VTEP IP、UDP 4789、VNI 100 与内层 VM 地址。这里“出网为 VXLAN”指 VM 跨节点流量以 VXLAN 形式从物理口发出，不包含公网 NAT/Internet 出口。若题目另需 Internet 出口，应独立设计网关、路由及安全策略，不能与本项混为一谈。

## 4. DPU-P4-04：开关卸载与报告

按 Phase 3 流程分别关闭/开启 `hw-offload` 并重启。保持 underlay、overlay、VNI、MTU、VM CPU、消息长度和客户机分段聚合配置不变，执行 TCP/UDP、四种消息长度、1/4/8 并发。

检查两端：

```bash
sudo ovs-appctl dpctl/dump-flows type=offloaded
sudo tc -s filter show dev "$REP0" ingress
sudo tc -s filter show dev "$UPLINK" ingress
sudo ethtool -S "$UPLINK"
```

卸载证据应覆盖 VM→隧道封装和隧道→VM 解封装两个方向；只有 rep↔rep 或普通 L2 动作卸载，不足以证明 VXLAN 卸载。若当前 CX5/固件/驱动不支持某动作，保留软件路径实测并列出限制，不手动添加绕过 OVS 的规则伪造卸载。

报告按 Phase 3 表增加：节点、VTEP、VNI、underlay/overlay MTU、封装开销、分片状态、两端 CPU、封装/解封装卸载证据。分别比较“跨节点无隧道软件路径”“VXLAN 软件路径”“VXLAN 硬件路径”，不把不同拓扑的差异全部归因于卸载。硬件 TC 统计可能不含以太网头，字节计数应按同一层归一化再比较。
