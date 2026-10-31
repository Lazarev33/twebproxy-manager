# PRERC-UPDATE-01 — focused legacy-transition stop

**OPEN / BLOCKED. No runtime correction has been applied.** Version remains the
unpublished v0.2.26-beta candidate. The draft PR must not be merged or released.

The focused rerun used a fresh, owner-marked Ubuntu 24.04.5 KVM guest, real PID1
systemd/capabilities/nft and a complete build/install of main4049dee. Both installed
local status and foreign-node status returned0. The exact accepted v026 script
(SHA256 c592c71b045c4eb780ccd95318a4230b2f4d51f311b4b624274f7b2d7976fe77)
was authenticated with an independently supplied digest over trusted loopback TLS.
The native legacy transaction returned0/UPDATE_SUCCESS; installed Bridge status
then returned1 because only the old bundle existed. This is an unconditional
acceptance FAIL. Local profile status remained0.

CLI rollback restored both exact v025 manager copies and version metadata. Wrong
digest, failed download and pre-mutation SIGTERM refused/aborted safely. A deliberate
failed-help mutant rolled back exactly; the offline helper also restored safely.
Active/pending state-file refusal fixtures made no remote requests or state changes;
they are not real active-tunnel tests. Canonical profile/secret, edited website,
manual TLS settings and original component hashes were preserved. Backend, relay
and SSH PID/start/restart snapshots were unchanged during update/recovery tests.

## Why a candidate-only preflight is insufficient

The executable that decides the v025→v026 transition is the installed v025 Bash
script. Its candidate preflight authenticates the script, checks bash syntax and
literal version fields, then backs up and replaces both manager copies. It does
not invoke candidate code or inspect candidate component requirements before
replacement. The new script first executes in post-replacement health probes.
An executable validator experiment confirms that exact v026 and an instrumented
candidate both pass static identity without executing the instrumented code.

Adding a check only to v026's manager-update function therefore cannot make the
required native v025 transition refuse before mutation. A post-install health
failure/rollback also does not satisfy that particular pre-mutation criterion.
The unchanged v025 updater has no authenticated component-delivery step.

Deliberately changing version-declaration syntax to confuse the legacy parser
would produce a misleading identity error, not an actionable verified-distribution
refusal. Downloading/installing components from --help or read-only overview would
introduce hidden mutations and a new distribution path. Neither is implemented.
An older/mismatched controller is never relabelled as the new verified bundle.

## Smallest proposed next design — not implemented

1. Agree an authenticated bootstrap/backport for the updater that actually runs
   on legacy installations, or explicitly arrange a verified full-distribution
   upgrade. Merely publishing a new candidate cannot change already installed
   v025's preflight. Existing full-source repair is recovery, not blocker closure.
2. In that updater, after candidate authentication/identity but before backup or
   either manager replacement, read strict candidate Bridge manifest/launcher
   digests and verify the exact installed bundle, including manifest file set,
   hashes and safe paths/ownership. Execute no unauthenticated candidate code.
3. When the required bundle is missing or mismatched, return a meaningful nonzero
   UPDATE_REFUSED components result with RU/EN instructions to obtain a complete
   independently verified distribution. Preserve existing copy/backup/rollback
   transactions and active/pending guards. Re-run native legacy entrypoint tests
   including the bootstrap trust and interruption boundary before closure.

This proposal adds no network redesign and does not implement automatic auxiliary
downloads. Coherent automatic delivery would need a separately agreed distribution
step and its failure/rollback contract. Product work stops here under the task's
explicit unsafe-to-rewrite exception. Only the reproducer and this stop record
are added; runtime and security/network policies remain byte-identical.

See the focused handoff REPORT/RESULTS and tests/prerc-v026/update01-installed.py.
No corrected GREEN, merge readiness or stable readiness is claimed. External RC
gates from docs/PRERC-v0.2.26.md remain unexecuted in this focused pass.
