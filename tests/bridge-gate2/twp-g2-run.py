#!/usr/bin/python3
import subprocess,time,json,re,sys
from pathlib import Path
E=Path('/tmp/twp-g2-evidence');E.mkdir(exist_ok=True)
def redact(t):
 t=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',t)
 t=re.sub(r'(?im)(Secret:\s*)\S+',r'\1[REDACTED]',t)
 return t
name=sys.argv[1];cmd=sys.argv[2];start=time.time()
p=subprocess.run(['ssh','-F','/root/.ssh/twp-g2-lab-config','g2-entry',cmd],text=True,capture_output=True)
s=redact(p.stdout+p.stderr)
(E/(name+'.log')).write_text(json.dumps({'start':start,'end':time.time(),'command':cmd,'rc':p.returncode})+'\n'+s)
print(json.dumps({'name':name,'rc':p.returncode,'last_output':s[-2200:]}))
sys.exit(p.returncode)
