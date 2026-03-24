#!/usr/bin/env python3
"""HTTP receiver for Debezium Server HTTP sink.

Receives CDC events from two Debezium Server instances (LogMiner and OLR adapters)
and writes them to separate JSONL files. Provides status endpoint for polling
completion via sentinel table detection.

Endpoints:
  POST /logminer  — append event(s) to logminer.jsonl
  POST /olr       — append event(s) to olr.jsonl
  GET  /status    — return event counts and sentinel detection status
  GET  /metrics   — return throughput and latency statistics per adapter
  POST /reset     — clear all state for next scenario
"""

import json
import os
import sys
import time
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

OUTPUT_DIR = os.environ.get('OUTPUT_DIR', '/app/output')
SENTINEL_TABLE = 'DEBEZIUM_SENTINEL'

# Shared state protected by lock
lock = threading.Lock()
state = {
    'logminer_count': 0,
    'olr_count': 0,
    'logminer_sentinel': False,
    'olr_sentinel': False,
}
logminer_file = None
olr_file = None

# Per-adapter metrics for throughput and latency
metrics = {
    'logminer': {
        'latencies_ms': [],       # list of (arrival_ms - source_ts_ms) values
        'timestamps': [],         # arrival timestamps for throughput calc
        'first_event_time': None, # wall clock of first event
    },
    'olr': {
        'latencies_ms': [],
        'timestamps': [],
        'first_event_time': None,
    },
}


def open_files():
    global logminer_file, olr_file
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    logminer_file = open(os.path.join(OUTPUT_DIR, 'logminer.jsonl'), 'a')
    olr_file = open(os.path.join(OUTPUT_DIR, 'olr.jsonl'), 'a')


def reset_state():
    global logminer_file, olr_file
    with lock:
        state['logminer_count'] = 0
        state['olr_count'] = 0
        state['logminer_sentinel'] = False
        state['olr_sentinel'] = False

        for ch in ('logminer', 'olr'):
            metrics[ch]['latencies_ms'] = []
            metrics[ch]['timestamps'] = []
            metrics[ch]['first_event_time'] = None

        if logminer_file:
            logminer_file.close()
        if olr_file:
            olr_file.close()

        # Truncate files
        for name in ('logminer.jsonl', 'olr.jsonl'):
            path = os.path.join(OUTPUT_DIR, name)
            with open(path, 'w'):
                pass

        open_files()


def is_sentinel(event):
    """Check if event is a sentinel table insert."""
    if not isinstance(event, dict):
        return False
    source = event.get('source', {})
    table = source.get('table', '')
    op = event.get('op', '')
    return table == SENTINEL_TABLE and op == 'c'


def process_events(body, channel):
    """Parse and store events from HTTP POST body."""
    arrival_ms = time.time() * 1000

    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return 0

    events = data if isinstance(data, list) else [data]

    with lock:
        f = logminer_file if channel == 'logminer' else olr_file
        count_key = f'{channel}_count'
        sentinel_key = f'{channel}_sentinel'
        m = metrics[channel]

        for event in events:
            if not isinstance(event, dict):
                continue
            f.write(json.dumps(event) + '\n')
            f.flush()
            state[count_key] += 1

            # Track arrival time for throughput
            m['timestamps'].append(arrival_ms)
            if m['first_event_time'] is None:
                m['first_event_time'] = arrival_ms

            # Track latency: source.ts_ms is Oracle commit time (epoch ms)
            source_ts = event.get('source', {}).get('ts_ms')
            if source_ts is not None:
                try:
                    latency = arrival_ms - float(source_ts)
                    if latency >= 0:
                        m['latencies_ms'].append(latency)
                except (TypeError, ValueError):
                    pass

            if is_sentinel(event):
                state[sentinel_key] = True

    return len(events)


def compute_metrics(channel):
    """Compute throughput and latency stats for a channel. Caller holds lock."""
    m = metrics[channel]
    count = state[f'{channel}_count']
    now_ms = time.time() * 1000

    result = {
        'count': count,
        'throughput_total_eps': 0.0,
        'throughput_10s_eps': 0.0,
        'latency_avg_ms': 0.0,
        'latency_p50_ms': 0.0,
        'latency_p95_ms': 0.0,
        'latency_p99_ms': 0.0,
        'latency_min_ms': 0.0,
        'latency_max_ms': 0.0,
    }

    # Overall throughput
    if m['first_event_time'] is not None and count > 0:
        elapsed_s = (now_ms - m['first_event_time']) / 1000.0
        if elapsed_s > 0:
            result['throughput_total_eps'] = round(count / elapsed_s, 1)

    # 10-second window throughput
    cutoff = now_ms - 10000
    recent = [t for t in m['timestamps'] if t >= cutoff]
    if len(recent) > 1:
        window_s = (recent[-1] - recent[0]) / 1000.0
        if window_s > 0:
            result['throughput_10s_eps'] = round(len(recent) / window_s, 1)

    # Latency percentiles
    lats = m['latencies_ms']
    if lats:
        sorted_lats = sorted(lats)
        n = len(sorted_lats)
        result['latency_avg_ms'] = round(sum(sorted_lats) / n, 1)
        result['latency_min_ms'] = round(sorted_lats[0], 1)
        result['latency_max_ms'] = round(sorted_lats[-1], 1)
        result['latency_p50_ms'] = round(sorted_lats[int(n * 0.50)], 1)
        result['latency_p95_ms'] = round(sorted_lats[int(min(n * 0.95, n - 1))], 1)
        result['latency_p99_ms'] = round(sorted_lats[int(min(n * 0.99, n - 1))], 1)

    return result


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length else ''

        if self.path == '/logminer':
            n = process_events(body, 'logminer')
            self.send_response(200)
            self.end_headers()
            self.wfile.write(f'{{"accepted":{n}}}'.encode())

        elif self.path == '/olr':
            n = process_events(body, 'olr')
            self.send_response(200)
            self.end_headers()
            self.wfile.write(f'{{"accepted":{n}}}'.encode())

        elif self.path == '/reset':
            reset_state()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"reset":true}')

        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == '/status':
            with lock:
                body = json.dumps(state)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(body.encode())

        elif self.path == '/metrics':
            with lock:
                body = json.dumps({
                    'logminer': compute_metrics('logminer'),
                    'olr': compute_metrics('olr'),
                })
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(body.encode())

        elif self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        sys.stderr.write("%s - - [%s] %s\n" %
                         (self.client_address[0],
                          self.log_date_time_string(),
                          format%args))
        sys.stderr.flush()


def main():
    open_files()
    port = int(os.environ.get('PORT', 8080))
    server = HTTPServer(('0.0.0.0', port), Handler)
    print(f'Debezium receiver listening on :{port}', flush=True)
    print(f'Output dir: {OUTPUT_DIR}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if logminer_file:
            logminer_file.close()
        if olr_file:
            olr_file.close()


if __name__ == '__main__':
    main()
