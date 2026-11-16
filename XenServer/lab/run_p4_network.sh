#!/usr/bin/env bash
# Phase 4: virtual networking building blocks (libvirt networks + QEMU NIC backends), mapped to XenServer network/PIF/VIF.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
{
echo "== [1] 受管虚拟网络（= XenServer network 对象） =="
virsh -c test:///default net-list --all | sed 's/^/  /'
echo
echo "== [2] 网络定义：NAT 转发 + 网桥 + DHCP（= 内部网络 + 地址分配） =="
virsh -c test:///default net-dumpxml default | sed 's/^/  /'
echo
echo "== [3] QEMU 虚拟网卡后端类型（= VIF 的连接方式） =="
qemu-system-x86_64 -machine none -netdev help 2>&1 | sed -n '1,12p' | sed 's/^/  /'
echo
echo "== [4] 虚拟网卡设备型号（virtio-net = XenServer PV 网卡；e1000 = 模拟网卡） =="
qemu-system-x86_64 -device help 2>&1 | grep -iE 'virtio-net-pci,|e1000",|rtl8139' | sed 's/^/  /'
} | tee results/p4-network.log
