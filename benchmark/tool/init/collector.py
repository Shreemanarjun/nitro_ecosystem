# Bench collector: /next hands out (mode, rotation); /result appends a JSON line.
import http.server, json, sys, threading
out = sys.argv[1]
n = 0
lock = threading.Lock()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        global n
        with lock:
            k = n; n += 1
        body = json.dumps({'mode': ['plain', 'breakdown'][(k // 4) % 2], 'rot': k % 4}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        with lock, open(out, 'a') as f: f.write(data.decode() + '\n')
        self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
http.server.ThreadingHTTPServer(('0.0.0.0', 8765), H).serve_forever()
