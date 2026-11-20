#!/bin/bash
echo "== 磁盘 =="; df -h / | tail -1
echo "== 热压力 =="; pmset -g therm 2>/dev/null | head -6
echo "== 内存 =="; vm_stat | awk '/free|inactive|wired/{print}' | head -3
echo "== Wine/Steam CPU =="; top -l 1 -stats pid,cpu,mem,command 2>/dev/null | grep -iE 'wine|Steam' | head -8
echo "== 备份 =="; ls -dt "$HOME/Library/Application Support/Backups"/steam-* 2>/dev/null | head -1
