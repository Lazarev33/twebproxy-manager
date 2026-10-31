#!/usr/bin/env python3
"""Synthetic HTTPS carrier + MTProto resPQ probe; NOT a Telegram application."""
import base64,hashlib,hmac,http.client,json,os,re,ssl,struct,time
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
start=time.monotonic_ns();result={'kind':'synthetic HTTPS carrier + obfuscated req_pq_multi','genuine_telegram_client':False,'http':[]};token=None
ctx=ssl.create_default_context()
def frame(t,s,p=b''):return bytes([t])+s.to_bytes(3,'big')+len(p).to_bytes(4,'big')+p
def req(method,path,body=None,auth=None,extra=None):
 c=http.client.HTTPSConnection('martins.ortositi.ru',443,timeout=30,context=ctx);headers={'Host':'martins.ortositi.ru'}
 if auth:headers.update({'Origin':'https://martins.ortositi.ru','Authorization':'Bearer '+auth})
 if body is not None:headers['Content-Type']='application/octet-stream'
 if extra:headers.update(extra)
 c.request(method,path,body,headers);r=c.getresponse();data=r.read();hdr=dict(r.getheaders());code=r.status;c.close();result['http'].append({'path':path.split('?')[0],'status':code,'bytes':len(data)})
 if code not in [200,204]:raise RuntimeError('unexpected HTTP '+str(code))
 return data,hdr
try:
 secret=bytes.fromhex(Path('/root/twp-gate3-private/client-secret').read_text().strip());cap=base64.urlsafe_b64encode(hmac.new(secret,b'tdesktop-web-proxy-bridge-v1\nmartins.ortositi.ru',hashlib.sha256).digest()).decode().rstrip('=')
 data,hdr=req('GET','/?bridge='+cap);bootstrap=re.search(rb'bootstrap="([A-Za-z0-9_-]{43})"',data).group(1).decode()
 data,hdr=req('POST','/api/v1/session',frame(0x10,0,b'\x01'),bootstrap);token=hdr.get('X-Session-Token');assert token and data==frame(0x11,0)
 header=bytearray(os.urandom(64));header[:4]=b'\x9a\x88\x71\x42';header[56:60]=b'\xef'*4;header[60:62]=struct.pack('<h',2)
 rev=bytes(header[8:56])[::-1];enc=Cipher(algorithms.AES(hashlib.sha256(header[8:40]+secret).digest()),modes.CTR(bytes(header[40:56]))).encryptor();dec=Cipher(algorithms.AES(hashlib.sha256(rev[:32]+secret).digest()),modes.CTR(rev[32:48])).decryptor()
 encrypted=enc.update(bytes(header));header[56:]=encrypted[56:]
 nonce=os.urandom(16);msg=b'\0'*8+struct.pack('<Q',int(time.time())<<32)+struct.pack('<I',20)+struct.pack('<I',0xbe7e8ef1)+nonce
 raw=bytes(header)+enc.update(b'\x0a'+msg)
 req('POST','/api/v1/up',frame(1,1)+frame(2,1,raw),token,{'X-Up-Seq':'1'})
 cursor='0';ciphertext=b''
 for attempt in range(4):
  data,hdr=req('POST','/api/v1/down',None,token,{'X-Down-Cursor':cursor});cursor=hdr.get('X-Down-Cursor',cursor)
  while data:
   typ=data[0];stream=int.from_bytes(data[1:4],'big');size=int.from_bytes(data[4:8],'big');payload=data[8:8+size];data=data[8+size:]
   if typ==2 and stream==1:ciphertext+=payload
   if typ==3 and stream==1:result['stream_close']=True
  if ciphertext:break
 plain=dec.update(ciphertext);assert plain, 'no Telegram response';offset=1 if plain[0]!=127 else 4;body=plain[offset:];constructor=struct.unpack('<I',body[20:24])[0];matches=body[24:40]==nonce
 result.update({'constructor':f'{constructor:08x}','nonce_matches':matches,'response_bytes':len(body),'tls_verified':True,'tls_trust':'public CA trust store; hostname verification; no TLS override'})
 assert constructor==0x05162463 and matches,'not nonce-matched resPQ';result['status']='PASS'
except Exception as e:result.update({'status':'FAIL','error':str(e)})
finally:
 if token:
  try:req('DELETE','/api/v1/session',None,token)
  except Exception:pass
 result['elapsed_ms']=(time.monotonic_ns()-start)/1e6
 print(json.dumps(result,indent=2))
