#!/usr/bin/env python3
"""Real-time validator: tails LogMiner and OLR JSONL files, matches events.

Stops the swingbench container on mismatch. Designed for long-running
continuous validation of OLR vs LogMiner data correctness.

Usage:
    python3 validator.py --logminer output/logminer.jsonl --olr output/olr.jsonl
"""

import argparse
import json
import os
import subprocess
import sys
import time
from collections import defaultdict

SENTINEL_TABLE = 'DEBEZIUM_SENTINEL'
POLL_INTERVAL = 1.0     # seconds between file polls
REPORT_INTERVAL = 10.0  # seconds between progress reports
DEFAULT_MATCH_WINDOW = 120  # seconds to wait for matching event


def normalize_value(v):
    if v is None:
        return None
    return str(v)


def event_key(event):
    """Extract a content-based match key from a Debezium event."""
    source = event.get('source', {})
    table = source.get('table', '')
    op = event.get('op', '')

    if table == SENTINEL_TABLE:
        return None  # skip sentinel

    after = event.get('after') or {}
    before = event.get('before') or {}

    after_norm = tuple(sorted((k, normalize_value(v)) for k, v in after.items()))
    before_norm = tuple(sorted((k, normalize_value(v)) for k, v in before.items()))

    if op == 'c':
        return (table, op, after_norm)
    elif op == 'u':
        return (table, op, before_norm, after_norm)
    elif op == 'd':
        return (table, op, before_norm)
    else:
        return None  # skip unknown ops (heartbeats, etc.)


def tail_file(path, position):
    """Read new lines from file starting at position. Returns (lines, new_position)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return [], position

    if size <= position:
        return [], position

    lines = []
    with open(path, 'r') as f:
        f.seek(position)
        for line in f:
            line = line.strip()
            if line:
                lines.append(line)
        new_position = f.tell()
    return lines, new_position


def stop_swingbench():
    """Stop the swingbench container via Docker socket."""
    import socket
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect('/var/run/docker.sock')
        request = (
            'POST /v1.40/containers/perf-swingbench/stop HTTP/1.1\r\n'
            'Host: localhost\r\n'
            'Content-Length: 0\r\n'
            '\r\n'
        )
        sock.sendall(request.encode())
        response = sock.recv(4096).decode()
        sock.close()
        if '204' in response or '304' in response:
            print('  Swingbench stopped', flush=True)
        else:
            print(f'  WARNING: Unexpected response: {response[:100]}', flush=True)
    except Exception as e:
        print(f'  WARNING: Failed to stop swingbench: {e}', flush=True)


def main():
    parser = argparse.ArgumentParser(description='Real-time OLR vs LogMiner validator')
    parser.add_argument('--logminer', required=True, help='Path to logminer.jsonl')
    parser.add_argument('--olr', required=True, help='Path to olr.jsonl')
    parser.add_argument('--match-window', type=int, default=DEFAULT_MATCH_WINDOW,
                        help=f'Seconds to wait for matching event (default: {DEFAULT_MATCH_WINDOW})')
    parser.add_argument('--stop-on-fail', action='store_true', default=True,
                        help='Stop swingbench on mismatch (default: true)')
    args = parser.parse_args()

    print(f'Validator starting', flush=True)
    print(f'  LogMiner: {args.logminer}', flush=True)
    print(f'  OLR:      {args.olr}', flush=True)
    print(f'  Match window: {args.match_window}s', flush=True)
    print(flush=True)

    # Pending events: key -> [(timestamp, channel, full_event), ...]
    # When both sides produce the same key, they cancel out (match).
    lm_pending = {}  # key -> (timestamp, event_json)
    olr_pending = {}  # key -> (timestamp, event_json)

    lm_pos = 0
    olr_pos = 0
    matched = 0
    lm_total = 0
    olr_total = 0
    skipped = 0
    last_report = time.time()

    while True:
        now = time.time()

        # Tail both files
        lm_lines, lm_pos = tail_file(args.logminer, lm_pos)
        olr_lines, olr_pos = tail_file(args.olr, olr_pos)

        # Process LogMiner events
        for line in lm_lines:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            key = event_key(event)
            if key is None:
                skipped += 1
                continue
            lm_total += 1

            if key in olr_pending:
                # Match found — OLR already has this event
                del olr_pending[key]
                matched += 1
            else:
                lm_pending[key] = (now, line)

        # Process OLR events
        for line in olr_lines:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            key = event_key(event)
            if key is None:
                skipped += 1
                continue
            olr_total += 1

            if key in lm_pending:
                # Match found — LogMiner already has this event
                del lm_pending[key]
                matched += 1
            else:
                olr_pending[key] = (now, line)

        # Check for expired events (exceeded match window)
        expired_lm = [(k, ts, line) for k, (ts, line) in lm_pending.items()
                       if now - ts > args.match_window]
        expired_olr = [(k, ts, line) for k, (ts, line) in olr_pending.items()
                        if now - ts > args.match_window]

        if expired_lm or expired_olr:
            print(flush=True)
            print('!!! MISMATCH DETECTED !!!', flush=True)
            print(f'  Matched so far: {matched}', flush=True)
            print(f'  LogMiner total: {lm_total}, OLR total: {olr_total}', flush=True)
            print(f'  LogMiner pending: {len(lm_pending)}, OLR pending: {len(olr_pending)}', flush=True)
            print(flush=True)

            if expired_lm:
                print(f'  Events in LogMiner but NOT in OLR ({len(expired_lm)} expired):', flush=True)
                for key, ts, line in expired_lm[:5]:
                    age = now - ts
                    print(f'    [{age:.0f}s old] table={key[0]} op={key[1]}', flush=True)
                    print(f'      {line[:200]}', flush=True)

            if expired_olr:
                print(f'  Events in OLR but NOT in LogMiner ({len(expired_olr)} expired):', flush=True)
                for key, ts, line in expired_olr[:5]:
                    age = now - ts
                    print(f'    [{age:.0f}s old] table={key[0]} op={key[1]}', flush=True)
                    print(f'      {line[:200]}', flush=True)

            if args.stop_on_fail:
                stop_swingbench()

            print(flush=True)
            print('VALIDATION FAILED', flush=True)
            sys.exit(1)

        # Progress report
        if now - last_report >= REPORT_INTERVAL:
            print(f'[{time.strftime("%H:%M:%S")}] '
                  f'matched={matched:,} '
                  f'lm={lm_total:,} olr={olr_total:,} '
                  f'pending: lm={len(lm_pending):,} olr={len(olr_pending):,} '
                  f'skipped={skipped:,}',
                  flush=True)
            last_report = now

        time.sleep(POLL_INTERVAL)


if __name__ == '__main__':
    main()
