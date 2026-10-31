import sys,time,json,re
from pathlib import Path
import paramiko
p=paramiko.SSHClient();p.load_host_keys('/root/.ssh/twebproxy-gate3-known-hosts');p.set_missing_host_key_policy(paramiko.RejectPolicy());p.connect('179.66.186.143',username='root',key_filename='/root/.ssh/twebproxy-gate3-lab-access',look_for_keys=False,allow_agent=False,timeout=10)
cmd='TWEBPROXY_NO_LOG=1 TWEBPROXY_UI_LANGUAGE=en /usr/local/sbin/twebproxy add';ch=p.get_transport().open_session();ch.get_pty(width=120,height=40);ch.exec_command(cmd);buf=b'';pos=0;steps=[];err=None;start=time.time()
ansi=re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')
def expect(rx,answer,timeout=400):
 global buf,pos
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if ch.recv_ready():buf+=ch.recv(65536)
  text=ansi.sub(b'',buf[pos:]).decode(errors='replace')
  if re.search(rx,text,re.S|re.I):pos=len(buf);ch.sendall(answer+'\n');steps.append({'prompt':rx,'answered':True});print('answered '+rx,flush=True);return
  if ch.exit_status_ready():raise RuntimeError('early exit waiting '+rx)
  time.sleep(.05)
 raise RuntimeError('timeout waiting '+rx)
try:
 for pattern,answer in [(r'Hostname[^\n]*:\s*$','martins.ortositi.ru'),(r'Setup type:.*>\s*$','1'),(r'Regular website on the hostname:.*>\s*$','1'),(r'SSL / reverse proxy:.*>\s*$','1'),(r'Email[^\n]*:\s*$','bizkillerru@gmail.com'),(r'Create it\? \[Y/n\]:\s*$','y')]:expect(pattern,answer)
except Exception as e:err=str(e)
end=time.monotonic()+500
while time.monotonic()<end:
 if ch.recv_ready():buf+=ch.recv(65536)
 if ch.exit_status_ready() and not ch.recv_ready():break
 if err:ch.close();break
 time.sleep(.1)
rc=ch.recv_exit_status() if ch.exit_status_ready() else 124
text=buf.decode(errors='replace');text=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',text);text=re.sub(r'(?im)(Secret:\s*)\S+',r'\1[REDACTED]',text)
E=Path('/root/projects/twebproxy/gate3-evidence');(E/'entry-bundled-default-add-pty.log').write_text(json.dumps({'command':cmd,'start':start,'end':time.time(),'rc':rc,'error':err,'steps':steps})+'\n'+text);print(json.dumps({'rc':rc,'error':err,'steps':steps,'tail':text[-1800:]}));ch.close();p.close();sys.exit(0 if rc==0 and err is None else 1)
