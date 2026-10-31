# Gate2 verification

`test_safety.py` and existing Stage C1 fixtures are MODEL/UNIT tests.
`function-scope.sh <baseline-checkout>` compares actual Bash functions and
asserts accepted proc/firewall functions are unchanged.

The `twp-g2-*.py` scripts are the exact independent real-host lab harnesses.
They contain lab paths/IPs, no credentials. Run ONLY on explicitly authorized
disposable machines after reading them. They are not general provisioning
tools; the user-facing implementation is `foreign-node`. The lab operator
SSH alias is an external root-only fixture with strict known_hosts,
BatchMode, IdentitiesOnly and no agent forwarding. Reproduction requires
your own key outside this source tree and independently verified host keys.
The managed negative tests use the real installed isolated dependency cache;
they replace neither transport nor executor boundary with a model.

Order: inventory and public-port sampler; normal frontend fixture; Add by
key; real security snapshot, negative requests, protocol/TLS probe;
private-namespace proc fault, repair; link down/watcher, repair; Remove;
Add by password; backend failure; protocol probe; unavailable management-key
removal and retry; fault/crash injection after backend_ready; repair and
metadata comparison; restore original lab services and remove fixture keys.

The password harness creates a temporary sudo-capable bootstrap account,
random password exclusively in memory, and scoped SSH Match fixture. It
sends the password through a hidden PTY prompt and deletes fixtures in
finally. It requires an external operator key and known_hosts. Never add
passwords to arguments, environment variables, scripts, logs or evidence.

The proc fault test mounts visible procfs only inside a private unshare
namespace, drops CAP_SYS_ADMIN, and runs the REAL owned deploy job. It stops
the real owned foreign MTProxy and proves remount fails while host procfs
stays protected. Run Manager repair afterwards.

Root-only developer fault hooks:

```
TWEBPROXY_BRIDGE_FAIL_AFTER=backend_ready ./twebproxy-manager.sh foreign-node add ...
TWEBPROXY_BRIDGE_CRASH_AFTER=backend_ready ./twebproxy-manager.sh foreign-node add ...
./twebproxy-manager.sh foreign-node repair
```

Expected: first rc1 and complete compensation; second controller rc137,
durable phase/identity retained, then repair removes interrupted deployment.
Compare canonical profile, profiles.json, backend.env, instance.env and
global.env hashes, original backend active and no sidecar/owner marker.
Actual evidence supersedes expectations. HTTPS req_pq is synthetic, not a
genuine application. Upstream Go MTProto probe source is retained from Gate1.
