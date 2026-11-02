#!/usr/bin/env python3
"""New independent Entry overlay after fixing laboratory DNS/CA prerequisites.
Preserves the initial failed/repaired guest, all logs, and the Bridge pair.
"""
import hashlib,json,os,subprocess
from pathlib import Path
assert os.geteuid()==0
P=Path('/root/twp-finalrc-private');base=Path('/root/twp-gate3-private/clean-vm/noble-server-cloudimg-amd64.img')
with base.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()=='04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94'
os.umask(0o077)
disk=P/'entry-retest.qcow2';assert not disk.exists()
subprocess.run(['qemu-img','create','-q','-f','qcow2','-F','qcow2','-b',str(base),str(disk),'18G'],check=True)
public=(P/'control_ed25519.pub').read_text().strip()
user={'disable_root':False,'ssh_pwauth':False,'users':[{'name':'root','lock_passwd':True,'ssh_authorized_keys':[public]}],
'runcmd':[['cp','/etc/machine-id','/etc/twebproxy-disposable-lab'],['chmod','0600','/etc/twebproxy-disposable-lab'],['sh','-c','printf "TWP_LAB_HOSTKEY "; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub']]}
(P/'entry-retest-user-data').write_text('#cloud-config\n'+json.dumps(user))
(P/'entry-retest-meta-data').write_text('instance-id: twp-finalrc-entry-retest\nlocal-hostname: twp-finalrc-clean-entry\n')
network={'version':2,'ethernets':{'wan':{'match':{'macaddress':'52:54:00:26:32:22'},'dhcp4':True},'lab':{'match':{'macaddress':'52:54:00:26:33:22'},'addresses':['192.0.2.20/24']}}}
(P/'entry-retest-network').write_text(json.dumps(network))
seed=P/'entry-retest-seed.img'
subprocess.run(['cloud-localds','--network-config='+str(P/'entry-retest-network'),str(seed),str(P/'entry-retest-user-data'),str(P/'entry-retest-meta-data')],check=True)
subprocess.run(['systemd-run','--unit=twp-finalrc-entry-retest','--property=MemoryMax=2200M','--property=OOMPolicy=stop',
'/usr/bin/qemu-system-x86_64','-enable-kvm','-cpu','host','-smp','1','-m','1152','-display','none','-serial','file:'+str(P/'entry-retest-console.log'),'-monitor','none',
'-drive',f'file={disk},format=qcow2,if=virtio,cache=none','-drive',f'file={seed},format=raw,if=virtio,cache=none',
'-netdev','user,id=wan,hostfwd=tcp:127.0.0.1:22242-:22','-device','virtio-net-pci,netdev=wan,mac=52:54:00:26:32:22',
'-netdev','socket,id=lab,listen=127.0.0.1:27342','-device','e1000,netdev=lab,mac=52:54:00:26:33:22','-no-reboot'],check=True)
