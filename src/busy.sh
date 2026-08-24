#!/usr/bin/env bash
# For each process matching $1 (a pgrep pattern), print "<name> <cpu_delta>"
# where cpu_delta is utime+stime jiffies used over a short interval. The caller
# treats a non-trivial delta as "actively working" (vs running but idle).
pattern="$1"
[ -z "$pattern" ] && exit 0

pids=$(pgrep "$pattern")
[ -z "$pids" ] && exit 0

declare -A t0
for p in $pids; do
  s=$(awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null) && t0[$p]=$s
done

sleep 0.2

for p in $pids; do
  name=$(cat "/proc/$p/comm" 2>/dev/null) || continue
  s=$(awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null) || continue
  printf '%s %s\n' "$name" "$(( s - ${t0[$p]:-$s} ))"
done
