#!/usr/bin/env python3
"""Synthetic resPQ over existing four WEB carriers, never a Telegram app.
Use only an operator-authorized host and root-only secret file. No client tokens,
full links, query capabilities or private headers are written to evidence.
Protocol: pinned official tproxy-server PROTOCOL.md; stdlib RFC6455 transport.
"""
import argparse,base64,hashlib,hmac,http.client,json,os,re,socket,ssl,struct,time
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes

def frame(t,s,p=b''):return bytes([t])+s.to_bytes(3,'big')+len(p).to_bytes(4,'big')+p

def main():
 p=argparse.ArgumentParser();p.add_argument('--hostname',required=True);p.add_argument('--secret-file',required=True)
 p.add_argument('--mode',choices=['https','https-lanes','websocket','websocket-lanes'],required=True)
 a=p.parse_args();secret_path=Path(a.secret_file)
 assert secret_path.stat().st_mode & 0o077==0,'secret file must be private'
 secret=bytes.fromhex(secret_path.read_text().strip());assert len(secret)==16
 ctx=ssl.create_default_context();start=time.time_ns();token=None;ws=None
 result={'kind':'SYNTHETIC_PUBLIC_HTTPS_WEB_TO_MTPROTO','actual_telegram_application':False,'hostname':a.hostname,'carrier':a.mode,'start_ns':start,'http':[],'frames':[]}
 def req(method,path,body=None,auth=None,extra=None):
  c=http.client.HTTPSConnection(a.hostname,443,timeout=30,context=ctx);headers={'Host':a.hostname}
  if auth:headers.update({'Origin':'https://'+a.hostname,'Authorization':'Bearer '+auth})
  if body is not None:headers['Content-Type']='application/octet-stream'
  if extra:headers.update(extra)
  try:
   c.request(method,path,body,headers);r=c.getresponse();data=r.read();hdr={k.lower():v for k,v in r.getheaders()};code=r.status
  finally:c.close()
  result['http'].append({'method':method,'path':path.split('?')[0],'status':code,'bytes':len(data)})
  assert code in [200,204],f'HTTP {code} at {path.split("?")[0]}'
  return data,hdr
 class WebSocket:
  def __init__(self,subprotocol):
   self.sock=ctx.wrap_socket(socket.create_connection((a.hostname,443),timeout=15),server_hostname=a.hostname);self.sock.settimeout(30);self.buf=b''
   key=base64.b64encode(os.urandom(16)).decode()
   request='GET /api/v1/ws HTTP/1.1\r\nHost: '+a.hostname+'\r\nOrigin: https://'+a.hostname+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Protocol: '+subprotocol+'\r\n\r\n'
   self.sock.sendall(request.encode())
   while b'\r\n\r\n' not in self.buf:
    b=self.sock.recv(4096);assert b,'EOF during WebSocket Upgrade';self.buf+=b;assert len(self.buf)<65536
   head,self.buf=self.buf.split(b'\r\n\r\n',1);lines=head.decode('iso8859-1').split('\r\n');assert lines[0].split()[1]=='101','Upgrade not101'
   headers={k.lower():v.strip() for k,v in (x.split(':',1) for x in lines[1:])}
   expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
   assert headers.get('sec-websocket-accept')==expected and headers.get('sec-websocket-protocol')==subprotocol
   result['websocket_upgrade']={'status':101,'accept_verified':True,'subprotocol_verified':True,'TLS_hostname_verified':True}
  def exact(self,n):
   while len(self.buf)<n:
    b=self.sock.recv(max(4096,n-len(self.buf)));assert b,'EOF in WebSocket';self.buf+=b
   b,self.buf=self.buf[:n],self.buf[n:];return b
  def send(self,data,opcode=2):
   mask=os.urandom(4);n=len(data);header=bytes([0x80|opcode])
   header+=bytes([0x80|n]) if n<126 else bytes([0x80|126])+n.to_bytes(2,'big') if n<65536 else bytes([0x80|127])+n.to_bytes(8,'big')
   self.sock.sendall(header+mask+bytes(v^mask[i%4] for i,v in enumerate(data)))
  def receive(self):
   message=b'';started=False
   while True:
    h=self.exact(2);fin=bool(h[0]&0x80);op=h[0]&15;assert not h[0]&0x70 and not h[1]&0x80
    n=h[1]&127
    if n==126:n=int.from_bytes(self.exact(2),'big')
    elif n==127:n=int.from_bytes(self.exact(8),'big')
    assert n<=1024*1024;data=self.exact(n)
    if op==9:self.send(data,10);continue
    if op==10:continue
    assert op!=8,'server closed WebSocket before reply'
    assert op in ([0] if started else [2]),'unexpected WebSocket opcode'
    started=True;message+=data;assert len(message)<=2*1024*1024
    if fin:return message
  def close(self):
   try:self.send(struct.pack('!H',1000),8)
   except OSError:pass
   self.sock.close()
 try:
  cap=base64.urlsafe_b64encode(hmac.new(secret,b'tdesktop-web-proxy-bridge-v1\n'+a.hostname.encode(),hashlib.sha256).digest()).decode().rstrip('=')
  body,hdr=req('GET','/?bridge='+cap);m=re.search(rb'bootstrap="([A-Za-z0-9_-]{43})"',body);assert m,'missing bootstrap';bootstrap=m.group(1).decode()
  body,hdr=req('POST','/api/v1/session',frame(0x10,0,b'\x01'),bootstrap);token=hdr.get('x-session-token');assert token and body==frame(0x11,0)
  header=bytearray(os.urandom(64));header[:4]=b'\x9a\x88\x71\x42';header[56:60]=b'\xef'*4;header[60:62]=struct.pack('<h',2)
  rev=bytes(header[8:56])[::-1];enc=Cipher(algorithms.AES(hashlib.sha256(header[8:40]+secret).digest()),modes.CTR(bytes(header[40:56]))).encryptor();dec=Cipher(algorithms.AES(hashlib.sha256(rev[:32]+secret).digest()),modes.CTR(rev[32:48])).decryptor()
  encrypted=enc.update(bytes(header));header[56:]=encrypted[56:]
  nonce=os.urandom(16);message=b'\0'*8+struct.pack('<Q',int(time.time())<<32)+struct.pack('<I',20)+struct.pack('<I',0xbe7e8ef1)+nonce
  raw=bytes(header)+enc.update(b'\x0a'+message);up=frame(1,1)+frame(2,1,raw)
  lane={'X-Lane-ID':'1'} if a.mode=='https-lanes' else {}
  if a.mode.startswith('websocket'):
   subprotocol=('tproxy-lane-v1.'+token+'.1') if a.mode=='websocket-lanes' else ('tproxy-v1.'+token)
   ws=WebSocket(subprotocol);ws.send(up)
  else:req('POST','/api/v1/up',up,token,{**lane,'X-Up-Seq':'1'})
  cursor='0';plain=b'';packet_size=None;offset=None
  for _ in range(6):
   if ws:data=ws.receive()
   else:
    data,hdr=req('POST','/api/v1/down',None,token,{**lane,'X-Down-Cursor':cursor});cursor=hdr.get('x-down-cursor',cursor)
   while data:
    assert len(data)>=8;typ=data[0];stream=int.from_bytes(data[1:4],'big');size=int.from_bytes(data[4:8],'big');assert size<=1024*1024 and len(data)>=8+size
    payload=data[8:8+size];data=data[8+size:]
    result['frames'].append({'type':typ,'stream':stream,'bytes':size})
    if typ==2 and stream==1:plain+=dec.update(payload)
    if typ==3 and stream==1:assert plain,'stream closed without Telegram response'
    if typ==5:
     pong=frame(6,0,payload)
     if ws:ws.send(pong)
     else:req('POST','/api/v1/up',pong,token,{'X-Up-Seq':'2',**({'X-Lane-ID':'0'} if a.mode=='https-lanes' else {})})
   if plain and (plain[0]!=127 or len(plain)>=4):
    offset=1 if plain[0]!=127 else 4;words=plain[0] if offset==1 else int.from_bytes(plain[1:4],'little')
    assert 1<=words<=262144;packet_size=words*4
    if len(plain)>=offset+packet_size:break
  assert plain and packet_size is not None and len(plain)>=offset+packet_size,'no complete Telegram response'
  body=plain[offset:offset+packet_size];assert len(body)>=40
  constructor=struct.unpack('<I',body[20:24])[0];matches=body[24:40]==nonce
  result.update(constructor=f'{constructor:08x}',nonce_matches=matches,response_bytes=len(body),TLS_verified=True)
  assert constructor==0x05162463 and matches,'not nonce-matched resPQ'
  result['status']='PASS'
 except Exception as e:result.update(status='FAIL',error=str(e))
 finally:
  if ws:ws.close()
  if token:
   try:req('DELETE','/api/v1/session',None,token)
   except Exception:pass
  result['end_ns']=time.time_ns();result['elapsed_ms']=(result['end_ns']-start)/1e6
  print(json.dumps(result,indent=2))
 return 0 if result['status']=='PASS' else 1
if __name__=='__main__':raise SystemExit(main())
