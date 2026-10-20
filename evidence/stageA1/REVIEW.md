# Stage A.1 — checkpoint evidence

Status: PARTIAL. Implementation and deterministic targeted regressions are
complete, but mandatory real ENOSPC and real nft kernel round-trip were
NOT_EXECUTED. Stage A exits 77/INCOMPLETE, not PASS.

The immutable supplied Stage A input is preserved as baseline-stageA.zip.
Its SHA-256 is d5dfc292683e99931de7731256d68ad63a5d0fb585915039d96d05241061e76d.
Extract that checkpoint only into a separate disposable directory for
before/after comparisons. Do not replace the candidate with it.

results.json lists actual final results. targeted-before.log is the initial
regression-first run against the immutable 0.2.10 manager (21 cases, 17 failed).
stage-a-suite-final.log includes all 32 final targeted cases and truthful
mandatory NOT_EXECUTED accounting. stock-symlink-before/after show the
additional exact-parent cleanup test within F11.

The raw final suite output is preserved byte-for-byte in
stage-a-suite-final.raw.log.gz. Its readable .log copy trims two trailing prompt
spaces only, so git diff --check also passes for committed evidence.

focused.diff covers implementation/tests/version/changelog, with zero context.
Project SHA256SUMS is generated separately over all current files (except
itself). It is packaging metadata, not a protected stale baseline manifest.

The original nft text mocks now support JSON through nft-json-model.sh.
That converter is TEST MODEL ONLY, is not shipped as a runtime dependency, and
does not replace real nft validation. The production verifier embeds its own
schema-1 parser; script-only manager installation/update requires no new asset.

Pending checks, only in a disposable Linux VM with suitable privileges:

    bash tests/stagea/sa1-real-nft-validation.sh
    bash tests/stagea/sa3-state-publication.sh
    bash tests/stagea/run-stage-a-suite.sh

The real-nft fixture refuses execution without a disposable network namespace.
It starts no systemd/nfqws services and never changes the host ruleset.
No production VPS was accessed, no release published, no push/merge performed.
Stage B has not started. The full Validation Campaign was not run.
