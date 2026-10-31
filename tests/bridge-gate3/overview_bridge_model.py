"""MODEL reproduction: old dashboard checked a stopped local backend for a Bridge."""
import subprocess,tempfile,json,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as d:
 baseline=Path(d)/'gate2.sh';baseline.write_bytes(subprocess.check_output(['git','show','3375c4a9d5057bab453ce3fdc41b688a06b6ab77:twebproxy-manager.sh'],cwd=ROOT))
 results={}
 code='''source "$1"; trap - ERR
list_hosts_array(){ echo example.invalid; }; count_profiles(){ echo 1; }
list_profiles_array(){ echo default; }; load_instance(){ TLS_MODE=caddy; }
load_profile(){ CARRIER_MODE=https; }; dpi_collect_host_check(){ :; }
bridge_managed(){ return 0; }; bridge_forward_unit(){ echo twb-aaaaaaaaaaaa-forward.service; }
diag_unit_state(){ case "$1" in twebproxy-mtproxy@*) echo inactive;; *) echo active;; esac; }
collect_overview; tcore_render_json
'''
 for name,path in [('gate2',baseline),('gate3',ROOT/'twebproxy-manager.sh')]:
  p=subprocess.run(['bash','-c',code,'_',str(path)],env={**os.environ,'TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1'},text=True,capture_output=True);assert p.returncode==0,p.stderr
  data=json.loads(p.stdout);check=next(x for x in data['checks'] if x['id']=='profile.backend.service.active');results[name]={'profile_backend_service_check':check,'rc':p.returncode}
 assert results['gate2']['profile_backend_service_check']['status']=='ERROR'
 assert results['gate3']['profile_backend_service_check']['status']=='OK'
 print(json.dumps({'kind':'MODEL','assertion':'old local backend inactive, real bridge forwarder active','results':results,'status':'PASS'},indent=2))
