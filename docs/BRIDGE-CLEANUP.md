# Safe removal

Run `sudo twebproxy foreign-node remove` on the entry and approve the plan.
It restores local mapping only after the protected local backend is active,
disables the forward socket before stopping its service, and removes only
UUID-owned components. Packages are retained. Unavailable remote management
produces PARTIAL/cleanup_pending. Keep journal/key, restore connectivity and
run repair. Do not reinstall over a tombstone. Interrupted initial enrollment
may require repair with original bootstrap key or hidden password options.

Before destroying a lab: check no node.json/bridge.owner/bridge.json; no owned
unit/interface/table/key/account/sshd Match/sudoers file; canonical profile
port/secret and frontend unchanged; original services running. Remove
fixture HTTPS service/certificate/client secret, bootstrap account and test
SSH keys separately. The Manager preserves original operator keys and
unrelated services/packages.

Lab cleanup evidence records restoration of foreign v0.2.24 test instances
and original Manager/global.env/Caddyfile hashes. Restoring these parked
fixtures is not part of normal provisioning. No production machine involved.
