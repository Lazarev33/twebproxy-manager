#!/usr/bin/env python3
"""Actual installed Manager on marked disposable KVM guests; no live hosts.
Raw outputs/keys remain root-only. JSON evidence contains no client credentials.
Run --phase provision|verify|remove in order after install_clean_entry.py.
"""
import argparse, hashlib, json, os, re, subprocess, time
from pathlib import Path
P=Path('/root/twp-finalrc-private')
OUT=Path('/root/projects/twebproxy/final-rc-evidence'); OUT.mkdir(exist_ok=True)
assert os.geteuid()==0 and P.stat().st_mode & 0o077==0
RESULTS=[]
def ssh(role, command, check=True, timeout=180):
 a=['ssh','-i',str(P/'control_ed25519'),'-o','IdentitiesOnly=yes','-o','IdentityAgent=none',
    '-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(P/(role+'-known_hosts')),
    '-p',str(22240 if role=='entry' else 22241),'root@127.0.0.1','bash -s']
 r=subprocess.run(a,input=command,text=True,capture_output=True,timeout=timeout)
 if check and r.returncode: raise RuntimeError(f'{role} SSH command failed rc={r.returncode}; private log retained')
 return r

def record(name,role,command,timeout=180):
 start=time.time_ns();r=ssh(role,command,False,timeout)
 (P/(name+'.raw')).write_text(r.stdout+r.stderr)
 s=re.sub(r'(?i)tg://\S+','[PRIVATE_LINK]',r.stdout+r.stderr)
 s=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',s)
 s=re.sub(r'(?i)\b[0-9a-f]{32}\b','[PRIVATE_TOKEN]',s)
 (OUT/(name+'.log')).write_text(json.dumps({'command':command,'start_ns':start,'end_ns':time.time_ns(),'return_code':r.returncode})+'\n'+s)
 RESULTS.append({'test':name,'kind':'REAL_KVM','status':'PASS' if r.returncode==0 else 'FAIL','return_code':r.returncode})
 print(name,'RC',r.returncode,flush=True)
 if r.returncode:raise RuntimeError(name+' failed; inspect private and sanitized evidence')
 return r

for role in ['entry','exit']:
 ssh(role,'test "$(cat /etc/twebproxy-disposable-lab)" = "$(cat /etc/machine-id)" && test "$(cat /proc/1/comm)" = systemd')
p=argparse.ArgumentParser();p.add_argument('--phase',choices=['provision','verify','remove'],required=True);phase=p.parse_args().phase
try:
 if phase=='provision':
  record('fresh-exit-immediate-pre-add','exit', '''set -eu
test ! -e /usr/local/libexec
test ! -e /var/lib/twebproxy-bridge
printf 'libexec=ABSENT bridge_state=ABSENT\n'
systemctl is-active ssh
''')
  # Bootstrap identity is generated in Entry: no private key is transferred.
  ssh('entry', '''set -eu
test ! -e /root/.ssh/finalrc-exit-bootstrap
ssh-keygen -q -t ed25519 -N '' -C finalrc-disposable-bootstrap -f /root/.ssh/finalrc-exit-bootstrap
mkdir -m700 /root/finalrc-preservation
cp -a /etc/twebproxy/instances/bridge-rc.invalid /root/finalrc-preservation/instance
sha256sum /srv/twebproxy/bridge-rc.invalid/index.html /etc/ssl/twebproxy-finalrc/leaf.crt > /root/finalrc-preservation/content.sha256
''')
  pub=ssh('entry','cat /root/.ssh/finalrc-exit-bootstrap.pub').stdout.strip()
  assert re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+ finalrc-disposable-bootstrap',pub)
  ssh('exit',"printf '%s\\n' '"+pub+"' >> /root/.ssh/authorized_keys\nchmod 600 /root/.ssh/authorized_keys\n")
  record('clean-foreign-add','entry', '''TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 /usr/local/sbin/twebproxy foreign-node add --host 192.0.2.21 --port 22 --user root --auth key --identity /root/.ssh/finalrc-exit-bootstrap --fingerprint SHA256:h7D3lmwxhuaixJIuHZwgRGqxlHtuTA+N0c028Vp4aZc --entry-endpoint 192.0.2.20 --instance bridge-rc.invalid --approve
''',timeout=1800)
 if phase=='verify':
  status=json.loads(record('installed-bridge-status','entry','/usr/local/sbin/twebproxy foreign-node status').stdout)
  assert status['phase']=='active' and not status.get('cleanup_debt')
  assert all(status['checks'].get(k)=='OK' for k in ['bridge.peer.route','bridge.exit.tcp','bridge.exit.service','bridge.security.boundary'])
  record('fresh-exit-postconditions','exit', '''set -eu
python3 - <<'REMOTE'
import json,os,stat,subprocess
from pathlib import Path
for p in ['/usr/local/libexec','/usr/local/libexec/twebproxy-bridge']:
 st=os.lstat(p);assert stat.S_ISDIR(st.st_mode) and st.st_uid==0 and stat.S_IMODE(st.st_mode)==0o755
 print(p,oct(stat.S_IMODE(st.st_mode)),st.st_uid)
c=json.loads(next(Path('/var/lib/twebproxy-bridge').glob('*/config.json')).read_text());prefix='twb-'+c['id'][:12]
for suffix in ['guard','wg','mt']:
 unit=prefix+'-'+suffix+'.service'
 print(subprocess.check_output(['systemctl','show',unit,'-p','ActiveState','-p','NRestarts','-p','DynamicUser','-p','IPAddressDeny','-p','IPAddressAllow'],text=True))
 assert subprocess.run(['systemctl','is-active','--quiet',unit]).returncode==0
print(subprocess.check_output(['wg','show'],text=True))
print(subprocess.check_output(['nft','list','table','inet','twb_'+c['id'][:12]],text=True))
REMOTE
''')
  record('bridge-repeatable-repair','entry','TWEBPROXY_NO_LOG=1 /usr/local/sbin/twebproxy foreign-node repair',timeout=600)
 if phase=='remove':
  record('bridge-removal','entry','TWEBPROXY_NO_LOG=1 /usr/local/sbin/twebproxy foreign-node remove --approve',timeout=600)
  record('entry-restored-post-removal','entry', '''set -eu
/usr/local/sbin/twebproxy foreign-node status
sha256sum -c /root/finalrc-preservation/content.sha256
systemctl is-active twebproxy@bridge-rc.invalid.service twebproxy-mtproxy@bridge-rc.invalid--default.service nginx ssh
python3 - <<'REMOTE'
from pathlib import Path
import hashlib,json
old=Path('/root/finalrc-preservation/instance');new=Path('/etc/twebproxy/instances/bridge-rc.invalid')
for p in old.rglob('*'):
 if p.is_file():
  q=new/p.relative_to(old);assert q.is_file() and q.read_bytes()==p.read_bytes(),str(p.relative_to(old))
print('Original local profile/secret/settings bytes restored')
assert not (new/'bridge.json').exists() and not (new/'bridge.owner').exists()
REMOTE
''')
finally:
 (OUT/('REAL-KVM-'+phase+'.json')).write_text(json.dumps(RESULTS,indent=2)+'\n')
