"""Filesystem/process tests plus real Linux loopback listeners; no live nodes.
Environment/renderer doubles are explicit. No firewall/systemd mutation is run.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
ENV={**os.environ,'PYTHONDONTWRITEBYTECODE':'1','TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1'}

class Shell(unittest.TestCase):
 def run_shell(self,script,stdin='',lang='ru'):
  with tempfile.TemporaryDirectory() as d:
   p=subprocess.run(['bash','-c','source "$1"; disable_colors; BASE_DIR="$2/etc"; INSTANCES_DIR="$BASE_DIR/instances"; BACKENDS_DIR="$BASE_DIR/backends"; '+script,'_',str(ROOT/'twebproxy-manager.sh'),d],input=stdin,text=True,capture_output=True,env={**ENV,'TWEBPROXY_UI_LANGUAGE':lang},timeout=25)
   return p
 def test_real_socket_conflict_and_reselection(self):
  with socket.socket() as sock:
   for port in range(24170,24200):
    try:sock.bind(('127.0.0.1',port));break
    except OSError:continue
   else:self.fail('No free loopback test port')
   sock.listen()
   p=self.run_shell(f'rc=0; port_available {port} || rc=$?; printf "occupied=%s\\n" "$rc"; preferred_free_port {port} {port} {port+10}')
   self.assertEqual(p.returncode,0,p.stderr);self.assertIn('occupied=1',p.stdout);self.assertNotEqual(p.stdout.splitlines()[-1],str(port))
 def test_valid_automatic_proposal_is_reused(self):
  p=self.run_shell('port_available(){ return 0; }; next_free_port(){ return 99; }; preferred_free_port 24500 23980 26999')
  self.assertEqual((p.returncode,p.stdout),(0,'24500'))
 def test_unknown_ports_never_assumed_free(self):
  p=self.run_shell('trap - ERR; port_available(){ return 2; }; preferred_free_port 24500 23980 26999')
  self.assertEqual(p.returncode,2)
 def test_actual_registry_reservation_is_honored(self):
  p=self.run_shell('mkdir -p "$BACKENDS_DIR"; printf "MTPROXY_CLIENT_PORT=24500\\nMTPROXY_STATS_PORT=29500\\n" > "$BACKENDS_DIR/fixture.env"; rc=0; port_available 24500 || rc=$?; printf "%s" "$rc"')
  self.assertEqual((p.returncode,p.stdout),(0,'1'))
 def test_auto_profile_unique_secret_and_defaults(self):
  p=self.run_shell('port_available(){ return 0; }; collect_profile_settings example.invalid default quick; first="$SECRET"; collect_profile_settings example.invalid default quick; [[ "$SECRET" =~ ^[0-9a-f]{32}$ && "$SECRET" != "$first" ]]; printf "%s/%s/%s/%s/%s" "$PROFILE_NAME" "$CARRIER_MODE" "$WORKERS" "$MAX_CONNECTIONS" "$PROFILE_PORTS_AUTO"')
  self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout,'default/https/1/4096/1')
 def test_singletons_do_not_consume_input(self):
  p=self.run_shell('list_hosts_array(){ printf "one.invalid\\n"; }; list_profiles_array(){ printf "default\\n"; }; printf "%s/%s" "$(select_instance)" "$(select_profile one.invalid)"')
  self.assertEqual(p.stdout,'one.invalid/default');self.assertEqual(p.returncode,0)
 def test_multiple_instances_and_profiles_are_numbered(self):
  p=self.run_shell('list_hosts_array(){ printf "one.invalid\\ntwo.invalid\\n"; }; list_profiles_array(){ printf "default\\nprivate\\n"; }; h="$(select_instance)"; q="$(select_profile "$h")"; printf "RESULT=%s/%s" "$h" "$q"', '2\n2\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('RESULT=two.invalid/private',p.stdout)
 def test_unterminated_approval_at_eof_is_refused(self):
  for text in ('y','да'):
   p=self.run_shell('if yesno approval n; then printf UNSAFE; else printf CANCELLED; fi',text)
   self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('UNSAFE',p.stdout)
   p=self.run_shell('rc=0; stage4_confirm_restore approval || rc=$?; printf "rc=%s" "$rc"',text)
   self.assertEqual(p.returncode,0,p.stderr);self.assertIn('rc=130',p.stdout)
 def test_eof_never_selects_a_default(self):
  p=self.run_shell('choose question first second')
  self.assertEqual(p.returncode,130)
 def test_empty_or_eof_never_approves_change(self):
  for data in ['','\n','n\n']:
   p=self.run_shell('if yesno "$(ui_msg smart_apply)" n; then printf UNSAFE; else printf CANCELLED; fi',data)
   self.assertEqual(p.stdout,'CANCELLED')
 def test_next_profile_skips_existing_and_orphan_files(self):
  p=self.run_shell('mkdir -p "$INSTANCES_DIR/one.invalid/profiles.d" "$BACKENDS_DIR"; touch "$INSTANCES_DIR/one.invalid/profiles.d/profile1.env" "$BACKENDS_DIR/one.invalid--profile2.env"; backend_id_used_by_other(){ return 1; }; next_profile_name one.invalid')
  self.assertEqual((p.returncode,p.stdout),(0,'profile3'))
 def test_context_bridge_state_is_fail_closed_and_read_only(self):
  for content,expected in [('','pending'),('{"schema":1,"phase":"active"}','active'),('{"schema":1,"phase":"cleanup_pending"}','pending'),('bad-json','pending')]:
   # Use stdin for arbitrary fixture bytes instead of interpolating shell content.
   p=self.run_shell('mkdir -p "$BASE_DIR/bridge"; cat > "$BASE_DIR/bridge/node.json"; before="$(sha256sum "$BASE_DIR/bridge/node.json")"; bridge_menu_state; [[ "$before" == "$(sha256sum "$BASE_DIR/bridge/node.json")" ]]',content)
   self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout.strip(),expected)
 def test_broken_bridge_marker_blocks_add(self):
  p=self.run_shell('mkdir -p "$BASE_DIR/bridge"; ln -s missing "$BASE_DIR/bridge/node.json"; bridge_menu_state')
  self.assertEqual(p.stdout.strip(),'pending')
 def test_all_six_dpi_modes_remain_valid(self):
  p=self.run_shell('for m in stock window1152 mss88 nfqws window1152_nfqws mss88_nfqws; do dpi_mode_valid "$m" || exit 90; done')
  self.assertEqual(p.returncode,0,p.stderr)
 def test_stock_refusal_and_eof_do_not_mutate(self):
  for data in ['','\n','n\n']:
   p=self.run_shell('DPI_STATE_DIR="$BASE_DIR/dpi"; tui_run(){ printf UNSAFE; }; dpi_tui_apply one.invalid stock',data)
   self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('UNSAFE',p.stdout)
 def test_guided_dpi_keep_does_not_probe_or_mutate(self):
  p=self.run_shell('tui_run(){ printf UNSAFE; }; select_instance(){ printf UNSAFE; }; menu_dpi_guided','1\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('UNSAFE',p.stdout)
 def test_zero_cancels_preset_without_selection(self):
  p=self.run_shell('tui_preset_choose question first second','0\n')
  self.assertEqual(p.returncode,130)
 def test_ufw_needs_explicit_tui_approval(self):
  p=self.run_shell('TUI_ACTIVE=1; ufw(){ if [[ "$1" == status ]]; then printf "Status: active\\n"; else printf UNSAFE; fi; }; configure_ufw','\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('UNSAFE',p.stdout)
 def test_locale_catalog_is_complete_for_smart_messages(self):
  p=self.run_shell('ui_i18n_init; for k in "${!UI_EN[@]}"; do [[ "$k" != smart_* || -n "${UI_RU[$k]:-}" ]] || exit 91; done; UI_LANGUAGE=en; ui_msg smart_quick; UI_LANGUAGE=ru; ui_msg smart_quick')
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('Standard setup',p.stdout);self.assertIn('Стандартная',p.stdout)

 def test_cli_collector_keeps_existing_prompt_contract(self):
  p=self.run_shell('collect_instance_settings; printf "RESULT=%s/%s/%s" "$HOSTNAME" "$SITE_MODE" "$TLS_MODE"','legacy.invalid\n1\n1\n4\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('RESULT=legacy.invalid/default/manual',p.stdout)
 def test_context_menu_hides_add_for_existing_or_pending_node(self):
  for phase in ['active','cleanup_pending']:
   payload=json.dumps({'schema':1,'phase':phase})
   script="mkdir -p \"$BASE_DIR/bridge\"; printf '%s' '"+payload+"' > \"$BASE_DIR/bridge/node.json\"; menu_foreign_nodes"
   p=self.run_shell(script,'0\n')
   self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('Добавить зарубежный узел',p.stdout+p.stderr)
 def test_dpi_presets_never_take_raw_packet_parameters(self):
  for choice,mode in [(1,'window1152'),(2,'mss88'),(3,'nfqws'),(4,'window1152_nfqws'),(5,'mss88_nfqws'),(6,'stock')]:
   p=self.run_shell('dpi_list_methods_cmd(){ :; }; select_instance(){ printf one.invalid; }; dpi_tui_apply(){ printf "APPLY=%s/%s" "$1" "$2"; }; menu_dpi_advanced',str(choice)+'\n')
   self.assertEqual(p.returncode,0,p.stderr);self.assertIn('APPLY=one.invalid/'+mode,p.stdout)
 def test_diagnostics_remembers_host_until_explicitly_changed(self):
  p=self.run_shell('select_instance(){ printf "SELECT\n" >> "$BASE_DIR-count"; printf one.invalid; }; tui_run(){ printf "%s\n" "$*"; }; menu_diagnostics; printf "SELECTIONS=%s" "$(wc -l < "$BASE_DIR-count")"','1\n\n2\n\n0\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('SELECTIONS=1',p.stdout)

class PythonBridge(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  sys.path.insert(0,str(ROOT/'bridge'));spec=importlib.util.spec_from_file_location('smart_controller',ROOT/'bridge/controller.py');cls.c=importlib.util.module_from_spec(spec)
  with mock.patch.dict(sys.modules,{'paramiko':mock.Mock(name='inert_paramiko')}):spec.loader.exec_module(cls.c)
 def test_bridge_human_plan_is_localized_and_omits_credentials(self):
  c=self.c;remote={'version':'24.04','services':'ssh.service loaded active running SSH\ncron.service loaded active running Cron\n','password':'DO_NOT_DISPLAY'}
  with mock.patch.object(c,'INTERACTIVE',True),mock.patch.object(c,'LANG','ru'),mock.patch('sys.stdout',new=io.StringIO()) as stream:
   c.show_plan('one.invalid','default',{'version':'24.04'},remote,'digest')
   text=stream.getvalue()
  self.assertIn('План установки',text);self.assertIn('Запущенных служб зарубежного узла: 2',text);self.assertNotIn('DO_NOT_DISPLAY',text)
 def test_bridge_cli_plan_keeps_legacy_json_fields(self):
  c=self.c
  with mock.patch.object(c,'INTERACTIVE',False),mock.patch('sys.stdout',new=io.StringIO()) as stream:
   c.show_plan('one.invalid','default',{'version':'24.04'},{'version':'24.04','services':'ssh.service\n'},'digest')
   data=json.loads(stream.getvalue())
  self.assertEqual(data['existing_remote_services'],'ssh.service\n');self.assertEqual(data['plan']['hostname'],'one.invalid');self.assertEqual(data['plan']['executor_sha256'],'digest')
 def test_numeric_choices_reject_invalid_and_eof(self):
  c=self.c
  with mock.patch('builtins.input',side_effect=['99','bad','2']),mock.patch('sys.stdout',new=io.StringIO()):self.assertEqual(c.select('choose',['one','two']),2)
  with mock.patch('builtins.input',side_effect=EOFError),mock.patch('sys.stdout',new=io.StringIO()):
   with self.assertRaises(EOFError):c.select('choose',['one'])
 def test_zero_cancels_python_preset(self):
  with mock.patch('builtins.input',return_value='0'),mock.patch('sys.stdout',new=io.StringIO()):
   with self.assertRaises(KeyboardInterrupt):self.c.select('choose',['one','two'])
 def test_empty_password_rejected_before_authentication(self):
  c=self.c;s=c.SSH.__new__(c.SSH);s.t=mock.Mock()
  with self.assertRaises(c.Fault):s.auth('root',password='')
  s.t.auth_password.assert_not_called()
 def test_host_identity_mismatch_prevents_authentication(self):
  c=self.c;transport=mock.Mock();transport.get_security_options.return_value.kex=['curve25519-sha256@libssh.org'];transport.get_remote_server_key.return_value.asbytes.return_value=b'fixture host public key'
  with mock.patch.object(c.socket,'create_connection',return_value=mock.Mock()),mock.patch.object(c.paramiko,'Transport',return_value=transport):
   with self.assertRaises(c.Fault):c.SSH('127.0.0.1',22,expected='SHA256:WRONG')
  transport.auth_password.assert_not_called();transport.auth_publickey.assert_not_called()
 def test_existing_node_still_refused_without_state_change(self):
  c=self.c
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'node.json';p.write_text('{"phase":"cleanup_pending"}');before=p.read_bytes()
   with mock.patch.object(c,'STATE',p),mock.patch.object(c,'choose_instance') as choose:
    with self.assertRaises(c.Fault):c.add(None)
    choose.assert_not_called()
   self.assertEqual(p.read_bytes(),before)


class ProcessBoundary(unittest.TestCase):
 def run_fixture(self, action, data='', extra='', family='', listeners='', dns='1', existing=False):
  with tempfile.TemporaryDirectory() as d:
   f=Path(d);manager=f/'manager.sh'
   import shutil
   shutil.copytree(ROOT/'sites',f/'sites')
   (f/'listeners').write_text(listeners)
   (f/'unrelated').write_text('operator data')
   if existing:(f/'core-marker').write_text('existing core')
   overrides=r"""
BASE_DIR="$UX_FIXTURE/etc"; INSTANCES_DIR="$BASE_DIR/instances"; BACKENDS_DIR="$BASE_DIR/backends"; SITES_DIR="$UX_FIXTURE/web"
need_root(){ :; }; need_systemd(){ :; }; check_platform(){ :; }; banner(){ :; }
core_installed(){ [[ -e "$UX_FIXTURE/core-marker" ]]; }
core_install_cmd(){ printf CORE_CALLED >> "$UX_FIXTURE/core-called"; return 76; }
managed_frontend_family(){ printf '%s' "$UX_FAMILY"; }
list_hosts_array(){ [[ -z "$UX_FAMILY" ]] || printf 'old.invalid\n'; }
load_instance(){ TLS_MODE="$UX_FAMILY"; [[ "$TLS_MODE" != nginx ]] || TLS_MODE=nginx-le; ACME_EMAIL=owner@example.invalid; }
ss(){ if [[ "$*" == *-ltnp* ]]; then cat "$UX_FIXTURE/listeners"; fi; }
smart_dns_ready(){ [[ "$UX_DNS" == 1 ]]; }
repair_instance_cmd(){ printf STARTED; false; printf STRICT_MODE_BYPASSED; }
status_cmd(){ printf '{"schema":"fixture.status.v1"}\n'; return 7; }
"""+extra+'\n'
   source=(ROOT/'twebproxy-manager.sh').read_text();anchor='if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then'
   before,sep,after=source.rpartition(anchor)
   self.assertTrue(sep)
   manager.write_text(before+overrides+'\n'+sep+after)
   env={**ENV,'UX_FIXTURE':d,'UX_FAMILY':family,'UX_DNS':dns,'TWEBPROXY_UI_LANGUAGE':'ru'}
   if action.startswith('CLI:'):
    cmd=['bash',str(manager),*action[4:].split()]
   else:cmd=['bash','-c','source "$1"; UI_LANGUAGE=ru; disable_colors; tui_run '+action+'; printf "\nPARENT_ALIVE\n"','_',str(manager)]
   r=subprocess.run(cmd,input=data,text=True,capture_output=True,env=env,timeout=25)
   return r,{'core_called':(f/'core-called').exists(),'unrelated':(f/'unrelated').read_text(),'instance_files':list((f/'etc').rglob('*')) if (f/'etc').exists() else []}
 def test_child_failure_keeps_errexit_and_parent_menu_alive(self):
  p,state=self.run_fixture('repair example.invalid','y\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('STARTED',p.stdout);self.assertNotIn('STRICT_MODE_BYPASSED',p.stdout)
  self.assertIn('PARENT_ALIVE',p.stdout);self.assertIn('код 1',p.stderr)
 def test_service_restart_decline_or_eof_is_safe(self):
  for value in ['','\n','n\n']:
   p,state=self.run_fixture('repair example.invalid',value)
   self.assertNotIn('STARTED',p.stdout);self.assertFalse(state['core_called']);self.assertIn('PARENT_ALIVE',p.stdout)
 def test_quick_preview_never_contains_generated_secret(self):
  secret='11223344556677889900aabbccddeeff'
  p,state=self.run_fixture('quick-add','new.invalid\nn\n',extra='openssl(){ printf '+secret+'; }')
  self.assertNotIn(secret,p.stdout+p.stderr);self.assertFalse(state['core_called'])
 def test_fresh_quick_only_domain_then_explicit_approval(self):
  p,state=self.run_fixture('quick-add','new.invalid\nn\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn('new.invalid',p.stdout);self.assertIn('caddy',p.stdout)
  self.assertIn('default',p.stdout);self.assertIn('STOCK',p.stdout);self.assertFalse(state['core_called']);self.assertEqual(state['instance_files'],[])
  self.assertNotIn('Сгенерировать новый',p.stdout+p.stderr);self.assertNotIn('Путь к каталогу',p.stdout+p.stderr)
 def test_existing_frontend_is_reused_without_extra_questions(self):
  for family in ['caddy','nginx']:
   p,state=self.run_fixture('quick-add','new.invalid\nn\n',family=family,existing=True)
   self.assertEqual(p.returncode,0,p.stderr);self.assertIn(family,p.stdout);self.assertFalse(state['core_called']);self.assertEqual(state['unrelated'],'operator data')
 def test_approved_fresh_setup_attempts_core_only_after_plan(self):
  p,state=self.run_fixture('quick-add','new.invalid\ny\n')
  self.assertTrue(state['core_called']);self.assertIn('код 76',p.stderr);self.assertEqual(state['instance_files'],[])
 def test_unknown_listener_is_not_adopted(self):
  p,state=self.run_fixture('quick-add','new.invalid\ny\n',listeners='LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("other",pid=1,fd=3))\n')
  self.assertFalse(state['core_called']);self.assertEqual(state['instance_files'],[]);self.assertIn('Стандартный TLS нельзя',p.stderr)
 def test_dns_failure_is_actionable_and_does_not_install(self):
  p,state=self.run_fixture('quick-add','new.invalid\ny\n',dns='0')
  self.assertFalse(state['core_called']);self.assertIn('Принадлежность DNS',p.stderr)
 def test_cli_nonzero_and_json_are_not_rewritten(self):
  p,state=self.run_fixture('CLI:status example.invalid --json')
  self.assertEqual(p.returncode,7);self.assertEqual(json.loads(p.stdout),{'schema':'fixture.status.v1'})
 def test_readonly_tui_nonzero_remains_visible(self):
  p,state=self.run_fixture('status example.invalid --json')
  self.assertEqual(p.returncode,0);self.assertIn('"schema":"fixture.status.v1"',p.stdout);self.assertIn('код 7',p.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
