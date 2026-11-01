#!/usr/bin/env python3
"""Exact old installed CLI transaction rejects a new bare script with exact undo.

Disposable Ubuntu KVM only. HTTPS origins are injected after source; main CLI
dispatch and the unchanged installed v025 transaction execute. No component
cache may have been prepared; raw output is private.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading

assert os.geteuid()==0 and socket.gethostname()=='update01-final-entry'
assert Path('/etc/machine-id').read_bytes()==Path('/etc/twebproxy-disposable-lab').read_bytes()
candidate=Path(sys.argv[1]).read_bytes()
old=Path('/root/baseline25/twebproxy-manager.sh').read_bytes()
primary=Path('/usr/local/sbin/twebproxy');secondary=Path('/opt/twebproxy-manager/twebproxy-manager.sh')
assert primary.read_bytes()==secondary.read_bytes()==old
assert not Path('/opt/twebproxy-manager/distributions').exists(),'bare-script refusal must precede distribution preparation'
out=Path(sys.argv[2] if len(sys.argv)>2 else '/root/corrected-legacy-private');out.mkdir(mode=0o700)
cert,key=out/'cert.pem',out/'tls-key.pem'
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1','-keyout',str(key),'-out',str(cert)],check=True,capture_output=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/api/releases/latest':body=json.dumps({'tag_name':'v0.2.26','draft':False,'prerelease':False,
            'html_url':'https://github.com/Lazarev33/twebproxy-manager/releases/tag/v0.2.26'}).encode()
        elif self.path=='/raw/v0.2.26/twebproxy-manager.sh':body=candidate
        else:self.send_error(404);return
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key)
server.socket=ctx.wrap_socket(server.socket,server_side=True)
threading.Thread(target=server.serve_forever,daemon=True).start()
wrapper=out/'wrapper.sh'
wrapper.write_text('source /usr/local/sbin/twebproxy\nMANAGER_API_URL="$TEST_BASE/api"\nMANAGER_RAW_URL="$TEST_BASE/raw"\nmain manager-update "$@"\n')
env={**os.environ,'TEST_BASE':'https://127.0.0.1:'+str(server.server_port),'CURL_CA_BUNDLE':str(cert),
     'TWEBPROXY_UI_LANGUAGE':'ru','TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1','NO_COLOR':'1'}
try:
    before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in Path('/etc/twebproxy').rglob('*') if p.is_file()}
    p=subprocess.run(['bash',str(wrapper),'--sha256',hashlib.sha256(candidate).hexdigest()],capture_output=True,env=env,timeout=300)
    (out/'legacy-update.raw').write_bytes(p.stdout+p.stderr)
    assert p.returncode==1 and b'UPDATE_FAILED_ROLLBACK_SUCCESS' in p.stdout and b'UPDATE_SUCCESS' not in p.stdout
    assert b'pop_var_context' not in p.stdout+p.stderr
    assert primary.read_bytes()==secondary.read_bytes()==old
    after={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in Path('/etc/twebproxy').rglob('*') if p.is_file()}
    assert before==after,'configuration changed'
    q=subprocess.run([str(primary),'foreign-node','status'],capture_output=True,env=env,timeout=30)
    (out/'bridge-status.raw').write_bytes(q.stdout+q.stderr);assert q.returncode==0
    (out/'RESULTS.json').write_text(json.dumps({'status':'PASS','legacy_update_return_code':p.returncode,
        'outcome':'UPDATE_FAILED_ROLLBACK_SUCCESS','Bridge_status_after_undo':q.returncode,
        'old_manager_sha256':hashlib.sha256(old).hexdigest(),'bare_candidate_sha256':hashlib.sha256(candidate).hexdigest(),
        'prepared_components':False,'configuration_hashes_preserved':True,'public_TLS':False},indent=2)+'\n')
    print('LEGACY_BARE_SCRIPT_REFUSAL_EXACT_UNDO=PASS',flush=True)
finally:
    server.shutdown();server.server_close();key.unlink(missing_ok=True)
