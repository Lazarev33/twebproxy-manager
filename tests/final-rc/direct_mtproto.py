#!/usr/bin/env python3
"""Synthetic nonce-matched MTProto probe on disposable Entry, not Telegram app."""
import argparse,hashlib,json,os,socket,struct,subprocess,time
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
assert Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()
a=argparse.ArgumentParser();a.add_argument('--target',choices=['peer','forward'],required=True);a.add_argument('--wrong',action='store_true');a=a.parse_args()
s=json.loads(Path('/etc/twebproxy/bridge/node.json').read_text());c=s['entry']
x=subprocess.check_output(['/usr/local/sbin/twebproxy','bridge-internal','credential',s['hostname'],s['profile']],text=True)
t=json.loads(x)['secret'];t=t[2:] if t.startswith('dd') and len(t)==34 else t;secret=bytearray.fromhex(t)
if a.wrong:secret[0]^=1
r={'kind':'SYNTHETIC_REAL_KVM_TCP','target':a.target,'genuine_client':False,'wrong_secret':a.wrong};start=time.time_ns()
try:
 h=bytearray(os.urandom(64));h[:4]=b'\x9a\x88\x71\x42';h[56:60]=b'\xef'*4;h[60:62]=struct.pack('<h',2)
 rev=bytes(h[8:56])[::-1];enc=Cipher(algorithms.AES(hashlib.sha256(h[8:40]+secret).digest()),modes.CTR(bytes(h[40:56]))).encryptor();dec=Cipher(algorithms.AES(hashlib.sha256(rev[:32]+secret).digest()),modes.CTR(rev[32:48])).decryptor()
 encrypted=enc.update(bytes(h));h[56:]=encrypted[56:]
 nonce=os.urandom(16);msg=b'\0'*8+struct.pack('<Q',int(time.time())<<32)+struct.pack('<I',20)+struct.pack('<I',0xbe7e8ef1)+nonce
 addr=(c['peer_ip'],c['client_port']) if a.target=='peer' else ('127.0.0.1',c['local_port'])
 with socket.create_connection(addr,timeout=5) as connection:
  connection.settimeout(15);connection.sendall(bytes(h)+enc.update(b'\x0a'+msg))
  def read(n):
   out=b''
   while len(out)<n:
    b=connection.recv(n-len(out));assert b,'EOF from MTProxy';out+=b
   return dec.update(out)
  length=read(1)[0];n=length if length!=127 else int.from_bytes(read(3),'little');assert 1<=n<=65536
  b=read(n*4);constructor=struct.unpack('<I',b[20:24])[0];matches=b[24:40]==nonce
  r.update(constructor=f'{constructor:08x}',nonce_matches=matches,response_bytes=len(b))
  assert constructor==0x05162463 and matches,'not nonce-matched resPQ'
 r['status']='FAIL' if a.wrong else 'PASS'
except Exception as e:r.update(status='PASS' if a.wrong else 'FAIL',error=str(e))
r['elapsed_ms']=(time.time_ns()-start)/1e6;print(json.dumps(r));raise SystemExit(0 if r['status']=='PASS' else 1)
