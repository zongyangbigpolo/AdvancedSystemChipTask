# Storage Phase 4：NVMe-oF 远程块存储

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

采用 SPDK Target + Linux NVMe/TCP Host，先 RAM 后端功能，再专用文件持久后端。无需解绑本地 NVMe；缺少第二物理节点时可用两 VM 但只报告虚拟环境功能。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | ST-P4-01 协议与网络规划 | 区分本地块、远程块、文件和对象接口 | NVMe-oF/TCP、RDMA 与 NFS/S3 概念对照，绘制拓扑 | 两 Linux 节点与专用数据网 | 不把挂载共享目录当成远程块设备开发 |
| [ ] | ST-P4-02 Target 控制面与后端 | 配置受限访问的远程 namespace | SPDK RPC、host NQN 白名单、Malloc/AIO 后端 | Target 主机、大页、实验文件系统 | RAM 排查协议，文件后端用于重启后数据核对 |
| [ ] | ST-P4-03 Host 连接与端到端校验 | 建立可证明归属的远程设备 | discover/connect、标识映射、有限范围写读验证 | Host 主机、nvme-tcp | 动态设备编号不稳定，先核对再写 |
| [ ] | ST-P4-04 网络/后端瓶颈对照 | 分离网络、CPU、介质贡献 | QD/块大小矩阵、两端采样、条件性 RDMA | 双节点；RDMA 需兼容 NIC/网络 | 固定后端比较传输，不混用 RAM/TCP 与 SSD/RDMA |

## 2. ST-P4-01：拓扑与前置条件

```text
Host 应用/fio → Linux nvme-tcp → 数据网 → SPDK TCP Target → bdev
                                                        ├─ LabMalloc0（易失）
                                                        └─ LabAio0（专用普通文件）
```

示例 Target=`198.51.100.41`，Host=`198.51.100.42`，TCP 4420；实际地址由实验环境分配，不与管理网冲突。核对双向路由、MTU、链路速率及防火墙，仅允许指定 Host 访问该 Target 服务端口。

NFS 是文件共享接口，S3 是对象接口，本阶段导出的 namespace 是块设备。不能在多个普通客户端同时挂载同一 ext4/XFS 来“共享数据”；本实验只允许一个 Host 写入，不引入分布式文件系统。

在 Host 读取 `/etc/nvme/hostnqn` 或按 nvme-cli 指南生成独立 host NQN，不复制其他主机身份。将其作为非秘密标识传到 Target；NQN 白名单不是密码认证，也不提供数据加密，实验必须留在隔离网络。

## 3. ST-P4-02：Target 配置

先按 Phase 3 配置固定版本 SPDK 和大页，不绑定 PCI 设备。停止旧实验实例，前台启动新 Target：

```bash
sudo "$SPDK/build/bin/nvmf_tgt" --no-pci -m 0x4 -s 512 -r "$RPC_SOCK"
```

另一个终端核对变量，设置专用 subsystem NQN 和来自 Host 的精确 host NQN。以下为实验名称示例，实际应按 nvme-cli/SPDK 的 NQN 格式要求生成并登记：

```bash
export SUBNQN=nqn.2014-08.org.nvmexpress:uuid:8b786e65-90ce-4b79-8fb4-cf2e079ad011
export HOSTNQN='<实际 Host NQN>'
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" nvmf_create_transport -t TCP
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" bdev_malloc_create \
  -b LabMalloc0 128 4096
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" nvmf_create_subsystem \
  "$SUBNQN" -s LABSTORAGE0001
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" nvmf_subsystem_add_host \
  "$SUBNQN" "$HOSTNQN"
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" nvmf_subsystem_add_ns \
  "$SUBNQN" LabMalloc0
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" nvmf_subsystem_add_listener \
  "$SUBNQN" -t TCP -a 198.51.100.41 -s 4420
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" nvmf_get_subsystems
```

不使用 `allow-any-host` 作为默认方案。检查 RPC 返回的 NSID、序列号和实际 listener，不把配置请求成功视为数据路径完成。

完成 RAM 功能后，停止 Host I/O、断开 Host 并移除该 namespace，或用另一个独立 subsystem 测文件后端。Target 创建**不存在的新文件**，确认 1 GiB 容量预算：

```bash
test ! -e "$DATA/nvmf-aio.bin" &&
  fallocate -l 1G "$DATA/nvmf-aio.bin"
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" bdev_aio_create \
  "$DATA/nvmf-aio.bin" LabAio0 4096
```

任何一步失败均停止，包括上面的不存在性检查；使用带 `set -euo pipefail` 的实验脚本，不能检查失败后继续提交 RPC。按该 RPC `--help` 核对 block size 参数，检查文件系统支持 direct AIO。未写入的预分配区可能读作零；正式读性能前需从独占 Host 有限初始化，不能测未落实际数据的稀疏区域当介质带宽。

用 `LabAio0` 替代上述 `LabMalloc0` 添加 namespace，保存完整配置。Target 本地不得同时打开后端文件进行修改；AIO 后端仍经过内核及文件系统，不是 SPDK 直驱 NVMe。文件持久化能力还受底层 fsync/Flush 支持和缓存层约束。

## 4. ST-P4-03：Host 连接、验证与断开

在 Host：

```bash
sudo modprobe nvme-tcp
sudo nvme discover -t tcp -a 198.51.100.41 -s 4420
sudo nvme connect -t tcp -a 198.51.100.41 -s 4420 -n "$SUBNQN"
sudo nvme list-subsys
nvme list
```

设置 `$SUBNQN` 与 Target 相同。若自定义 hostnqn，连接时按版本明确传入；默认则来自 `/etc/nvme/hostnqn`。通过 subsystem NQN、controller transport address、序列号、NSID 和容量识别新 namespace，使用稳定 by-id 路径并记录其解析目标：

```bash
export REMOTE_DEV='/dev/disk/by-id/<实际核对的实验命名空间标识>'
readlink -f "$REMOTE_DEV"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,SERIAL "$REMOTE_DEV"
```

确认不是本地盘、未挂载、无 swap/holder、由本实验独占后，才允许以下**会覆盖前 64 MiB**的功能验证：

```bash
sudo fio --name=remote-verify --filename="$REMOTE_DEV" \
  --allow_file_create=0 --offset=0 --size=64M \
  --ioengine=psync --rw=write --bs=4k --direct=1 --iodepth=1 \
  --verify=crc32c --do_verify=1 --verify_fatal=1 --end_fsync=1 \
  --output-format=json --output="$LAB/results/p4-verify.json"
```

这是经映射确认后的实验远程块设备，不允许直接替换成任意本地 `/dev/nvme0n1`。用独立脚本验证设备类型和标识白名单后再执行，检查进程返回和 JSON error/verify 结果。保留完整写入范围与数据模式。

文件后端另做一次“写入→Flush 成功→Host 断开→Target 正常重启→用原文件和原 namespace 标识恢复→Host 重连→只读校验”。校验参数必须与原写入一致，fio 使用 `verify_only=1` 等所选版本支持的只读校验方式，不能重新写入后宣称恢复成功。RAM 后端不执行持久性通过判定。

结束时先停 I/O，再 `sudo nvme disconnect -n "$SUBNQN"`，禁止 `disconnect-all` 影响其他卷。

## 5. ST-P4-04：性能和条件扩展

先用 RAM 后端判断协议/CPU 上限，再用文件后端观察介质影响。各自执行随机/顺序读 × 4/128 KiB × QD=1/8/32，单 job，每格三轮；性能读取范围先完全初始化，运行 10 秒预热、60 秒测量。写压另列限量配置。

两端同时采 CPU、网卡收发/丢弃和 Target bdev 计数；文件后端还采实际设备 iostat。记录实际队列数与 queue size、网络速率、MTU、NUMA、digest 配置。网络带宽与 payload 有封装开销，不用 `链路 Gb/s÷8` 直接当 fio 必达 MiB/s。

RDMA 仅在网络和 NIC 支持时构建 `--with-rdma` 并创建 RDMA transport/listener；先用主机内存 RDMA 测试确认连接、GID/路由与 MTU，再由 `nvme-rdma` 连接同一后端。无需把 mlx5 NIC 解绑到 vfio-pci。TCP/RDMA 采用同一数据、后端和并发；如硬件条件不同则不输出单因素加速结论。

交付 RPC 配置、Host/Target 映射、写读校验和重连日志、性能 JSON、两端 CPU/网络证据。可选多路径须使用到同一 namespace 的真实不同路径；一个路径断开后的重连不等于 multipath 高可用。
