#!/usr/bin/env python3
# parse-transcript.py — Parses a Claude JSONL transcript and outputs:
# model|effective_input_tokens|output_tokens|first_timestamp|last_timestamp
import sys
import json

if len(sys.argv) < 2:
    sys.exit(1)

path = sys.argv[1]
total_in = total_out = total_cache_create = total_cache_read = 0
model = ""
timestamps = []

with open(path) as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        msg = d.get("message", {})
        usage = msg.get("usage", {})
        if usage:
            total_in += usage.get("input_tokens", 0)
            total_out += usage.get("output_tokens", 0)
            total_cache_create += usage.get("cache_creation_input_tokens", 0)
            total_cache_read += usage.get("cache_read_input_tokens", 0)
            if msg.get("model"):
                model = msg["model"]
        ts = d.get("timestamp")
        if ts:
            timestamps.append(ts)

first_ts = min(timestamps) if timestamps else ""
last_ts = max(timestamps) if timestamps else ""
effective_in = total_in + total_cache_create + total_cache_read

print(f"{model}|{effective_in}|{total_out}|{first_ts}|{last_ts}")
