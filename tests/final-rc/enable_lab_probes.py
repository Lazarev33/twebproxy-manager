#!/usr/bin/env python3
"""Add loopback-only hypervisor forwards before any Manager installation.

Used once when preparing the initial clean guests. No live-host route/firewall
or proxy configuration change. Host keys and private overlay identities stay.
"""
import os
from pathlib import Path
import socket
import subprocess
import time

assert os.geteuid()==0 and socket.gethostname()=='VM-192306'
P=Path('/root/twp-finalrc-private');commands={}
for role,port in [('entry',22240),('exit',22241)]:
 unit='twp-finalrc-'+role
 pid=int(subprocess.check_output(['systemctl','show','-p','MainPID','--value',unit]))
 args=Path(f'/proc/{pid}/cmdline').read_bytes().decode().strip('\0').split('\0')
 assert args[0]=='/usr/bin/qemu-system-x86_64' and str(P/(role+'.qcow2')) in ' '.join(args)
 old=f'user,id=wan,hostfwd=tcp:127.0.0.1:{port}-:22';i=args.index(old)
 args[i]+=(',hostfwd=tcp:127.0.0.1:24443-:443,hostfwd=tcp:127.0.0.1:24080-:80,hostfwd=tcp:127.0.0.1:24680-:23980,hostfwd=tcp:127.0.0.1:24681-:28980' if role=='entry' else ',hostfwd=tcp:127.0.0.1:24890-:24990,hostfwd=tcp:127.0.0.1:24891-:29990')
 commands[role]=args
 a=['ssh','-i',str(P/'control_ed25519'),'-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={P}/{role}-known_hosts','-p',str(port),'root@127.0.0.1',
    'test ! -e /etc/twebproxy && test ! -e /var/lib/twebproxy-bridge && shutdown -h now']
 subprocess.run(a,check=True,capture_output=True,timeout=20)
for role in commands:
 for _ in range(50):
  if subprocess.run(['systemctl','is-active','--quiet','twp-finalrc-'+role]).returncode!=0:break
  time.sleep(.2)
 else:raise RuntimeError('guest shutdown not complete')
for role,args in commands.items():
 subprocess.run(['systemd-run','--unit=twp-finalrc-'+role,'--property=MemoryMax=2400M','--property=OOMPolicy=stop',*args],check=True)
 if role=='entry':
  for _ in range(50):
   if subprocess.check_output(['ss','-H','-ltn','sport = :27340']).strip():break
   time.sleep(.1)
