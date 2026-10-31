# Stage B checkpoint — PARTIAL

Implementation is complete; real kernel/systemd/ENOSPC validation did not
execute in this environment. The evidence distinguishes schema/model PASS
from NOT_EXECUTED_ENVIRONMENT_LIMITATION. Do not infer full release acceptance.

Baseline identities and machine results are in results.json. The original A.1
ZIP is preserved byte-identically, together with its report/checksums. The
normalized-A1.zip adds only the exact repository-only files from the verified
GitHub tree. It is the comparison baseline for the scope fixture:

```sh
mkdir /tmp/twebproxy-baseline-check
unzip evidence/stageB/normalized-A1.zip -d /tmp/twebproxy-baseline-check
bash tests/stageb/scope-invariants.sh /tmp/twebproxy-baseline-check/normalized-A1 .
sha256sum -c SHA256SUMS
```

The focused.patch is a zero-context diff covering implementation/tests/release
identity relative to normalized A.1 (apply with git apply --unidiff-zero).
Evidence containers and regenerated SHA256SUMS are excluded
from the patch to avoid recursive checksums; the final source tree and root
SHA256SUMS cover them. Repository docs and README remain unchanged. The raw
Stage A transcript is preserved as stage-a-suite.log.gz; use gzip -cd to read.

See tests/stageb/README.md for the safe disposable-VM commands. Remaining checks:

- Stage B actual nft batch/JSON/state round trip.
- Stage B actual systemd start/reload/failed restart without ExecStop gap.
- Stage A.1 F12 actual nft round trip.
- Stage A.1 genuine ENOSPC on private tmpfs.

No production, push, merge, release publication or Stage C work was performed.
