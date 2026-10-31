"""Focused MODEL tests: fault injection at HTTP/filesystem boundary, no host services."""
import os,subprocess,tempfile,unittest,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class Refresh(unittest.TestCase):
 def run_case(self,script):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);data=root/'data';data.mkdir();(data/'proxy-secret').write_bytes(b'A'*128);(data/'proxy-multi.conf').write_text('old-config\n')
   p=subprocess.run(['bash','-c','source "$1"; trap - ERR; export MTPROXY_DATA_DIR="$2"; log(){ :; }; '+script,'_',str(ROOT/'twebproxy-manager.sh'),str(data)],env={**os.environ,'TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1'},text=True,capture_output=True)
   return p,{n:(data/n).read_bytes() for n in ['proxy-secret','proxy-multi.conf']}
 def test_failed_second_download_preserves_pair(self):
  p,data=self.run_case('download_telegram_material(){ if [[ "$1" == *Secret ]]; then head -c 128 /dev/zero > "$2"; else return 28; fi; }; refresh_mtproxy_material')
  self.assertEqual(p.returncode,1);self.assertEqual(data['proxy-secret'],b'A'*128);self.assertEqual(data['proxy-multi.conf'],b'old-config\n')
 def test_html_response_preserves_pair(self):
  p,data=self.run_case('download_telegram_material(){ head -c 128 /dev/zero > "$2"; }; refresh_mtproxy_material')
  self.assertNotEqual(p.returncode,0);self.assertEqual(data['proxy-secret'],b'A'*128);self.assertEqual(data['proxy-multi.conf'],b'old-config\n')
 def test_second_publish_failure_restores_first(self):
  p,data=self.run_case('download_telegram_material(){ if [[ "$1" == *Secret ]]; then head -c 128 /dev/zero > "$2"; else printf "default 2;\\nproxy_for 2 149.154.167.50:8888;\\n%0100d\\n" 0 > "$2"; fi; }; mv(){ if [[ "${@: -2:1}" == */config ]]; then return 1; else command mv "$@"; fi; }; refresh_mtproxy_material')
  self.assertEqual(p.returncode,1);self.assertEqual(data['proxy-secret'],b'A'*128);self.assertEqual(data['proxy-multi.conf'],b'old-config\n')
 def test_bounded_authenticated_download_policy(self):
  p,_=self.run_case('curl(){ printf "%s\\n" "$@"; }; download_telegram_material https://core.telegram.org/getProxyConfig /tmp/out')
  self.assertEqual(p.returncode,0)
  for arg in ['-4','--retry-all-errors','--retry-max-time','--connect-timeout','--max-time',"=https"]:self.assertIn(arg,p.stdout)
  self.assertNotIn('--insecure',p.stdout)
if __name__=='__main__':unittest.main(verbosity=2)
