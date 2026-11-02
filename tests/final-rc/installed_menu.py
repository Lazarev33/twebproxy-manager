#!/usr/bin/env python3
"""Real installed TUI, safe status-only commands on marked disposable Entry."""
import subprocess,json,re,time
from pathlib import Path
P=Path('/root/twp-finalrc-private');E=Path('/root/projects/twebproxy/final-rc-evidence')
a=['ssh','-i',str(P/'control_ed25519'),'-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(P/'entry-known_hosts'),'-p','22240','root@127.0.0.1']
subprocess.run(a+['cmp -s /etc/twebproxy-disposable-lab /etc/machine-id'],check=True)
snapshot="sha256sum /etc/twebproxy/bridge/node.json /etc/twebproxy/instances/bridge-rc.invalid/profiles.d/default.env; systemctl show twebproxy@bridge-rc.invalid.service -p MainPID -p NRestarts"
before=subprocess.check_output(a+[snapshot],text=True)
start=time.time_ns()
r=subprocess.run([*a[:-1],'-tt',a[-1],'env TERM=xterm TWEBPROXY_UI_LANGUAGE=en TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 /usr/local/sbin/twebproxy menu'],input='9\n1\n\n0\n0\n',text=True,capture_output=True,timeout=100)
(P/'installed-menu.raw').write_text(r.stdout+r.stderr)
s=re.sub(r'\x1b\[[0-9;?]*[A-Za-z]','',r.stdout+r.stderr)
s=re.sub(r'(?i)tg://\S+','[PRIVATE_LINK]',s);s=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',s);s=re.sub(r'(?i)\b[0-9a-f]{32}\b','[PRIVATE_TOKEN]',s)
(E/'installed-menu.log').write_text(s)
after=subprocess.check_output(a+[snapshot],text=True)
assert r.returncode==0 and 'twebproxy.bridge.status.v1' in s and 'Foreign Nodes' in s
assert before==after,'state or relay process changed during status-only TUI'
result={'status':'PASS','kind':'REAL_KVM_INSTALLED_TUI','return_code':r.returncode,'start_ns':start,'end_ns':time.time_ns(),'sequence':'main9 -> Foreign Nodes status1 -> back0 -> exit0','state_and_relay_unchanged':True}
(E/'installed-menu-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
