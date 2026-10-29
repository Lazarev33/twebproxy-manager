# Stage C2 verification

Relay lifecycle: relay binary update (candidate validation, atomic install,
restart, bounded readiness, final verification, rollback, interruption),
relay update/restart serialization, instance restart and delete failure
propagation. Model tests only: safe on any Linux test workstation with Bash,
jq, coreutils and util-linux; no system state changes.

```sh
bash tests/stagec2/run-stage-c2-suite.sh            # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/stagec2/relay-lifecycle-fixture.sh [<manager>]
bash tests/stagec2/c2-scope-invariants.sh <v0.2.16 source tree>
```

`relay-harness.sh` extends `tests/stagec1/state-harness.sh`: the installed
relay binary is a script with a build marker, `go test`/`go build` are models
producing a candidate build, systemctl records which build each relay runs,
and curl answers `/readyz` from that record. Faults (start/restart failure,
never ready, slow listen, crash after first ready, partial binary write,
`-check` rejection) are files in the sandbox; see the harness header.

None of this proves real systemd, curl, Go toolchain or filesystem behaviour;
those remain disposable-VM gates before an RC. The C1 scope tests
(`tests/stagec1/c1*-scope-invariants.sh`) describe their own stage deltas and
are run against their stage checkpoints, not against later trees.
