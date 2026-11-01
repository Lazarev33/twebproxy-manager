#!/usr/bin/env python3
"""Actual repair/site/TLS preservation and deliberate CLI deletion/core-uninstall.
Only on the independently clean Entry retest guest; raw logs stay private.
"""
import hashlib,json,os,socket,subprocess,time
from pathlib import Path
assert os.geteuid()==0 and socket.gethostname()=='twp-finalrc-clean-entry'
assert Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()
assert not Path('/etc/twebproxy/bridge/node.json').exists()
OUT=Path('/root/finalrc-install-private');rows=[]
env={**os.environ,'TWEBPROXY_UI_LANGUAGE':'ru','TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1'}
def run(name,args,answer=None):
 start=time.time_ns()
 with (OUT/(name+'.raw')).open('wb') as f:r=subprocess.run(args,input=answer,stdout=f,stderr=subprocess.STDOUT,env=env,timeout=900)
 rows.append({'test':name,'return_code':r.returncode,'status':'PASS' if r.returncode==0 else 'FAIL','start_ns':start,'end_ns':time.time_ns()});assert r.returncode==0,name
site=Path('/srv/twebproxy/bridge-rc.invalid/index.html');site.write_bytes(site.read_bytes()+b'\n<!-- operator-edited RC preservation witness -->\n')
paths=[site,Path('/etc/ssl/twebproxy-finalrc/leaf.crt'),Path('/etc/ssl/twebproxy-finalrc/leaf.key'),Path('/etc/twebproxy/instances/bridge-rc.invalid/profiles.d/default.env')]
def hashes():return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
before=hashes()
canary=Path('/etc/nginx/conf.d/finalrc-unrelated.conf');assert not canary.exists()
canary.write_text('server { listen 127.0.0.1:18090; server_name unrelated.invalid; location / { return 200 "unrelated-preserved\\n"; } }\n');canary.chmod(0o644)
subprocess.run(['nginx','-t'],check=True,capture_output=True);subprocess.run(['systemctl','reload','nginx'],check=True)
canary_hash=hashlib.sha256(canary.read_bytes()).hexdigest()
try:
 run('ordinary-installed-repair',['/usr/local/sbin/twebproxy','repair','bridge-rc.invalid'])
 assert hashes()==before,'repair changed operator site/TLS/profile'
 rows.append({'test':'edited-site-profile-secret-TLS-preserved','status':'PASS'})
 run('ordinary-instance-delete',['/usr/local/sbin/twebproxy','delete','bridge-rc.invalid'],'да\n'.encode())
 run('ordinary-core-uninstall',['/usr/local/sbin/twebproxy','core-uninstall'],'да\n'.encode())
 assert not Path('/etc/twebproxy').exists() and not Path('/usr/local/bin/tproxy-server').exists()
 assert Path('/usr/local/sbin/twebproxy').exists(),'documented Manager retention'
 assert hashlib.sha256(canary.read_bytes()).hexdigest()==canary_hash
 assert subprocess.check_output(['curl','--fail','--silent','http://127.0.0.1:18090/'])==b'unrelated-preserved\n'
 subprocess.run(['systemctl','is-active','--quiet','ssh','nginx'],check=True)
 tables=subprocess.check_output(['nft','list','tables'],text=True)
 assert 'twebproxy_backend' not in tables and 'twebproxy_guard' not in tables
 rows.append({'test':'uninstall-postconditions-unrelated-nginx-SSH-preserved','status':'PASS'})
finally:
 (OUT/'cleanup-results.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows))
