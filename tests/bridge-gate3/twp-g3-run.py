import subprocess,re,json,time,sys
from pathlib import Path
name,cmd=sys.argv[1:3];start=time.time();p=subprocess.run(['ssh','-F','/root/.ssh/twp-g3-lab-config','g3-entry',cmd],text=True,capture_output=True)
s=p.stdout+p.stderr;s=re.sub(r'(?i)(secret=|bridge=)[^\s&"<>]+',r'\1[REDACTED]',s);s=re.sub(r'(?im)(Secret:\s*)\S+',r'\1[REDACTED]',s)
Path('/root/projects/twebproxy/gate3-evidence/'+name+'.log').write_text(json.dumps({'command':cmd,'start':start,'end':time.time(),'rc':p.returncode})+'\n'+s)
print(json.dumps({'test':name,'rc':p.returncode,'tail':s[-1200:]}));sys.exit(p.returncode)
