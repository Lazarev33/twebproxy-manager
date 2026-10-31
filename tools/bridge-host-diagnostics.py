#!/usr/bin/env python3
"""Root-only read-only diagnostic export. Never print configs, argv or credentials."""
import json,os,re,subprocess,time,platform,hashlib
from pathlib import Path

def command(a):
 try:
  p=subprocess.run(a,capture_output=True,text=True,timeout=8)
  return {'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
 except (OSError,subprocess.TimeoutExpired) as e:return {'rc':None,'error':type(e).__name__}

def main():
 if os.geteuid()!=0:raise SystemExit('root required')
 configs=list(Path('/var/lib/twebproxy-bridge').glob('*/config.json'))
 out={'schema':'twebproxy.bridge.safe-host-diagnostics.v1','at':time.time(),'kernel':platform.release(),'pid1':Path('/proc/1/comm').read_text().strip(),'nodes':[]}
 for f in configs:
  c=json.loads(f.read_text());owner=c['id']
  if not re.fullmatch('[0-9a-f]{32}',owner) or f.parent.name!=owner:raise SystemExit('invalid owner record')
  prefix='twb-'+owner[:12];units=['guard','wg']+(['mt'] if c['role']=='exit' else ['watch'])
  node={'id':owner,'role':c['role'],'executor_sha256':c.get('executor_sha256'),'units':{},'nft':command(['/usr/sbin/nft','list','table','inet','twb_'+owner[:12]]),'route':command(['/usr/sbin/ip','-j','route','get',c['peer_ip']]),'secret_file_permissions':{}}
  for suffix in units:
   u=prefix+'-'+suffix+'.service';node['units'][suffix]=command(['/usr/bin/systemctl','show',u,'-p','ActiveState','-p','SubState','-p','Result','-p','IPAddressDeny','-p','IPAddressAllow','-p','IPIngressBytes'])
  if c['role']=='entry':
   for ext in ['socket','service']:
    node['units']['forward.'+ext]=command(['/usr/bin/systemctl','show',prefix+'-forward.'+ext,'-p','ActiveState','-p','Result','-p','IPAddressDeny','-p','IPAddressAllow','-p','IPIngressBytes'])
  for p in [f.parent/'client-secret',Path('/etc/wireguard')/('twb-'+owner+'.key')]:
   if p.exists():st=p.stat();node['secret_file_permissions'][p.name]={'uid':st.st_uid,'mode':oct(st.st_mode&0o777)}
  if c['role']=='exit':
   pid=command(['/usr/bin/systemctl','show',prefix+'-mt.service','-p','MainPID','--value']).get('stdout','').strip()
   if pid.isdigit() and int(pid)>1:
    node['unprivileged_cmdline_read']=command(['/usr/bin/setpriv','--reuid=nobody','--regid=nogroup','--clear-groups','test','-r','/proc/'+pid+'/cmdline'])
    # No cat: even a policy failure must not put the secret into diagnostics.
  out['nodes'].append(node)
 print(json.dumps(out,indent=2))
if __name__=='__main__':main()
