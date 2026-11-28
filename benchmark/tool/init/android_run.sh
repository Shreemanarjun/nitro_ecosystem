#!/bin/bash
# usage: android_run.sh <apk> <out-prefix> <launches>
set -u
B=$(cd "$(dirname "$0")" && pwd)
A() { adb -s emulator-5554 "$@"; }
PKG=${PKG:-com.example.nitro_init_bench_example}
OUT=$B/$2
rm -f $OUT.jsonl $OUT.logcat.txt $OUT.amstart.txt
kill $(cat $B/collector.pid) 2>/dev/null; sleep 0.5
python3 -I $B/collector.py $OUT.jsonl > $B/collector.log 2>&1 & echo $! > $B/collector.pid
sleep 1
A install -r "$1" | tail -1
for i in $(seq $3); do
  A shell am force-stop $PKG; A logcat -c
  A shell am start -W -n $PKG/.MainActivity | grep TotalTime >> $OUT.amstart.txt
  for t in $(seq 60); do n=$(cat $OUT.jsonl 2>/dev/null | wc -l); [ "$n" -ge "$i" ] && break; sleep 0.5; done
  if [ "$n" -lt "$i" ]; then echo "launch $i posted no result" >&2; exit 1; fi
  A logcat -d -s NITRO_BENCH:I | grep NITRO_BENCH >> $OUT.logcat.txt
done
wc -l < $OUT.jsonl
