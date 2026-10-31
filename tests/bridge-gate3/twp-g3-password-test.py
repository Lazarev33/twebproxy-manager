#!/usr/bin/python3
import secrets,subprocess,time,json,re,sys
from pathlib import Path
import paramiko
user='twb-g3-bootstrap-fixture';password=secrets.token_urlsafe(36);conf=Path('/etc/ssh/sshd_config.d/00-twp-g3-password-fixture.conf');sudo=Path('/etc/sudoers.d/twp-g3-bootstrap-fixture')
def run(a,**kw):return subprocess.run(a,check=True,**kw)
assert subprocess.run(['id','-u',user],capture_output=True).returncode!=0
run(['useradd','-m','-s','/bin/sh',user]);run(['chpasswd'],input=user+':'+password+'\n',text=True)
sudo.write_text(user+' ALL=(root) NOPASSWD: ALL\n');sudo.chmod(0o440)
conf.write_text('Match User '+user+' Address 179.66.186.143\n    PasswordAuthentication yes\n    KbdInteractiveAuthentication no\nMatch all\n');run(['/usr/sbin/sshd','-t']);run(['systemctl','reload','ssh'])
ssh=paramiko.SSHClient();ssh.load_host_keys('/root/.ssh/twebproxy-gate3-known-hosts');ssh.set_missing_host_key_policy(paramiko.RejectPolicy());ssh.connect('179.66.186.143',username='root',key_filename='/root/.ssh/twebproxy-gate3-lab-access',look_for_keys=False,allow_agent=False,timeout=10)
cmd='/usr/local/sbin/twebproxy foreign-node add --host 95.85.251.163 --user '+user+' --auth password --fingerprint SHA256:uAjDyEi2SzugVv3ZkXd1joL00OfpNcphK5KbzFHf1sc --instance martins.ortositi.ru --approve'
ch=ssh.get_transport().open_session();ch.get_pty();ch.exec_command(cmd);buf=b'';sent=False;start=time.time();deadline=time.monotonic()+1000
try:
 while time.monotonic()<deadline:
  if ch.recv_ready():
   buf+=ch.recv(65536)
   if not sent and (b'(memory only): ' in buf or 'памяти): '.encode() in buf):ch.sendall(password+'\n');sent=True
  if ch.exit_status_ready() and not ch.recv_ready():break
  time.sleep(.05)
 else:raise RuntimeError('deadline')
 rc=ch.recv_exit_status();text=buf.decode(errors='replace');absent=password not in text
 text=text.replace(password,'[PASSWORD-LEAK-REDACTED]');text=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',text);text=re.sub(r'(?im)(Secret:\s*)\S+',r'\1[REDACTED]',text)
 Path('/root/projects/twebproxy/gate3-evidence/installed-password-bootstrap.log').write_text(json.dumps({'start':start,'end':time.time(),'command':cmd,'rc':rc,'password_sent_hidden_prompt':sent,'password_absent_transcript':absent,'password_storage':'harness memory only; chpasswd/PTY stdin; never argv/env/file'})+'\n'+text)
 print(json.dumps({'rc':rc,'hidden_prompt_seen':sent,'password_absent_transcript':absent,'last_output':text[-350:]}));assert rc==0 and sent and absent
finally:
 password=None;ch.close();ssh.close();conf.unlink(missing_ok=True);sudo.unlink(missing_ok=True);run(['/usr/sbin/sshd','-t']);run(['systemctl','reload','ssh']);run(['userdel','--remove',user],capture_output=True)
