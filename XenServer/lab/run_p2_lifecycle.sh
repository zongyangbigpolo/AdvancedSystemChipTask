#!/usr/bin/env bash
# Phase 2: VM lifecycle via the libvirt test driver (in-memory simulation), mapped to XenServer xe-CLI operations.
# Each command maps to an xe command (see phase2/README.md); all run in one virsh session so state persists.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
cp xml/xs-lab-vm.xml /tmp/xs-lab-vm.xml
virsh -c test:///default <<'EOF' 2>&1 | sed "s/^virsh # /\$ /" | grep -viE 'Welcome to virsh|Type: |for help|to quit|^\$ *$' | tee results/p2-lifecycle.log
define /tmp/xs-lab-vm.xml
start xs-lab-vm
dominfo xs-lab-vm
suspend xs-lab-vm
domstate xs-lab-vm
resume xs-lab-vm
domstate xs-lab-vm
setvcpus xs-lab-vm 1 --config --maximum
list --all
EOF
