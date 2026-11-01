#!/usr/bin/env python3
"""Create ONLY new disposable Ubuntu24.04 KVM overlays for final RC checks.

No live VPS or host firewall/routes are changed. Private control/host keys,
cloud-init seeds and disks stay in the root-only private directory, never ZIPs.
"""
import hashlib,json,os,subprocess,time
from pathlib import Path
import socket

assert os.geteuid()==0 and socket.gethostname()=='VM-192306'
P=Path('/root/twp-finalrc-private');assert not P.exists();P.mkdir(mode=0o700)
os.umask(0o077)
base=Path('/root/twp-gate3-private/clean-vm/noble-server-cloudimg-amd64.img')
with base.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()=='04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94'
subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-C','twebproxy-final-rc-disposable','-f',str(P/'control_ed25519')],check=True)
public=(P/'control_ed25519.pub').read_text().strip()
for role,last,port in [('entry','20',22240),('exit','21',22241)]:
 disk=P/(role+'.qcow2');seed=P/(role+'-seed.img')
 subprocess.run(['qemu-img','create','-q','-f','qcow2','-F','qcow2','-b',str(base),str(disk),'18G'],check=True)
 user={'disable_root':False,'ssh_pwauth':False,'users':[{'name':'root','lock_passwd':True,'ssh_authorized_keys':[public]}],
       'runcmd':[['cp','/etc/machine-id','/etc/twebproxy-disposable-lab'],['chmod','0600','/etc/twebproxy-disposable-lab'],
                  ['sh','-c','printf "TWP_LAB_HOSTKEY "; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub']]}
 (P/(role+'-user-data')).write_text('#cloud-config\n'+json.dumps(user,indent=2)+'\n')
 (P/(role+'-meta-data')).write_text('instance-id: twp-finalrc-clean-'+role+'\nlocal-hostname: twp-finalrc-clean-'+role+'\n')
 network={'version':2,'ethernets':{'wan':{'match':{'macaddress':'52:54:00:26:30:'+last},'set-name':'wan0','dhcp4':True},'lab':{'match':{'macaddress':'52:54:00:26:31:'+last},'set-name':'lab0','addresses':['192.0.2.'+last+'/24']}}}
 (P/(role+'-network')).write_text(json.dumps(network))
 subprocess.run(['cloud-localds','--network-config='+str(P/(role+'-network')),str(seed),str(P/(role+'-user-data')),str(P/(role+'-meta-data'))],check=True)
 forwards=f'user,id=wan,hostfwd=tcp:127.0.0.1:{port}-:22'
 forwards+=(',hostfwd=tcp:127.0.0.1:24443-:443,hostfwd=tcp:127.0.0.1:24080-:80,hostfwd=tcp:127.0.0.1:24680-:23980,hostfwd=tcp:127.0.0.1:24681-:28980' if role=='entry' else ',hostfwd=tcp:127.0.0.1:24890-:24990,hostfwd=tcp:127.0.0.1:24891-:29990')
 a=['systemd-run','--unit=twp-finalrc-'+role,'--property=MemoryMax=2400M','--property=OOMPolicy=stop',
    '/usr/bin/qemu-system-x86_64','-enable-kvm','-cpu','host','-smp','2','-m','1280','-display','none',
    '-serial','file:'+str(P/(role+'-console.log')),'-monitor','none',
    '-drive',f'file={disk},format=qcow2,if=virtio,cache=none','-drive',f'file={seed},format=raw,if=virtio,cache=none',
    '-netdev',forwards,'-device','virtio-net-pci,netdev=wan,mac=52:54:00:26:30:'+last,
    '-netdev','socket,id=lab,'+('listen' if role=='entry' else 'connect')+'=127.0.0.1:27340',
    '-device','e1000,netdev=lab,mac=52:54:00:26:31:'+last,'-no-reboot']
 subprocess.run(a,check=True)
 if role=='entry':
  for _ in range(50):
   if subprocess.check_output(['ss','-H','-ltn','sport = :27340']).strip():break
   time.sleep(.1)
  else:raise RuntimeError('private entry link listener absent')
print('NEW_CLEAN_DISPOSABLE_GUESTS_STARTED')
