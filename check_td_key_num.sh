#!/usr/bin/env bash
set -euo pipefail

sudo modprobe msr 2>/dev/null || true

p=$(rdmsr 0x87)
pval=$((0x$p))

mktme=$((pval & 0xffffffff))
tdx=$(((pval >> 32) & 0xffffffff))
guest=$((tdx > 0 ? tdx - 1 : 0))

echo "IA32_MKTME_KEYID_PARTITIONING(0x87): 0x$p"
echo "MKTME KeyIDs:           $mktme"
echo "TDX private KeyIDs:     $tdx"
echo "TD guest usable KeyIDs: $guest"

c=$(rdmsr 0x981)
cval=$((0x$c))
echo
echo "IA32_TME_CAPABILITY(0x981): 0x$c"
echo "MK_TME_MAX_KEYID_BITS:  $(((cval >> 32) & 0xf))"
echo "MK_TME_MAX_KEYS:        $(((cval >> 36) & 0x7fff))"

a=$(rdmsr 0x982)
aval=$((0x$a))
echo
echo "IA32_TME_ACTIVATE(0x982): 0x$a"
echo "Configured KeyID bits:  $(((aval >> 32) & 0xf))"

running=$(ps -ef | grep qemu | grep -i "tdx-guest" | grep -v grep | wc -l)
remain=$((guest - running))
[ "$remain" -lt 0 ] && remain=0

echo
echo "QEMU tdx-guest count:   $running"
echo "Estimated remaining:    $remain"
