#!/usr/bin/env python3
"""Rebuild the reviewed source bundle digest; never downloads dependencies."""
import hashlib,json,re
from pathlib import Path
root=Path(__file__).resolve().parents[1];b=root/'bridge'
import shutil
for cache in b.rglob('__pycache__'):
 if cache.is_symlink():cache.unlink()
 else:shutil.rmtree(cache)
files=[p for p in b.rglob('*') if p.is_file() and p.name!='MANIFEST.json' and '__pycache__' not in p.parts]
manifest={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
raw=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode();(b/'MANIFEST.json').write_bytes(raw)
p=root/'twebproxy-manager.sh';s=p.read_text();s=re.sub(r'^BRIDGE_MANIFEST_SHA256=.*$', 'BRIDGE_MANIFEST_SHA256="'+hashlib.sha256(raw).hexdigest()+'"',s,flags=re.M);s=re.sub(r'^BRIDGE_LAUNCHER_SHA256=.*$', 'BRIDGE_LAUNCHER_SHA256="'+hashlib.sha256((b/'launcher.py').read_bytes()).hexdigest()+'"',s,flags=re.M);p.write_text(s)
print(hashlib.sha256(raw).hexdigest())
