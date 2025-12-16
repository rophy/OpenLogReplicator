#!/usr/bin/env python3
"""Simple HTTP server that writes incoming JSON events to a file."""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
from datetime import datetime

OUTPUT_FILE = "/app/output/events.json"

class FileWriterHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)

        try:
            # Try to parse as JSON for pretty output
            data = json.loads(body.decode('utf-8'))
            line = json.dumps(data)
        except:
            # If not JSON, write raw
            line = body.decode('utf-8', errors='replace')

        # Append to file
        with open(OUTPUT_FILE, 'a') as f:
            f.write(line + '\n')

        print(f"[{datetime.now().isoformat()}] Received event: {line[:100]}...")

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"status": "ok"}')

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'File Writer Service - POST events to write to file')

    def log_message(self, format, *args):
        # Suppress default logging
        pass

if __name__ == '__main__':
    print(f"Starting file writer server on port 8080...")
    print(f"Writing events to {OUTPUT_FILE}")
    server = HTTPServer(('0.0.0.0', 8080), FileWriterHandler)
    server.serve_forever()
