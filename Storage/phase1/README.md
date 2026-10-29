# Storage Phase 1：Linux 存储栈与同步 I/O

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

执行前完成公共环境中的数据目录核对。本阶段不格式化或覆盖物理块设备，所有写入指向新建的专用实验文件；任务均待执行。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | ST-P1-01 设备拓扑与存储栈调查 | 追踪文件到介质的实际路径 | findmnt、lsblk、NVMe Identify/SMART、blk-mq 结构图 | Linux 主机；NVMe 查询需对应设备 | 先确认路径与设备归属，避免测到系统盘或虚拟后端却误报 |
| [ ] | ST-P1-02 fio 基线与校验 | 建立可复现的读写和延迟口径 | 专用文件初始化、CRC 校验、顺序/随机读对照 | 专用数据文件系统 | 成熟工具先确认环境与数据，后续用于自写引擎交叉核对 |
| [ ] | ST-P1-03 同步 I/O 程序开发 | 掌握短读写、偏移和错误处理 | C 实现 pread/pwrite、数据模式、fsync 选项 | 普通 Linux 开发环境 | 先完成可解释的 QD=1 基线，不从复杂异步 API 起步 |
| [ ] | ST-P1-04 数据路径观测 | 区分缓存命中与真实块层访问 | strace、iostat、条件性块层 trace | 同上；trace 需管理员允许 | 关联 syscall 与块请求，不把应用请求和硬件命令简单一一对应 |

## 2. ST-P1-01：盘点与设备映射

```bash
lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
findmnt -T "$DATA_ROOT"
swapon --show
nvme list
lspci -nnk
```

按实际设备补充只读 `nvme id-ctrl`、`id-ns`、`smart-log`，保存对应 controller、namespace、NSID、序列号、LBA 大小和温度。没有 NVMe 时记录实际 SATA/虚拟磁盘，命令不适用不算失败。

画出 `应用 → VFS → 文件系统/page cache → bio/blk-mq → 驱动 → 控制器 → 介质`，标出 buffered/direct 的差异。存在 LVM、RAID、device-mapper、虚拟磁盘或网络文件系统时补全中间层；主机侧一个路径不保证对应一块独占物理盘。

**完成要求：**形成文件路径→挂载源→块设备→控制器→型号/序列号的映射，附容量预算与可写范围。不确定设备归属时停止写测试。

## 3. ST-P1-02：先初始化和校验，再做性能

在 Bash 中设置独立结果目录与文件路径。`fio` 会创建并写入指定文件，确认不存在再继续：

```bash
export RUN="$LAB/results/p1-baseline-r1"
export TESTFILE="$DATA/fio-baseline.bin"
mkdir -p "$RUN"
test ! -e "$TESTFILE"
fio --name=prepare --filename="$TESTFILE" --size=1G \
  --ioengine=psync --rw=write --bs=4k --direct=1 --iodepth=1 \
  --verify=crc32c --do_verify=1 --verify_fatal=1 --end_fsync=1 \
  --output-format=json --output="$RUN/prepare.json"
```

任何命令非零退出或 JSON job `error` 非零时停止，不忽略 `test` 失败后继续粘贴后续行。建议将一组命令保存到带 `set -euo pipefail` 的实验脚本中。先做一次有限范围完整写入与读回验证，不把带校验开销的运行当纯性能结果。

随机读性能示例：

```bash
fio --readonly --name=randread --filename="$TESTFILE" --size=1G \
  --allow_file_create=0 --ioengine=psync --rw=randread \
  --bs=4k --direct=1 --iodepth=1 --numjobs=1 \
  --time_based=1 --ramp_time=10 --runtime=60 \
  --randrepeat=1 --randseed=2026 \
  --output-format=json+ --output="$RUN/randread-direct.json"
```

以独立文件名保存顺序读 `--rw=read`、buffered `--direct=0` 的结果；每组至少三轮。更改选项前先核对该 fio 版本支持。`psync` 是同步引擎，增加 `iodepth` 不会自动变成异步高队深，应记录实际分布。

buffered 数据集可能落在 page cache；不对共享主机全局 `drop_caches`。重复读取称为“暖缓存”，若需冷缓存实验，使用可丢弃 VM 或受控的文件级缓存管理并说明限制。`direct=1` 也不绕过 SSD 控制器缓存。

## 4. ST-P1-03：同步程序的接口与状态

在 `$LAB/src/sync_io.c` 实现以下接口约定；源码完成后再构建，不能将模板文件名当作现成程序：

```text
sync_io --file PATH --op write|read --size BYTES --bs BYTES
        --direct 0|1 --sync none|end|each --seed N --report JSON
```

开发要求：

1. 仅接受实验目录内的普通文件，写入初始化使用独占创建，不接受块设备、符号链接或已存在输出；续测需单独明确的接口和范围。
2. 固定每块包含 block index、generation、payload 与 CRC；读模式校验每块身份及内容，不只是比较文件长度。
3. 处理 `pread/pwrite` 短返回、`EINTR`、EOF、零进展、偏移溢出和错误；重试必须保留已完成字节和偏移。`close` 错误也要记录，不能盲目重复 close 已释放的 fd。
4. direct 模式按文件系统要求分配对齐 buffer；在支持时通过 `statx(STATX_DIOALIGN)` 查询，不能默认所有平台都是 512 B 或 4 KiB。未支持或不满足约束时明确失败，不悄悄切换 buffered。
5. 用单调时钟记录调用提交到完成，以及单独的同步耗时。`none`、末尾 fsync、每写同步的 ack 语义不同，分表统计。

```bash
cc -std=c11 -O2 -g -Wall -Wextra -Werror \
  "$LAB/src/sync_io.c" -o "$LAB/build/sync_io"
```

边界包括空长度策略、单块、非整块尾部、越界偏移、不存在文件、无权限和无空间。buffered 可以正确处理尾部；direct 不满足对齐时按契约拒绝。使用有限容量实验文件系统测试 ENOSPC，不填满主机系统盘。

## 5. ST-P1-04：观测与交付

程序实现后，用其 write 接口独占创建并校验自己的 `$DATA/sync-reference.bin`，然后用短读运行采样；正式性能测试不带 strace：

```bash
export SYNCFILE="$DATA/sync-reference.bin"
strace -f -T -e trace=openat,pread64,pwrite64,fsync,fdatasync,close \
  -o "$LAB/results/sync-read.strace" \
  "$LAB/build/sync_io" --file "$SYNCFILE" --op read --size 1073741824 \
  --bs 4096 --direct 1 --sync none --seed 2026 \
  --report "$LAB/results/sync-read.json"
```

上述自写校验模式须与文件数据格式一致；fio 初始化文件不是 `sync_io` 的自定义格式，不能改用 `$TESTFILE`。不要把校验格式不一致误判为存储损坏。

在另一终端运行有界 `iostat -xz 1 70`，关联正式测试窗口；注意第一份报告可能是开机累计值。可在独占实验环境用 blk trace 工具辅助观察，但需注明权限、过滤设备和采样开销。

交付设备映射、初始化/校验 JSON、同步程序及单元测试、三轮性能数据、syscall 与块层路径说明。仅 `write` 成功不代表掉电后一定保存，持久性在 Phase 5 单独验证。
