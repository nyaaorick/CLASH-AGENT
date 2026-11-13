#!/usr/bin/env bash
# Genuine nginx + sing-box WS/TLS + SOCKS TCP/UDP integration, loopback only.
set -euo pipefail
if [[ $(uname -s) != Linux ]] || ! command -v nginx >/dev/null || ! command -v sing-box >/dev/null; then
    printf 'SKIP: native Linux nginx integration (requires Linux, nginx and sing-box).\n'; exit 0
fi
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../install.sh"
work=$(mktemp -d /tmp/clash-agent-cf-nginx.XXXXXX)
children=()
cleanup() { for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/tls"
python3 - "$work/ports" <<'PY' &
import http.server,pathlib,socket,sys,threading,signal
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  b=b'cf-ws-loopback-ok';self.send_response(200);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0))
def echo():
 while True:
  b,p=udp.recvfrom(4096);udp.sendto(b,p)
threading.Thread(target=http.serve_forever,daemon=True).start();threading.Thread(target=echo,daemon=True).start()
pathlib.Path(sys.argv[1]).write_text(str(http.server_port)+' '+str(udp.getsockname()[1])+'\n')
signal.pause()
PY
children+=("$!")
for ((i=0;i<40;i++)); do [[ ! -f $work/ports ]] || break; sleep .1; done
read -r http_port udp_port <"$work/ports"
read -r backend tls_port socks_port < <(python3 - <<'PY'
import socket
socks=[socket.socket() for _ in range(3)]
for s in socks:s.bind(('127.0.0.1',0))
print(' '.join(str(s.getsockname()[1]) for s in socks))
PY
)
uuid=123e4567-e89b-42d3-a456-426614174000
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/tls/test.key" -out "$work/tls/test.crt" -days 30 -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com >/dev/null 2>&1
printf 'allow 127.0.0.1;\ndeny all;\n' >"$work/allow.conf"
clash_agent_cf_render_core node.example.com "$backend" "$uuid" /samplews Fixture >"$work/server.json"
clash_agent_cf_render_profile node.example.com "$uuid" /samplews Fixture >"$work/clash.yaml"
clash_agent_cf_render_nginx node.example.com "$backend" /samplews "$work/clash.yaml" "$token" "$work/tls/test.crt" "$work/tls/test.key" "$work/allow.conf" |
    sed "s/listen 443 ssl;/listen 127.0.0.1:${tls_port} ssl;/" >"$work/site.conf"
cat >"$work/nginx.conf" <<EOF
user $(id -un);
worker_processes 1;
pid $work/nginx.pid;
error_log $work/error.log;
events { worker_connections 64; }
http { access_log off; include $work/site.conf; }
EOF
nginx -t -p "$work/" -c "$work/nginx.conf"
sing-box run -c "$work/server.json" >"$work/server.log" 2>&1 & children+=("$!")
nginx -p "$work/" -c "$work/nginx.conf" -g 'daemon off;' >"$work/nginx.log" 2>&1 & children+=("$!")
for ((i=0;i<40;i++)); do
    if curl --noproxy '*' --cacert "$work/tls/test.crt" --resolve "node.example.com:${tls_port}:127.0.0.1" -fsS --max-time 1 \
        "https://node.example.com:${tls_port}/s/${token}/clash.yaml" -o "$work/download" 2>/dev/null; then break; fi
    sleep .1
done
cmp "$work/download" "$work/clash.yaml"
[[ $(curl --noproxy '*' --cacert "$work/tls/test.crt" --resolve "node.example.com:${tls_port}:127.0.0.1" -sS -o /dev/null -w '%{http_code}' "https://node.example.com:${tls_port}/clash.yaml") == 404 ]]
jq -n --arg uuid "$uuid" --argjson port "$socks_port" --argjson server_port "$tls_port" \
    '{log:{level:"error"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],outbounds:[{
      type:"vless",server:"127.0.0.1",server_port:$server_port,uuid:$uuid,
      tls:{enabled:true,server_name:"node.example.com",insecure:true},transport:{type:"ws",path:"/samplews",headers:{Host:"node.example.com"}}}]}' >"$work/client.json"
# insecure=true exists only in this private self-signed loopback fixture.
sing-box run -c "$work/client.json" >"$work/client.log" 2>&1 & children+=("$!")
for ((i=0;i<40;i++)); do
    if curl --noproxy '' --proxy "socks5h://127.0.0.1:$socks_port" -fsS --max-time 1 "http://127.0.0.1:$http_port/" -o "$work/echo" 2>/dev/null; then break; fi
    sleep .1
done
[[ $(cat "$work/echo") == cf-ws-loopback-ok ]]
python3 - "$socks_port" "$udp_port" <<'PY'
import socket,struct,sys
def take(s,n):
 b=b''
 while len(b)<n:
  p=s.recv(n-len(b))
  if not p:raise OSError('closed')
  b+=p
 return b
s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),5);s.settimeout(5)
s.sendall(b'\x05\x01\x00');assert take(s,2)==b'\x05\x00'
s.sendall(b'\x05\x03\x00\x01'+b'\x00'*6);h=take(s,4);assert h[1]==0 and h[3]==1
address=socket.inet_ntoa(take(s,4));port=struct.unpack('!H',take(s,2))[0]
if address=='0.0.0.0':address='127.0.0.1'
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.settimeout(5)
u.sendto(b'\x00\x00\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',int(sys.argv[2]))+b'cf-ws-udp-echo',(address,port))
d,_=u.recvfrom(4096);assert d[10:]==b'cf-ws-udp-echo'
u.close();s.close()
PY
printf 'PASS: native nginx HTTPS/private subscription + VLESS-WS TCP/UDP loopback integration.\n'
