# Bounded first-RC acceptance

Run project commands from the verified source root. Set
`export PYTHONDONTWRITEBYTECODE=1` before Python tests. Run:

```
bash tests/tui-smart-defaults/run-local.sh
python3 tests/bridge-gate3/test_bootstrap_directories.py
python3 tests/distribution/test_engine.py
python3 tests/distribution/test_download.py
bash tests/final-rc/nft-discovery-fixture.sh
bash tests/stageb/transaction-fixture.sh
bash tests/stageb/apply-ambiguity-fixture.sh
```

The nft discovery fixture is a model; bootstrap directories use real chroot/UID
permissions with doubled SSH/agent body. Neither is a real network/client PASS.
Legacy updater fixtures are separately labelled, not a replacement for accepted
UPDATE01 real KVM evidence. Run them only to verify version-sensitive fixtures.

The real scripts require root, KVM, qemu/cloud-localds, an **explicitly disposable**
development host and the signed Ubuntu image hash pinned in create_clean_lab.py.
The original verified image/signature provenance is retained in the handoff.
They refuse existing overlays; never reset or wipe a previous run. Adapt only
explicit fixture root paths/loopback ports for an independently authorized lab.
No live VPS names/IPs are targets in these scripts.

`create_clean_lab.py` creates new overlays and temporary public-key access.
Pin each guest's SSH ED25519 fingerprint to its local hypervisor serial marker
before using SSH; never trust keyscan by itself. Keys, seeds, disks and raw logs
stay under root0700 `/root/twp-finalrc-private`, outside source/evidence ZIPs.
`enable_lab_probes.py` is historical one-time setup; current creation already
includes forwards. Do not rerun it against a running installed pair.

Transfer the independently authenticated full runtime and install_clean_entry.py
to a genuinely fresh Entry. Its normal Advanced workflow uses private lab DNS/
90-day test CA, default profile/site, normal official downloads/builds. Record the
exit code and guest RESULTS.json. `create_clean_entry_retest.py` was used for a
separate fresh attempt after the first fixture's CA/expiry error; it preserves
that original guest. No prepared MTProxy/relay binary is substituted.

Run run_bridge_acceptance.py phases `provision`, `verify`, `remove` in order.
The bootstrap key is generated **inside Entry**; only its public part is installed
on the disposable Exit. Provision asserts absent libexec/state immediately
before Add. Verify asserts JSON health values, not CLI0 alone. Keep protocol probes
serial with repair/recovery/removal: repair intentionally restarts the backend.
Run `recovery.py`, `secret_access.py` on their documented hosts and installed_menu.py
as directed by docstrings. `local_cleanup.py` deliberately deletes only the marked
independent Entry test profile/core after preserving evidence; do not run it on
an operator installation.

`owned_table_enumeration.py MANAGER` runs actual generated helper transactions in
a private kernel network namespace, retaining real foreign owner sessions. Twelve
native old-helper attempts did not reproduce the observed heap abort; their logs
are nonreproducing baseline controls. The real original failure is the retained
removal journal. The separate deterministic CLI failure injection is MODEL.

https_probe.py and direct_mtproto.py use synthetic nonce-matched req_pq/resPQ,
never Telegram application authentication. Private secrets are read only from
root-only files/normal Manager credentials, never CLI arguments. A wrong-secret
negative probe is valid only with a successful correct-secret positive control;
this checkpoint did not obtain that positive control. lab_nat_fixture.py is an
explicitly temporary QEMU RPC-NAT diagnostic, not shipped runtime functionality;
the hypothesis failed and the override was removed.

Sanitize before export; do not archive private directories or raw Manager setup/
show output. Verify original profile/site/TLS, remaining owned resources, SSH and
unrelated Nginx before powering off only the disposable units created by this run.
The delivered REPORT/RESULTS contain actual commands, returns and honest gaps.
