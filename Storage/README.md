# Storage：块存储开发、用户态数据面与一致性恢复

五个实验单元分别对应 Phase 1 至 Phase 5，任务文档独立存放，不在标题中重复按天命名。名词定义统一见 [名词与缩写](../glossary/README.md)。

| 阶段 | 任务文档 | 核心交付物 |
| --- | --- | --- |
| Phase 1 | [Linux 存储栈与同步 I/O](phase1/README.md) | 设备映射、fio 基线、同步读写程序、系统调用与块层证据 |
| Phase 2 | [io_uring 异步引擎与数据校验](phase2/README.md) | 异步状态机、错误路径测试、队列深度与尾延迟报告 |
| Phase 3 | [SPDK 数据面与 bdev 开发](phase3/README.md) | 可复现构建、RAM bdev、异步应用、条件性 NVMe 对照 |
| Phase 4 | [NVMe-oF 远程块存储](phase4/README.md) | Target/Host 配置、远程校验、TCP 与条件性 RDMA 报告 |
| Phase 5 | [WAL、故障注入与恢复验证](phase5/README.md) | 最小日志存储、恢复程序、ack 对照、故障矩阵与综合报告 |

## 1. 范围与执行边界

主线为 Linux 用户态存储软件开发：从文件接口追踪到块层，再实现异步 I/O、用户态块设备和远程访问，最后验证持久化语义。共 20 项任务，均包含名称、目的、方法、硬件、方案依据及完成细节。不以只安装软件或跑一次吞吐代替开发与正确性验证。

**文档不表示已执行。**没有独立 SSD、第二节点、RDMA 网卡或故障测试条件时，只完成方法、代码设计和软件功能实验；相关硬件性能、掉电测试保持未执行。文件、loop、RAM bdev、虚拟磁盘和真实 NVMe 必须分别标注，不能互相冒充。

每阶段先完成核心功能，再完成受硬件条件约束的扩展。跨越内核 API、SPDK 和持久化恢复的内容可按实验进度延长，不以阶段数量要求省略错误处理或数据校验。文中 `sync_io.c`、`uring_io.c`、`wal_store` 等是需要完成的作业文件/接口，不是仓库已实现或已测试的程序。

### 1.1 安全边界

| 资源 | 允许的操作 | 必须满足的条件 |
| --- | --- | --- |
| 只读设备调查 | 枚举拓扑、标识、SMART、驱动与队列 | 不改变固件、namespace、分区、挂载或缓存策略 |
| 普通实验文件 | 写入、覆盖、校验、故障测试 | 位于专用实验文件系统的独立目录，有空间和配额上限，不覆盖既有文件 |
| RAM bdev | 写入、清空、重建 | 仅属于本次 SPDK 进程；退出数据丢失是正常语义，不用于持久性验收 |
| 专用物理盘 | 经确认后测试指定范围、条件性驱动重绑 | 整个控制器及所有 namespace 均可释放，无系统盘、挂载、swap、LVM、RAID 或其他业务依赖 |
| 远程命名空间 | 在限定范围写入与校验 | 由本实验独占创建，以 NQN、序列号、NSID、容量建立映射，不按动态 `/dev/nvmeXnY` 编号猜测 |
| 故障注入 | 自有进程退出、I/O 包装层返回错误、实验副本尾部损坏 | 不关闭共享主机、不拔生产盘、不操作他人网络，不触及真实业务数据 |

系统盘不能因“文件在 home 下”而自动视为安全。示例用 `$HOME/storage-lab` 保存源码/日志，**数据目录必须由 `DATA_ROOT` 指向已核对的独立实验文件系统**。没有此条件时可在资源受限的可丢弃 VM 中做小容量功能验证，但不得报告为独立 NVMe 实测。

不提供对未知盘运行 `mkfs`、`blkdiscard`、`nvme format`、sanitize 或全盘 `dd` 的默认步骤。需要格式化的资源由维护流程预先准备；SPDK 绑定的是 PCI 控制器，不仅是某个分区。

### 1.2 硬件与软件基线

| 项目 | 要求 | 原因 |
| --- | --- | --- |
| 主机 | Linux，示例 Ubuntu 22.04/24.04；建议至少 8 核、16 GiB 内存；保留管理通道 | 分离应用、监控、网络和 SPDK 核心 |
| 数据介质 | 一块独立实验 SSD 或可丢弃虚拟磁盘；真实用户态 NVMe 扩展需可独占 PCIe NVMe | 文件路径功能和控制器直驱性能是不同实验 |
| 第二节点 | Phase 4 建议两台主机；可用两台 VM 完成功能 | 跨物理主机才能报告真实网络与设备链路性能 |
| 数据网 | 普通 Ethernet 支持 NVMe/TCP；RDMA 需要兼容 NIC、驱动、网络 | TCP 主线不依赖专用网卡，RDMA 是条件扩展 |
| 工具链 | C11、编译器、make/pkg-config、liburing、fio、nvme-cli、sysstat、strace | 自写程序与成熟工具交叉验证 |
| SPDK | 固定 release/tag、递归子模块及依赖；示例 `v24.09` | 示例对应可查源码，不要求部署历史版本；执行时选择适配且维护中的版本 |
| 持久化条件 | 记录文件系统、挂载选项、虚拟化层、设备写缓存与 PLP | `write`、`O_DIRECT`、Flush、真实掉电安全不能等同 |

不为运行 io_uring 全局降低安全策略；被内核策略、容器 seccomp 或版本限制时记录原因，申请专用实验环境。SPDK 的依赖、内核和所带 DPDK 按 release 文档选择，不与 DPU 目录的 OVS-DPDK 安装混用。

### 1.3 公共参数、版本与资源预算

```bash
export LAB=$HOME/storage-lab
export DATA_ROOT='<已核对的专用实验文件系统目录>'
mkdir -p "$LAB"/{src,build,results}
# 先替换 DATA_ROOT，并核对其实际挂载来源及剩余空间。
findmnt -T "$DATA_ROOT"
df -h "$DATA_ROOT"
export DATA="$DATA_ROOT/storage-lab-data"
```

确认目标目录不是其他业务目录、不是符号链接到未知位置，之后创建 `$DATA`。只向本次清单登记的文件写入，默认单文件 1 GiB；提前规划 fio、远程后端、WAL 和副本的总容量，避免填满文件系统。不得反复执行创建步骤覆盖旧数据。

```bash
mkdir -p "$DATA"
uname -a
fio --version
nvme version
pkg-config --modversion liburing
```

缺少工具时按实验发行版安装 `build-essential pkg-config liburing-dev fio nvme-cli sysstat strace pciutils numactl` 等对应包。先运行 `fio --enghelp`，确认调用的是 Flexible I/O Tester，而不是其他同名命令。

保存 CPU/NUMA、内存、设备型号/序列号/固件、PCIe 链路、LBA 大小、文件系统及挂载、队列/调度器、内核、fio/liburing/SPDK 版本、温度和写入计数。日志每次使用独立运行编号，不记录凭据或将大数据文件提交 Git。

## 2. 公共报告与验收口径

| 维度 | 要求 |
| --- | --- |
| 正确性 | 已知数据写入后读回校验；偏移、长度、generation 与 CRC 可追踪；错误返回不算成功 |
| 性能 | IOPS、MiB/s、平均/P95/P99 延迟、实际队列分布、CPU、上下文切换、温度与错误数 |
| 条件 | 介质/文件或块设备、I/O 引擎、直接/缓存、块大小、队列深度、job 数、范围、读写比例、同步策略 |
| 统计 | 每格至少三轮；性能运行示例预热 10 秒、测量 60 秒；长时稳定性/SSD 稳态另列，不从短测推断 |
| 归因 | 先正确性后性能，每次只改变一个变量；同层指标比较，不把 fio clat 和应用总耗时混为一个量 |
| 持久性 | 明确 ack 的时间点、Flush/fsync 语义及故障边界；进程崩溃不等于主机掉电 |
| 原始产物 | 源码、构建/启动命令、job/JSON 配置、返回码、逐次/直方图数据、设备映射与分析脚本 |

固定块大小时可用 `带宽 ≈ IOPS × 字节数` 检查单位；混合块大小需按完成字节数统计。多个 job 的 P99 不能算术平均成总体 P99，应合并有相同单位/边界的直方图或原始样本。写测试必须记录总写入量与 SSD 磨损，不执行无限时长发压。

## 3. 停止与恢复顺序

先停止发压与自写客户端，排空异步请求并同步需要持久的数据；断开本次远程 namespace，再删除 Target 的本次 listener、subsystem、bdev，正常停止本次 SPDK 进程。用记录的 PID，不按进程名批量终止。

若重绑真实控制器，先确认无消费者，仅对获准的 BDF 恢复原驱动并重新核对 namespace/序列号；不要无参数运行可能扫描所有设备的 setup/reset。恢复大页和绑核前确认已无使用者。只删除清单中的实验文件，保留失败日志及恢复前数据副本，不递归清理未知目录。

## 4. 参考资料

资料核对日期：2026-10-29。在线文档与 `master` 会变化，具体命令应以实验固定版本的 `--help`、man page 和源码为准。

- [Linux blk-mq](https://docs.kernel.org/block/blk-mq.html)
- [open 与 O_DIRECT](https://man7.org/linux/man-pages/man2/open.2.html)
- [fsync/fdatasync 与目录持久化](https://man7.org/linux/man-pages/man2/fsync.2.html)
- [liburing 源码、示例与内核依赖](https://github.com/axboe/liburing)
- [io_uring_enter](https://man7.org/linux/man-pages/man2/io_uring_enter.2.html)
- [fio 文档](https://fio.readthedocs.io/en/latest/fio_doc.html)
- [SPDK 构建](https://spdk.io/doc/getting_started.html)
- [SPDK bdev](https://spdk.io/doc/bdev.html)
- [bdev 模块开发](https://spdk.io/doc/bdev_module.html)
- [SPDK v24.09 hello_bdev](https://github.com/spdk/spdk/blob/v24.09/examples/bdev/hello_world/hello_bdev.c)
- [SPDK v24.09 setup 设备白名单](https://github.com/spdk/spdk/blob/v24.09/scripts/setup.sh)
- [NVMe-oF Target/Host](https://spdk.io/doc/nvmf.html)
- [nvme-cli](https://github.com/linux-nvme/nvme-cli)
