#!/usr/bin/env python3
"""Actual loopback HTTPS/signatures; archive verification only, no host install."""
import argparse
import base64
import http.server
import importlib.util
import json
import os
from pathlib import Path
import ssl
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('download_engine',ROOT/'updater/engine.py')
mod=importlib.util.module_from_spec(spec);sys.modules[spec.name]=mod;spec.loader.exec_module(mod)


class Download(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='twp-dist-tls-');cls.root=Path(cls.temp.name)
        cls.source=cls.root/'source';cls.source.mkdir()
        names=[*json.loads((ROOT/'COMPONENTS.json').read_text()),'COMPONENTS.json','DISTRIBUTION.json','twebproxy-manager.sh']
        for name in names:
            target=cls.source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
        cls.package=cls.root/mod.ARTIFACT
        subprocess.run([sys.executable,str(ROOT/'tools/build-distribution.py'),'--root',str(cls.source),'--output',str(cls.package)],check=True,capture_output=True)
        cls.body=cls.package.read_bytes();cls.digest=mod.sha(cls.body)
        identity=json.loads((cls.source/'DISTRIBUTION.json').read_text())
        cls.version=identity['version'];cls.label=identity['release_version'];cls.tag='v'+cls.version
        cls.cert=cls.root/'cert.pem';cls.key=cls.root/'tls-key.pem'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1','-keyout',str(cls.key),'-out',str(cls.cert)],check=True,capture_output=True)
        cls.signing=cls.root/'signing.pem'
        subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(cls.signing)],check=True,capture_output=True)
        public=subprocess.check_output(['openssl','pkey','-in',str(cls.signing),'-pubout','-outform','DER'])
        cls.public=base64.b64encode(public).decode()
        outer=cls
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.requests.append(self.path)
                if self.path=='/api/releases/latest':body=json.dumps(outer.api).encode()
                elif self.path.endswith('/twebproxy-manager-release.json'):body=outer.manifest
                elif self.path.endswith('/twebproxy-manager-release.json.sig'):body=outer.signature
                elif self.path.endswith('/'+mod.ARTIFACT):
                    if outer.mode=='404':self.send_error(404);return
                    if outer.mode=='redirect-http':
                        self.send_response(302);self.send_header('Location','http://127.0.0.1:1/forbidden');self.end_headers();return
                    body=outer.body
                else:self.send_error(404);return
                self.send_response(200)
                self.send_header('Content-Length',str(len(body)+(1 if outer.mode=='truncated' and self.path.endswith(mod.ARTIFACT) else 0)))
                self.end_headers()
                try:self.wfile.write(body)
                except OSError:pass
            def log_message(self,*args):pass
        cls.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cls.cert,cls.key)
        cls.server.socket=ctx.wrap_socket(cls.server.socket,server_side=True)
        cls.base='https://127.0.0.1:'+str(cls.server.server_port)
        threading.Thread(target=cls.server.serve_forever,daemon=True).start()
        cls.old_ca=os.environ.get('CURL_CA_BUNDLE');os.environ['CURL_CA_BUNDLE']=str(cls.cert)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close()
        if cls.old_ca is None:os.environ.pop('CURL_CA_BUNDLE',None)
        else:os.environ['CURL_CA_BUNDLE']=cls.old_ca
        cls.temp.cleanup()

    def setUp(self):
        cls=type(self);cls.requests=[];cls.mode='normal'
        cls.api={'tag_name':self.tag,'draft':False,'prerelease':False}
        self.work=tempfile.TemporaryDirectory(prefix='case-',dir=self.root)
        self.args=argparse.Namespace(api_url=self.base+'/api',release_url=self.base,
                                     sha256=self.digest,trusted_key=[])
        self.manifest_obj={'format':'twebproxy.manager-distribution-release.v1',
            'repository':mod.REPOSITORY,'channel':'stable','version':self.version,
            'release_version':self.label,'tag':self.tag,'commit':'a'*40,
            'artifact':{'name':mod.ARTIFACT,'size':len(self.body),'sha256':self.digest}}
        self.sign()

    def tearDown(self):self.work.cleanup()

    def sign(self):
        cls=type(self);cls.manifest=mod.json_bytes(self.manifest_obj)
        path=Path(self.work.name)/'sign-input';sig=Path(self.work.name)/'sig.bin'
        path.write_bytes(cls.manifest)
        subprocess.run(['openssl','pkeyutl','-sign','-inkey',str(self.signing),'-rawin','-in',str(path),'-out',str(sig)],check=True,capture_output=True)
        cls.signature=base64.b64encode(sig.read_bytes())

    def fetch(self):
        archive,pin,version,label=mod.release_archive(self.args,Path(self.work.name))
        with tempfile.TemporaryDirectory(dir=self.work.name) as d:
            info,_=mod.extract_distribution(archive,pin,Path(d))
        self.assertEqual(info['version'],version)
        if label:self.assertEqual(info['label'],label)

    def test_independent_distribution_digest_authenticates_real_https_payload(self):self.fetch()

    def test_missing_trust_anchor_never_downloads_code(self):
        self.args.sha256=''
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'trust');self.assertFalse(any(p.endswith(mod.ARTIFACT) for p in self.requests))

    def test_wrong_digest_rejects_actual_download(self):
        self.args.sha256='0'*64
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'digest')

    def test_valid_pinned_ed25519_manifest(self):
        self.args.trusted_key=[self.public];self.args.sha256='';self.fetch()

    def test_invalid_signature_cannot_fall_back_to_good_operator_digest(self):
        self.args.trusted_key=[self.public];type(self).signature=base64.b64encode(b'x'*64)
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'signature')

    def test_wrong_signed_repository_refused(self):
        self.args.trusted_key=[self.public];self.manifest_obj['repository']='other/project';self.sign()
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'signature')

    def test_signed_digest_disagrees_with_operator_pin(self):
        self.args.trusted_key=[self.public];self.args.sha256='0'*64
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'digest')

    def test_404_download_is_failure(self):
        type(self).mode='404'
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'download')

    def test_truncated_transfer_is_failure(self):
        type(self).mode='truncated'
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'download')

    def test_redirect_cannot_downgrade_tls(self):
        type(self).mode='redirect-http'
        with self.assertRaises(mod.Fault) as e:self.fetch()
        self.assertEqual(e.exception.code,'download')

    def test_prerelease_is_not_automatic_stable_update(self):
        type(self).api['prerelease']=True
        with self.assertRaises(mod.Fault):self.fetch()

    def test_transfer_size_limit(self):
        with self.assertRaises(mod.Fault) as e:
            mod.download(self.base+'/releases/download/'+self.tag+'/'+mod.ARTIFACT,Path(self.work.name)/'bounded',128)
        self.assertEqual(e.exception.code,'download')


if __name__=='__main__':unittest.main(verbosity=2)
