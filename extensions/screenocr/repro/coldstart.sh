#!/bin/bash
# Runs the recognition 8 times in fresh processes on a freshly booted CI Mac and
# reports any stdout that is not exactly one JSON line.
set -u
cd "$(dirname "$0")"
sw_vers
swiftc -parse-as-library -O coldstart.swift -o coldstart 2>&1 | tail -5 || exit 1
fail=0
for mode in --accurate --fast; do
  for i in 1 2 3 4 5 6 7 8; do
    out=$(./coldstart $mode 2>err.txt); lines=$(printf '%s' "$out" | grep -c '')
    ok=yes
    if [ "$lines" -ne 1 ] || ! printf '%s' "$out" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());assert d["status"]=="recognized" and "12345" in d["text"]'; then ok=NO; fail=1; fi
    echo "run $mode $i: clean=$ok lines=$lines $(cat err.txt | tr '\n' ' ')"
    [ "$ok" = NO ] && { echo "---- stdout ----"; printf '%s\n' "$out" | head -20; echo "----"; }
  done
done
exit $fail
