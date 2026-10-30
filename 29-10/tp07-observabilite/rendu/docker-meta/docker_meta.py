"""docker-meta : expose sur :9417 des métriques Prometheus tirées de l'API Docker (lecture seule).

  docker_container_info{id="/docker/<id>",name,service,project} 1   -> jointure avec les séries cAdvisor (label id)
  docker_container_restart_count{name,service,project}               -> RestartCount
  docker_container_oom_killed{name,service,project}                  -> State.OOMKilled
  docker_container_healthy{name,service,project}                     -> 1 healthy, 0 sinon (absent si pas de healthcheck)
"""
import http.client, json, socket, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

class UnixConn(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("docker")
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect("/var/run/docker.sock")

def api(path):
    c = UnixConn(); c.request("GET", path); r = c.getresponse(); data = json.loads(r.read()); c.close(); return data

def esc(v): return str(v).replace("\\", "\\\\").replace('"', '\\"')

metrics = "# aucune collecte encore\n"

def collect():
    global metrics
    while True:
        try:
            out = ["# TYPE docker_container_info gauge", "# TYPE docker_container_restart_count gauge",
                   "# TYPE docker_container_oom_killed gauge", "# TYPE docker_container_healthy gauge"]
            for c in api("/containers/json"):
                d = api(f"/containers/{c['Id']}/json")
                lab = c.get("Labels") or {}
                base = (f'name="{esc(c["Names"][0].lstrip("/"))}",service="{esc(lab.get("com.docker.compose.service", ""))}",'
                        f'project="{esc(lab.get("com.docker.compose.project", ""))}"')
                out.append(f'docker_container_info{{id="/docker/{c["Id"]}",{base}}} 1')
                out.append(f"docker_container_restart_count{{{base}}} {d.get('RestartCount', 0)}")
                out.append(f"docker_container_oom_killed{{{base}}} {int(d['State'].get('OOMKilled', False))}")
                h = d["State"].get("Health")
                if h: out.append(f"docker_container_healthy{{{base}}} {int(h['Status'] == 'healthy')}")
            metrics = "\n".join(out) + "\n"
        except Exception as e:  # le daemon peut être momentanément indisponible : on garde la dernière collecte
            print(json.dumps({"level": "error", "msg": "collecte", "err": str(e)}))
        time.sleep(10)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = metrics.encode()
        self.send_response(200); self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

Thread(target=collect, daemon=True).start()
HTTPServer(("", 9417), H).serve_forever()
