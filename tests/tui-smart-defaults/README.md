# Focused UX tests

Run from the complete candidate distribution on a Linux development host:

```sh
export PYTHONDONTWRITEBYTECODE=1
bash -n twebproxy-manager.sh
shellcheck --severity=error twebproxy-manager.sh
python3 tests/tui-smart-defaults/test_corrections.py
bash tests/localization-static-audit.sh
python3 tests/tui-smart-defaults/test_smart_defaults.py
python3 tests/bridge-gate3/test_bridge_menu.py
python3 tests/bridge-gate2/test_safety.py
python3 tests/bridge-gate3/test_default_site.py
bash tests/read-only-core-fixture.sh
bash tests/localization-flow-fixture.sh
bash tests/stagec1/state-persistence-fixture.sh
bash tests/stagec1/port-allocation-fixture.sh
```

These use temporary files, explicit command doubles and real loopback socket
listeners. They do not modify live systemd/firewall/proxy state. Process-boundary
tests launch a fresh child Bash; their injected environment is not a deployment.
40 UX, 13 Bridge menu, 8 bundle-safety and 7 default-site unittest cases are
separate from 54 persistence and 26 allocation fixture assertions.

## Actual isolated Linux integration

Use a newly created disposable Ubuntu 24.04 x86_64 guest with systemd, full
network capabilities, outbound official dependency access, and an operator-pinned
SSH host key. Never run these steps on the Entry/Exit or an unrelated host.
The test guest used 768 MiB RAM, one vCPU and a clean overlay of the GPG-verified
official cloud image. No host reboot or existing-host wipe was used.

Transfer the full source, without credentials, to `/root/ux-source`. In the guest:

```sh
test "$(hostname)" = tui-smart-lab || exit 1
test "$(cat /proc/1/comm)" = systemd || exit 1
test ! -e /etc/twebproxy || exit 1
nft list tables
export GOMAXPROCS=1 GOFLAGS=-p=1
# Advanced: manual external TLS avoids pretending the .invalid name has TLS.
printf 'smart-ui.invalid\ny\n1\n4\n\ny\n1\ny\n1\ny\n' |
  bash /root/ux-source/twebproxy-manager.sh tui-internal advanced-add
```

Capture raw output only in a root-private location: successful creation prints
private links by design. Sanitize before copying evidence. Dependencies must be
downloaded and verified normally; do not substitute prepared executables.

After copying a newer candidate into this disposable guest only, install the
normal Manager copy, then exercise the actual installed main menu:

```sh
test "$(hostname)" = tui-smart-lab || exit 1
TWEBPROXY_NO_LOG=1 bash -c 'source /root/ux-source/twebproxy-manager.sh; install_manager_copy'
printf '4\n1\n1\ny\n\n0\n0\n' | /usr/local/sbin/twebproxy menu
printf '<!-- operator edit -->\n' >> /srv/twebproxy/smart-ui.invalid/index.html
sha256sum /srv/twebproxy/smart-ui.invalid/index.html
printf 'y\n' | twebproxy tui-internal repair smart-ui.invalid
sha256sum /srv/twebproxy/smart-ui.invalid/index.html
printf '1\nn\n' | twebproxy tui-internal profile-rotate smart-ui.invalid profile1
printf 'n\n' | twebproxy tui-internal profile-delete smart-ui.invalid profile1
twebproxy status smart-ui.invalid --json
twebproxy foreign-node status
# Destructive cleanup applies ONLY to the named disposable guest.
printf 'y\n' | twebproxy tui-internal delete smart-ui.invalid
printf 'y\n' | twebproxy tui-internal core-uninstall
systemctl is-active ssh
test ! -d /etc/twebproxy
```

Record return codes and canonical profile/site hashes before and after refusals.
Real SSH identity/key tests additionally use a temporary key generated INSIDE the
guest and the controller SSH class against its own actual sshd; they do not
constitute new remote-node provisioning. Never export the private key.

For pristine negative Quick scenarios, use another fresh overlay (`tui-smart-clean`)
and `fresh-quick-negative.sh`. Do not overlap with installation in the same guest.
No positive public DNS/TLS Quick result is claimed from an `.invalid` hostname.
Old harness attempts retained as excluded evidence are not passing product tests.

## Reproducibility without global Paramiko

The controller-only unit/menu tests install an inert scoped `paramiko` import
double; they test confirmations, pre-network guards and injected transport
failures, not genuine SSH. The actual Bash dispatch/ERR handler executes. No
system-wide pip install is required. Production `bridge/launcher.py` and its hash
verification are unchanged. Run `python3 -I tests/bridge-gate3/test_bridge_menu.py`
to exclude ambient Python import paths; `python3 -S` additionally omits global
site-packages for this fixture. The correction suite tests full RU/EN affirmation,
negative/default and incomplete/EOF cases, CLI statuses and clean JSON/raw stdout.
New external public DNS/TLS, two-VPS and Telegram tests are NOT_EXECUTED in this
correction pass; earlier VM/client results are historical, not newly performed.
