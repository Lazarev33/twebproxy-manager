#!/usr/bin/env python3
"""Real kernel owner tables + actual generated firewall helper in private netns.
Only a marked disposable guest, never host networking. Old JSON enumerator can
crash nft1.0.9; corrected discovery must coexist with foreign owned tables.
"""
import argparse,json,os,subprocess,sys,tempfile,time
from pathlib import Path
assert os.geteuid()==0 and Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()
p=argparse.ArgumentParser();p.add_argument('manager');p.add_argument('--inside',action='store_true');a=p.parse_args()
if not a.inside:
 env={**os.environ,'TWP_PARENT_NETNS':os.readlink('/proc/self/ns/net')}
 raise SystemExit(subprocess.run(['unshare','--net',sys.executable,__file__,a.manager,'--inside'],env=env).returncode)
assert os.readlink('/proc/self/ns/net')!=os.environ['TWP_PARENT_NETNS']
import resource;resource.setrlimit(resource.RLIMIT_CORE,(0,0))
owner=subprocess.Popen(['nft','-i'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
try:
 owner.stdin.write('add table inet twebproxy_guard { flags owner; }\n')
 owner.stdin.flush();time.sleep(.4)
 assert owner.poll() is None
 before=subprocess.check_output(['nft','list','table','inet','twebproxy_guard'],text=True);assert 'flags owner' in before
 results=[]
 with tempfile.TemporaryDirectory(prefix='twp-real-nft-owner-') as temp:
  root=Path(temp)
  for d in ['etc/backends','libexec','systemd']:(root/d).mkdir(parents=True,exist_ok=True);(root/d).chmod(0o700)
  (root/'etc').chmod(0o700)
  (root/'etc/backends/a.env').write_text('MTPROXY_CLIENT_PORT=23980\nMTPROXY_STATS_PORT=28980\n')
  code='source "$1"; trap - ERR; BASE_DIR="$2/etc"; BACKENDS_DIR="$BASE_DIR/backends"; FIREWALL_FILE="$BASE_DIR/firewall.nft"; LIBEXEC_DIR="$2/libexec"; SYSTEMD_DIR="$2/systemd"; write_backend_firewall_helper'
  subprocess.run(['bash','-c',code,'fixture',a.manager,temp],check=True,capture_output=True)
  for i in range(12):
   r=subprocess.run([str(root/'libexec/apply-firewall')],capture_output=True,text=True,timeout=35)
   if i==0 and r.returncode==0:
    owner.stdin.write('add table inet twb_0123456789ab { flags owner; }\n');owner.stdin.flush();time.sleep(.2)
   results.append({'attempt':i,'return_code':r.returncode,'stderr':r.stderr[-500:]})
   if r.returncode:break
 after=subprocess.check_output(['nft','list','table','inet','twebproxy_guard'],text=True)
 assert before==after and owner.poll() is None,'foreign table owner altered'
 status='PASS' if results and all(r['return_code']==0 for r in results) else 'FAIL'
 print(json.dumps({'kind':'REAL_KERNEL_PRIVATE_NETNS','status':status,'nft_version':subprocess.check_output(['nft','--version'],text=True).strip(),'foreign_owner_table_preserved':True,'results':results},indent=2));raise SystemExit(0 if status=='PASS' else 1)
finally:
 try:owner.stdin.close();owner.wait(timeout=5)
 except Exception:owner.kill();owner.wait()
