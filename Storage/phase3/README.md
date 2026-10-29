# Storage Phase 3：SPDK 数据面与 bdev 开发

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

默认先用 RAM bdev，不解绑任何物理设备。真实 NVMe 直驱是有设备独占和 IOMMU 条件的扩展，不能因为使用 SPDK 就声称绕过了所有内核 I/O。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | ST-P3-01 构建与 RAM bdev | 建立用户态块层环境 | 固定 release/子模块、RPC、Malloc bdev | Linux 实验主机、可用大页 | 不改物理盘归属即可验证控制面 |
| [ ] | ST-P3-02 bdev 异步应用开发 | 掌握 channel、回调和请求资源 | 基于 hello_bdev 实现多 offset、CRC、QD | RAM bdev 即可 | 学习真实异步编程接口，不只调用现成性能工具 |
| [ ] | ST-P3-03 统计虚拟块设备 | 理解下层请求转发和生命周期 | 在实验源码新增轻量 vbdev，统计读写/失败/延迟 | RAM 或专用文件后端 | 自写模块可验证提交与完成语义，避免只改输出文本 |
| [ ] | ST-P3-04 真实 NVMe 条件对照 | 比较内核与用户态路径及 CPU 代价 | BDF 白名单、同盘时分复用、限范围读对照 | 独占 NVMe、IOMMU、管理网 | 同一盘两种路径不可同时持有，不能拿 RAM 与 SSD 比“加速比” |

## 2. ST-P3-01：固定构建与不解绑设备的启动

示例使用可查源码的 `v24.09`；换版本时同步核对二进制、RPC 参数及依赖。依赖安装与大页分配只在专用实验主机/VM 执行，先记录现状。

```bash
cd "$LAB/src"
git clone https://github.com/spdk/spdk.git
cd spdk
git checkout v24.09
git submodule update --init --recursive
git rev-parse HEAD
git submodule status --recursive
```

审阅该 tag 的 `scripts/pkgdep.sh --help` 后安装所需依赖；TCP/RAM 主线不要求 `--all` 或 RDMA 包。构建：

```bash
./configure
make -j"$(nproc)"
sudo env PCI_ALLOWED=none HUGEMEM=1024 scripts/setup.sh
```

`PCI_ALLOWED=none` 明确阻止该示例脚本绑定 PCI 设备，不能省略。脚本仍会分配/挂载大页，若环境共享或内存不足，先获取独占资源而非直接执行；保存原大页数量。若使用不同 tag，先读其 help/源码确认白名单语义。禁止依赖脚本“检测挂载就安全”的启发式检查。

在独立终端前台启动一个实例，mask `0x4` 仅为 CPU 2 的示例：

```bash
export SPDK="$LAB/src/spdk"
export RPC_SOCK=/var/tmp/storage-lab-spdk.sock
sudo "$SPDK/build/bin/spdk_tgt" --no-pci -m 0x4 -s 512 -r "$RPC_SOCK"
```

另一个终端重新加载相同变量后：

```bash
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" rpc_get_methods
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" bdev_malloc_create \
  -b LabMalloc0 128 4096
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" bdev_get_bdevs
sudo python3 "$SPDK/scripts/rpc.py" -s "$RPC_SOCK" save_config \
  > "$LAB/results/p3-spdk.json"
```

容量参数单位按该 RPC 为 MiB，块大小为字节；检查实际 block count、block size 与名称。`--no-pci` 禁止应用枚举 PCI 设备，RAM/AIO 主线不能因主机上已有其他 vfio 设备而访问它们。RPC socket 仅给实验账户或管理员访问，不对公网开放管理接口。重放配置前停止旧实例，避免重名与重复创建。

## 3. ST-P3-02：从 hello_bdev 到带校验异步读写

阅读 [hello_bdev 固定版本源码](https://github.com/spdk/spdk/blob/v24.09/examples/bdev/hello_world/hello_bdev.c)，在实验工程中实现以下差异：

SPDK bdev 是进程内对象，自写应用不能按名字直接访问另一个 `spdk_tgt` 进程的 `LabMalloc0`。停止旧实例，在自写应用启动时加载上节 JSON（接入 `spdk_app_opts.json_config_file`），在**自己的进程内**创建同名私有 RAM bdev；仍禁用 PCI 枚举。需要保留旧实例时使用独立 RPC socket、资源与环境实例参数，不共享同一设备所有权。

1. 可指定 bdev 名称、测试范围、QD、读写长度与随机种子；先测试 `LabMalloc0`。
2. 使用 bdev 的实际块大小和 DMA buffer，明确 block 与 byte 单位；为每个在途请求独立管理数据及回调。
3. 遵守 SPDK 线程与 I/O channel 所属关系；跨线程传递消息，不直接在任意线程复用 channel。
4. 提交立即返回的错误与异步 completion failure 分别计数；资源不足时按该版本 `spdk_bdev_queue_io_wait` 等机制等待，不能忙重试到占满 CPU。
5. 回调读回校验 block ID/CRC，仅在全部请求结束后释放 channel、descriptor 和 buffer；每个 I/O 对象恰好 free 一次。

先完整写入有限范围再读回，不并发写同一逻辑块。QD=1/8/32、4/16 KiB，每格输出提交数、成功/失败数、字节数、in-flight 峰值和完成时间。Malloc bdev 不持久，Flush 返回也不能让进程退出后的内存数据保留。

**验收：**正常路径校验正确、错误路径返回非零、在途归零、无重复释放。交付源码 diff、构建参数、RPC JSON、日志和测试脚本。

## 4. ST-P3-03：轻量统计 vbdev

参考 [bdev 模块开发指南](https://spdk.io/doc/bdev_module.html)，以该版本 passthru 模块为参考编写 `lab_stats` 虚拟 bdev；先用默认 RAM 后端，不增加压缩、加密或 RAID 等无关功能。将模块及 RPC 注册接入该 tag 的构建/链接清单，重新构建并在装载该模块的进程中创建 wrapper，不能只在源码树新增文件后认为模块已生效。

实现创建/删除 RPC、打开并 claim 下层 bdev、按 channel 转发 READ/WRITE、每线程计数和完成延迟直方图。I/O context 保留提交时间、操作、长度和下层完成状态；回调先更新统计再恰好一次完成上层请求。

声明支持的类型与真实转发能力一致；Flush、不支持操作、下层失败、移除事件、卸载时仍有在途请求均要有明确行为。不能把下层失败计为成功，也不能所有请求提交后立即完成上层。

测试包括：正常读写、非法范围、已被占用的下层设备、RPC 参数错误、删除存在依赖的设备、请求尚未完成时退出。与底层计数核对成功字节数，统计重置需定义并发语义。性能测量单列“无 wrapper/有 wrapper”，报告观测开销；不能因添加统计后吞吐下降而删除错误检查。

## 5. ST-P3-04：可选真实控制器

仅在管理员确认整张控制器及所有 namespace 都可释放时执行。先保存 Linux 驱动下的只读基线、Identify、SMART 和测试数据；检查挂载、swap、holder、LVM/RAID、进程占用及 IOMMU 组。组内有不可释放设备则停止，不用 ACS override 或强行解绑整组。

根据 setup 脚本 help，以**唯一获准 BDF**设置 `PCI_ALLOWED`，明确使用 vfio-pci；失败时停止，不退回 UIO 绕过隔离。此扩展才允许取消 `--no-pci`，并按固定版本使用显式单 BDF allowlist 限制应用枚举，不能仅靠 setup 白名单限制已有绑定设备。用 `bdev_nvme_attach_controller` 的本版本 help 配置精确 PCIe transport address，确认实际 namespace 与只读数据身份后再做对照。

不在本文提供可直接粘贴的真实盘写入或自动扫描绑定命令。读取也限定已授权范围；用户态持有期间不能从内核路径再次访问。测试后关闭所有消费者、正常停 SPDK、只恢复该 BDF 的原驱动，重新核对标识与数据。

比较同一盘、同范围、块大小、QD、worker、CPU/NUMA 和采样窗口；文件系统路径与裸 namespace 路径不同层时应明确，不能把差异全部归因为 SPDK。忙轮询 CPU 即使空闲也可能接近一核，不由此推断功耗。无独占硬件则此任务保留未执行。
