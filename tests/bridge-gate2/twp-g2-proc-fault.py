import json,subprocess,time
from pathlib import Path
root=next(p for p in Path('/var/lib/twebproxy-bridge').iterdir() if p.is_dir());c=json.loads((root/'config.json').read_text());unit='twb-'+c['id'][:12]+'-mt.service';agent='/usr/local/libexec/twebproxy-bridge/'+c['id']+'/agent.py'
before=subprocess.run(['systemctl','is-active',unit],text=True,capture_output=True)
cmd=['unshare','--mount','--propagation','private','sh','-c','mount -t proc -o hidepid=0 proc /proc && setpriv --reuid=nobody --regid=nogroup --clear-groups cat /proc/1/comm && exec capsh --drop=cap_sys_admin -- -c "$1"','sh','/usr/bin/python3 '+agent+' job '+c['id']+' '+'a'*32]
p=subprocess.run(cmd,text=True,capture_output=True,timeout=50);after=subprocess.run(['systemctl','is-active',unit],text=True,capture_output=True)
host=subprocess.run(['setpriv','--reuid=nobody','--regid=nogroup','--clear-groups','cat','/proc/1/cmdline'],capture_output=True)
print(json.dumps({'test':'real failed remount in private mount namespace; real owned MT stop','at':time.time(),'command':cmd,'before':before.stdout.strip(),'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'backend_after':after.stdout.strip(),'backend_rc':after.returncode,'host_unpriv_proc_read_rc':host.returncode,'pass':before.returncode==0 and p.returncode!=0 and after.returncode!=0 and host.returncode!=0},indent=2))
