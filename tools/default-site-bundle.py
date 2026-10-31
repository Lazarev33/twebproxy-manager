#!/usr/bin/env python3
"""Build integrity metadata for the fixed, checked-in default website. No generation."""
import hashlib,json,re
from pathlib import Path
root=Path(__file__).resolve().parents[1];site=root/'sites/podmoskovye';records={}
for p in sorted(site.rglob('*')):
 if p.is_symlink():raise SystemExit('symlinks are not allowed')
 if p.is_file() and p.name!='MANIFEST.json':records[str(p.relative_to(site))]=hashlib.sha256(p.read_bytes()).hexdigest()
(site/'MANIFEST.json').write_text(json.dumps(records,sort_keys=True,indent=2)+'\n');digest=hashlib.sha256((site/'MANIFEST.json').read_bytes()).hexdigest();manager=root/'twebproxy-manager.sh';s=manager.read_text();s,n=re.subn(r'DEFAULT_SITE_MANIFEST_SHA256="[^"]*"','DEFAULT_SITE_MANIFEST_SHA256="'+digest+'"',s);assert n==1;manager.write_text(s);print(digest)
