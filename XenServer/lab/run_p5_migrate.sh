#!/usr/bin/env bash
# Phase 5: the memory-state transfer behind live migration, plus snapshot-based backup, mapped to XenMotion/backup.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
cp xml/xs-lab-vm.xml /tmp/xs-lab-vm.xml
rm -f /tmp/xs-lab-vm.save /tmp/xs-backup.qcow2
echo "=== A. 实时迁移核心机制：内存状态序列化与恢复（suspend -> save -> restore） ===" | tee results/p5-migrate.log
virsh -c test:///default <<'EOF' 2>&1 | sed "s/^virsh # /\$ /" | grep -viE 'Welcome to virsh|Type: |for help|to quit|^\$ *$' | tee -a results/p5-migrate.log
define /tmp/xs-lab-vm.xml
start xs-lab-vm
domstate xs-lab-vm
save xs-lab-vm /tmp/xs-lab-vm.save
list --all
restore /tmp/xs-lab-vm.save
domstate xs-lab-vm
list --all
EOF
{
echo
echo "=== B. 基于快照的备份与导出（= 快照一致点 + 导出 xva） ==="
cd results/sr 2>/dev/null || { echo "  先运行 ./run_p3_storage.sh 生成 SR 工作区"; exit 0; }
qemu-img snapshot -c backup-point base.qcow2 && echo "[1] 在 base.qcow2 建立一致性备份点 backup-point"
qemu-img snapshot -l base.qcow2 | sed 's/^/  /'
qemu-img convert -O qcow2 base.qcow2 /tmp/xs-backup.qcow2 && echo "[2] 导出为独立离线备份 /tmp/xs-backup.qcow2"
qemu-img info /tmp/xs-backup.qcow2 | grep -E '^(virtual size|disk size)' | sed 's/^/  /'
} | tee -a results/p5-migrate.log
