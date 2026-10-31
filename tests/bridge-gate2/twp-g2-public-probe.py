import socket,time,json
from pathlib import Path
out=Path('/root/twp-gate2-public-probes.jsonl')
with out.open('a',buffering=1) as f:
 while not Path('/root/twp-gate2-stop-probe').exists():
  for port in (24990,29990,443):
   start=time.time()
   try:
    with socket.create_connection(('95.85.251.163',port),timeout=.4):opened=True
   except OSError:opened=False
   f.write(json.dumps({'at':start,'peer':'95.85.251.163','port':port,'open':opened})+'\n')
  time.sleep(.1)
