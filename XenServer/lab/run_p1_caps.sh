#!/usr/bin/env bash
# Phase 1: inspect host virtualization capabilities and the local hypervisor/toolstack analogs for XenServer concepts.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
{
echo "== 主机与硬件虚拟化支持 =="
echo "date   : $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "host   : $(sw_vers -productName) $(sw_vers -productVersion)  arch=$(uname -m)"
echo "cpu    : $(sysctl -n machdep.cpu.brand_string)"
echo "cores  : $(sysctl -n hw.ncpu)   memory: $(( $(sysctl -n hw.memsize) / 1024/1024/1024 )) GiB"
echo "hv     : kern.hv_support=$(sysctl -n kern.hv_support)  (1 = 支持 Hypervisor.framework / 硬件辅助虚拟化)"

echo
echo "== Hypervisor 与工具栈版本 =="
qemu-system-x86_64 --version | head -1
echo "libvirt/virsh: $(virsh --version)"

echo
echo "== QEMU 可用加速器（hvf = 硬件辅助虚拟化，XenServer 等 Type-1 依赖此能力） =="
qemu-system-aarch64 -accel help | sed 's/^/  /'
echo "  注: 跨架构 x86 客户机在本机走 tcg 软件模拟；原生 arm64 客户机可用 hvf 硬件加速"

echo
echo "== QEMU 可用机器类型（节选，= 虚拟平台/芯片组） =="
qemu-system-x86_64 -machine help | sed -n '1,5p' | sed 's/^/  /'

echo
echo "== libvirt test 驱动节点信息（模拟受管主机，数值为测试驱动内置，非真实硬件） =="
virsh -c test:///default nodeinfo | sed 's/^/  /'
} | tee results/p1-caps.log
