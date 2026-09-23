#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/libexec/tp-disk-watchdog"

set +e
df --output=avail -BG / >/tmp/tp-df.out 2>/tmp/tp-df.err
red=$?
set -e
if [ "$red" -eq 0 ]; then
  echo "GNU df unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unrecognized option" /tmp/tp-df.err

funcs=$(awk '
  /^free_gb\(\) \{/ {p=1; n=0}
  p {print; n += gsub(/\{/,"{"); n -= gsub(/\}/,"}")}
  p && n==0 {exit}
' "$script")
eval "$funcs"
MOUNT=/
got=$(free_gb)
want=$(df -k -P / | awk 'NR==2 {printf "%d\n", $4 / 1024 / 1024}')
[ -n "$got" ]
[ "$got" = "$want" ]
[ "$got" -gt 0 ]
echo "taskpump disk darwin ok (df exit $red, free ${got}G)"
