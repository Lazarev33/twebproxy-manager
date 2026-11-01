#!/usr/bin/env python3
"""Disposable QEMU usernet fixture ONLY, never a product topology/default.
Stock MTProxy RPC handshake needs actual external IP behind hypervisor NAT.
Temporary ExecStart adds its existing --nat-info; security policies are retained.
Run on marked Exit with apply|remove. Does not edit distributed agent/runtime.
"""
import argparse,ipaddress,json,os,subprocess
from pathlib import Path
assert Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()
a=argparse.ArgumentParser();a.add_argument('action',choices=['apply','remove']);a=a.parse_args()
c=json.loads(next(Path('/var/lib/twebproxy-bridge').glob('*/config.json')).read_text());unit='twb-'+c['id'][:12]+'-mt.service'
lib=Path('/usr/local/libexec/twebproxy-bridge')/c['id'];runner=lib/'test-run-mt-nat.py';drop=Path('/run/systemd/system')/(unit+'.d')/'90-finalrc-lab-nat.conf'
if a.action=='apply':
 assert not drop.exists() and not runner.exists()
 external=subprocess.check_output(['curl','--fail','--silent','--show-error','--max-time','10','https://api.ipify.org'],text=True).strip();assert ipaddress.ip_address(external).is_global
 local='10.0.2.15';text=(lib/'run-mt.py').read_text();assert text.count('"4096"])')==1
 runner.write_text(text.replace('"4096"])','"4096","--nat-info",'+repr(local+':'+external)+'])'));runner.chmod(0o755)
 drop.parent.mkdir(exist_ok=True);drop.write_text('[Service]\nExecStart=\nExecStart=/usr/bin/python3 '+str(runner)+'\n')
else:
 drop.unlink(missing_ok=True);runner.unlink(missing_ok=True)
 try:drop.parent.rmdir()
 except OSError:pass
subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','restart',unit],check=True)
print(json.dumps({'fixture':'QEMU usernet MTProxy RPC NAT identity','action':a.action,'unit':unit,'not_product_change':True}))
