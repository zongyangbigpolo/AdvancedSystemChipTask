#!/usr/bin/env bash
# Phase 3: storage mechanics with qemu-img, mapped to XenServer SR / VDI / fast-clone / snapshot / thin provisioning.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
WORK=results/sr
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
{
echo "== [1] 创建精简置备 VDI（= SR 上的 thin VDI） =="
qemu-img create -f qcow2 base.qcow2 4G
echo
echo "== [2] 精简置备：虚拟容量 vs 实际占用 =="
qemu-img info base.qcow2 | grep -E '^(virtual size|disk size)' | sed 's/^/  /'
echo
echo "== [3] 快速克隆（qcow2 backing file = CoW，= XenServer fast clone / linked clone） =="
qemu-img create -f qcow2 -b base.qcow2 -F qcow2 clone-A.qcow2
qemu-img info clone-A.qcow2 | grep -E '^(backing file|disk size)' | sed 's/^/  /'
echo "  说明: clone-A 仅记录差异，写时复制；多台 VM 可共享同一 base，节省空间"
echo
echo "== [4] VDI 内部快照（= xe vdi-snapshot / vm-snapshot 的磁盘部分） =="
qemu-img snapshot -c before-change base.qcow2
qemu-img snapshot -c after-change  base.qcow2
qemu-img snapshot -l base.qcow2 | sed 's/^/  /'
echo
echo "== [5] 一致性检查（= 快照链 coalesce 前的完整性校验） =="
qemu-img check clone-A.qcow2 | sed 's/^/  /'
echo
echo "== [6] 导出为单文件（= xe vm-export / VDI 导出的离线镜像） =="
qemu-img convert -O qcow2 clone-A.qcow2 export.qcow2 && echo "  已将克隆链合并导出为 export.qcow2"
qemu-img info export.qcow2 | grep -E '^(backing file|virtual size)' | sed 's/^/  /'
echo "  (导出后无 backing file，成为独立整卷)"
} | tee ../p3-storage.log
