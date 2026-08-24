#!/usr/bin/env bash
# Print the Hyprland window address running the AI process matched by $1 (a
# pgrep pattern). First tries the process's parent chain (CLIs in a terminal),
# then matches a window class to an ancestor process (editors like VS Code,
# whose window is a sibling of the AI process). Prints nothing if not found.
pattern="$1"
[ -z "$pattern" ] && exit 0

pid=$(pgrep "$pattern" | head -n1)
[ -z "$pid" ] && exit 0

clients=$(hyprctl clients -j)

p="$pid"
comms=""
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  a=$(printf '%s' "$clients" | jq -r --argjson q "$p" 'first(.[]|select(.pid==$q).address)//empty')
  if [ -n "$a" ]; then printf '%s\n' "$a"; exit 0; fi
  c=$(ps -o comm= -p "$p" 2>/dev/null)
  [ -n "$c" ] && comms="$comms $c"
  p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
done

for c in $comms; do
  a=$(printf '%s' "$clients" | jq -r --arg c "$c" \
    'first(.[]|select((.class|ascii_downcase)==($c|ascii_downcase) or (.initialClass|ascii_downcase)==($c|ascii_downcase)).address)//empty')
  if [ -n "$a" ]; then printf '%s\n' "$a"; exit 0; fi
done

exit 0
