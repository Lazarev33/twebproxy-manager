import sys,time,json,re
from pathlib import Path
import paramiko
p=paramiko.SSHClient();p.load_host_keys('/root/.ssh/twebproxy-gate3-known-hosts');p.set_missing_host_key_policy(paramiko.RejectPolicy());p.connect('179.66.186.143',username='root',key_filename='/root/.ssh/twebproxy-gate3-lab-access',look_for_keys=False,allow_agent=False,timeout=10)
cmd='TWEBPROXY_NO_LOG=1 TWEBPROXY_UI_LANGUAGE=en /usr/local/sbin/twebproxy menu';ch=p.get_transport().open_session();ch.get_pty(width=120,height=45);ch.exec_command(cmd);buf=b'';pos=0;steps=[];err=None;start=time.time();ansi=re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')
def expect(rx,answer,timeout=240):
 global buf,pos
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if ch.recv_ready():buf+=ch.recv(65536)
  text=ansi.sub(b'',buf[pos:]).decode(errors='replace')
  if re.search(rx,text,re.S|re.I):
   pos=len(buf);ch.sendall(answer+'\n');steps.append({'prompt':rx,'answered':True});print('answered '+rx,flush=True);return
  if ch.exit_status_ready():raise RuntimeError('early exit '+rx)
  time.sleep(.05)
 raise RuntimeError('timeout '+rx)
try:
 for pat,ans in [(r'Foreign Nodes / Bridge.*>\s*$','9'),(r'Add Foreign Node.*>\s*$','1'),(r'Foreign IPv4/hostname:\s*$','95.85.251.163'),(r'SSH port \[22\]:\s*$','22'),(r'SSH username \[root\]:\s*$','root'),(r'enter full SHA256 fingerprint:\s*$','SHA256:uAjDyEi2SzugVv3ZkXd1joL00OfpNcphK5KbzFHf1sc'),(r'Authentication \[key/password\]:\s*$','key'),(r'Existing private key path:\s*$','/root/.ssh/twp-gate3-bootstrap-exit'),(r'Approve installation\? \[yes/NO\]:\s*$','yes'),(r'(?:Press Enter|Нажми Enter)[^\n]*',''),(r'Add Foreign Node.*>\s*$','0'),(r'Foreign Nodes / Bridge.*>\s*$','0')]:expect(pat,ans)
except Exception as e:err=str(e)
end=time.monotonic()+20
while time.monotonic()<end:
 if ch.recv_ready():buf+=ch.recv(65536)
 if ch.exit_status_ready() and not ch.recv_ready():break
 if err:ch.close();break
 time.sleep(.1)
rc=ch.recv_exit_status() if ch.exit_status_ready() else 124;text=buf.decode(errors='replace');text=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',text);text=re.sub(r'(?im)(Secret:\s*)\S+',r'\1[REDACTED]',text)
Path('/root/projects/twebproxy/gate3-evidence/installed-menu-key-provision.log').write_text(json.dumps({'command':cmd,'start':start,'end':time.time(),'rc':rc,'steps':steps,'error':err})+'\n'+text);print(json.dumps({'rc':rc,'error':err,'steps':steps,'tail':text[-1200:]}));ch.close();p.close();sys.exit(0 if rc==0 and err is None else 1)
