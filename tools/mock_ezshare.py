"""EzShare WiFi SD 카드 흉내 서버 (개발/테스트용).

로컬 폴더(기본: 저장소의 Data/)를 SD 카드 루트(A:)처럼 제공한다.

    python tools/mock_ezshare.py            # http://0.0.0.0:8000, ./Data
    python tools/mock_ezshare.py --root D:\\SDCARD --port 8080

Android 에뮬레이터에서는 앱 설정의 EzShare 주소를 http://10.0.2.2:8000 으로,
실제 폰에서는 PC 의 IP(같은 WiFi)로 지정한다.
"""
import argparse
import datetime
import html
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse


def make_handler(root):
    root = os.path.abspath(root)

    def resolve(sd_path):
        sd_path = sd_path.replace("A:", "", 1) if sd_path.upper().startswith("A:") else sd_path
        parts = [p for p in sd_path.replace("/", "\\").split("\\") if p and p not in (".", "..")]
        full = os.path.abspath(os.path.join(root, *parts))
        if not full.startswith(root):
            return None, parts
        return full, parts

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urlparse(self.path)
            q = parse_qs(url.query)
            if url.path == "/dir":
                self.list_dir(q.get("dir", ["A:"])[0])
            elif url.path == "/download":
                self.download(q.get("file", [""])[0])
            else:
                self.send_error(404)

        def list_dir(self, sd_path):
            full, parts = resolve(sd_path)
            if not full or not os.path.isdir(full):
                return self.send_error(404)
            lines = []
            for name in sorted(os.listdir(full)):
                p = os.path.join(full, name)
                ts = datetime.datetime.fromtimestamp(os.path.getmtime(p))
                stamp = f"{ts.year}-{ts.month:2d}-{ts.day:2d}   {ts:%H:%M:%S}"
                rel = "\\".join(parts + [name])
                if os.path.isdir(p):
                    href = "dir?dir=A:" + quote("\\" + rel)
                    lines.append(f'{stamp}         &lt;DIR&gt;   <a href="{href}"> {html.escape(name)}</a>')
                else:
                    kb = (os.path.getsize(p) + 1023) // 1024
                    href = f"http://{self.headers.get('Host')}/download?file=" + quote(rel)
                    lines.append(f'{stamp}   {kb:>10}KB  <a href="{href}"> {html.escape(name)}</a>')
            body = ("<html><body><h1>Directory Index of A:\\" + html.escape("\\".join(parts)) +
                    "</h1><pre>\n" + "\n".join(lines) + "\n</pre></body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def download(self, sd_path):
            full, _ = resolve(sd_path)
            if not full or not os.path.isfile(full):
                return self.send_error(404)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(os.path.getsize(full)))
            self.end_headers()
            with open(full, "rb") as f:
                while chunk := f.read(65536):
                    self.wfile.write(chunk)

    return Handler


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(here, "..", "Data"))
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()
    print(f"Serving {os.path.abspath(args.root)} as EzShare on http://0.0.0.0:{args.port}")
    ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(args.root)).serve_forever()
