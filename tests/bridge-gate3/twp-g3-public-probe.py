import socket,time,json
from pathlib import Path
stop=Path('/root/twp-gate3-stop-public-probe')
with Path('/root/twp-gate3-public-probes.jsonl').open('a',buffering=1) as f:
 while not stop.exists():
  for port in (24990,29990,443):
   at=time.time()
   try:
    with socket.create_connection(('95.85.251.163',port),timeout=.35):ok=True
   except OSError:ok=False
   f.write(json.dumps({'at':at,'host':'95.85.251.163','port':port,'open':ok})+'\n')
  time.sleep(.15)
