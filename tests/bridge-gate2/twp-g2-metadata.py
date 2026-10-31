import json,hashlib,subprocess,time
from pathlib import Path
base=Path('/etc/twebproxy/instances/gate2.invalid')
paths=[base/'instance.env',base/'profiles.d/default.env',base/'profiles.json',Path('/etc/twebproxy/global.env'),Path('/etc/twebproxy/backends/gate2.invalid--default.env')]
s={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
s.update({'node_exists':Path('/etc/twebproxy/bridge/node.json').exists(),'sidecar_exists':(base/'bridge.json').exists(),'owner_exists':(base/'bridge.owner').exists(),'original_backend':subprocess.run(['systemctl','is-active','twebproxy-mtproxy@gate2.invalid--default.service'],text=True,capture_output=True).stdout.strip()})
print(json.dumps(s,indent=2))
