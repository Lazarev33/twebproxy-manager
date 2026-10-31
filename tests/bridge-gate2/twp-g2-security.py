import json,subprocess,time,os
from pathlib import Path
root=next(p for p in Path('/var/lib/twebproxy-bridge').iterdir() if p.is_dir());c=json.loads((root/'config.json').read_text());u='twb-'+c['id'][:12]+'-mt.service'
def run(a):
 p=subprocess.run(a,text=True,capture_output=True);return {'argv':a,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
pid=subprocess.check_output(['systemctl','show',u,'-p','MainPID','--value'],text=True).strip()
r={'at':time.time(),'os':Path('/etc/os-release').read_text(),'kernel':os.uname().release,'pid1':Path('/proc/1/comm').read_text(),'caps':run(['capsh','--print']),'nft_version':run(['nft','--version']),'nft':run(['nft','list','table','inet','twb_'+c['id'][:12]]),'policy':run(['systemctl','show',u,'-p','IPAddressDeny','-p','IPAddressAllow','-p','IPIngressBytes','-p','ActiveState','-p','MainPID']),'secret_files':{str(p):{'mode':oct(p.stat().st_mode&0o777),'uid':p.stat().st_uid} for p in [root/'client-secret',Path('/etc/wireguard')/('twb-'+c['id']+'.key')]},'unpriv_cmdline':run(['setpriv','--reuid=nobody','--regid=nogroup','--clear-groups','cat','/proc/'+pid+'/cmdline']),'unpriv_environ':run(['setpriv','--reuid=nobody','--regid=nogroup','--clear-groups','cat','/proc/'+pid+'/environ'])}
print(json.dumps(r,indent=2))
