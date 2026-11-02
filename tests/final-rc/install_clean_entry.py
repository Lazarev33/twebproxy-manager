#!/usr/bin/env python3
"""Genuine first Manager/core/profile install on the marked clean Entry guest.

Normal Advanced UI and existing nginx-custom integration. An ephemeral test CA
is explicit lab trust, NOT public ACME. No prepared proxy/backend binary exists.
Raw output and private TLS keys stay on the disposable guest, outside delivery.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import tarfile
import time

assert os.geteuid()==0 and socket.gethostname()=='twp-finalrc-clean-entry'
assert Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()
assert not Path('/etc/twebproxy').exists() and not Path('/usr/local/bin/tproxy-server').exists()
os.umask(0o077)
OUT=Path('/root/finalrc-install-private');OUT.mkdir(mode=0o700)
archive=Path(sys.argv[1]);expected=sys.argv[2]
assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected
source=Path('/root/finalrc-candidate');source.mkdir(mode=0o700)
with tarfile.open(archive,'r:gz') as t:
 for member in t:
  assert member.isfile() and not member.name.startswith('/') and '..' not in Path(member.name).parts
 t.extractall(source,filter='data')
pin=json.loads((source/'DISTRIBUTION.json').read_text())['components_sha256']
subprocess.run([sys.executable,'-I',str(source/'updater/engine.py'),'verify',str(source),pin,'--source'],check=True)
tls=Path('/etc/ssl/twebproxy-finalrc');tls.mkdir(mode=0o700)
def quiet(args):subprocess.run(args,check=True,capture_output=True)
quiet(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','90',
       '-subj','/CN=TWebProxy isolated RC test CA','-keyout',str(tls/'ca.key'),'-out',str(tls/'ca.crt')])
quiet(['openssl','req','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-subj','/CN=bridge-rc.invalid',
       '-keyout',str(tls/'leaf.key'),'-out',str(tls/'leaf.csr')])
(tls/'extensions').write_text('subjectAltName=DNS:bridge-rc.invalid\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
quiet(['openssl','x509','-req','-in',str(tls/'leaf.csr'),'-CA',str(tls/'ca.crt'),'-CAkey',str(tls/'ca.key'),
       '-CAcreateserial','-days','90','-sha256','-extfile',str(tls/'extensions'),'-out',str(tls/'leaf.crt')])
for p in tls.glob('*.key'):p.chmod(0o600)
# The normal Manager's own TLS audit must verify the fixture too. This is
# explicit private-lab DNS/CA trust, not public DNS/ACME or a verification bypass.
trust=Path('/usr/local/share/ca-certificates/twebproxy-finalrc.crt')
shutil.copyfile(tls/'ca.crt',trust);trust.chmod(0o644)
quiet(['update-ca-certificates'])
with Path('/etc/hosts').open('a') as f:f.write('\n192.0.2.20 bridge-rc.invalid # isolated final RC fixture\n')
env={**os.environ,'TWEBPROXY_UI_LANGUAGE':'ru','TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1',
     'NO_COLOR':'1','GOMAXPROCS':'1','GOFLAGS':'-p=1'}
# Same normal Advanced controller used by the installed TUI; explicit approvals,
# default profile/secret/ports, HTTPS carrier, one worker and preserved STOCK.
answers='bridge-rc.invalid\ny\n1\n3\n'+str(tls/'leaf.crt')+'\n'+str(tls/'leaf.key')+'\n\ny\n1\ny\n1\ny\ny\n'
start=time.time_ns()
with (OUT/'normal-advanced-install.raw').open('wb') as f:
 p=subprocess.run(['bash',str(source/'twebproxy-manager.sh'),'tui-internal','advanced-add'],input=answers.encode(),
                  stdout=f,stderr=subprocess.STDOUT,env=env,timeout=2100)
result={'return_code':p.returncode,'start_ns':start,'end_ns':time.time_ns(),'runtime_archive_sha256':expected,
        'fresh_base_image':True,'normal_Advanced_UI':True,'prepared_backend_binary':False,'public_ACME':False,
        'TLS':'nginx-custom + explicitly trusted ephemeral laboratory CA'}
(OUT/'RESULTS.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
assert p.returncode==0
for unit in ['nginx.service','ssh.service','twebproxy@bridge-rc.invalid.service','twebproxy-mtproxy@bridge-rc.invalid--default.service']:
 subprocess.run(['systemctl','is-active','--quiet',unit],check=True)
assert Path('/srv/twebproxy/bridge-rc.invalid/index.html').exists()
result['status']='PASS';result['installed_manager_sha256']=hashlib.sha256(Path('/usr/local/sbin/twebproxy').read_bytes()).hexdigest()
(OUT/'RESULTS.json').write_text(json.dumps(result,indent=2)+'\n')
print('GENUINE_CLEAN_ENTRY_INSTALL=PASS',flush=True)
