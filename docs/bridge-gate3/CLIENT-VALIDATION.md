# Client connection and sanitized evidence

The Gate3 operator actually tested Telegram for iOS 13.1.2 using the RU-facing
link. They reported successful messages, photos, video messages, a 417 MB file,
LTE MegaFon, LTE T2 and Wi-Fi, then confirmed full application relaunch and
recovery after temporary loss of network. Approximate time: 2026-10-31 13:28 MSK.
These are operator-reported actions, corroborated by live server WEB session,
stream and byte counters, not a captured/decrypted Telegram session. The exact
OS build and whole-file hash were not collected. A reported 417 MB completion
must not be read as an independent byte-for-byte 417 MB tunnel measurement.

The upstream Telegram Desktop 7.3.3 release and its source expose WEB URL handling;
7.1.0 already contains that handler. Desktop runtime testing is NOT_EXECUTED here.
Do not assume that every Telegram client, Telegram Web in a browser, a separate
native macOS client, MTProto or SOCKS supports this WEB transport. Android/iOS
status in old upstream PoC documents may lag actual clients. The iOS claim here
is limited to the operator's actual13.1.2 test on this deployment.

Retrieve exactly one private connection link on the RU server in a trusted
terminal (not a recorded session, report or shell command argument):

```
sudo twebproxy connection-link martins.ortositi.ru default
```

It reads actual canonical Manager configuration and prints one `tg://webproxy`
link. Open it directly in the intended WEB-capable Telegram application and
approve import. Do not share it in the acceptance ZIP or public chat. The normal
public website at `/` does not contain the link, secret or bridge capability.
The t.me browser route is not relied upon; the deployed protocol uses HTTPS 443.
No Telegram account credentials/session files are requested by Manager or tests.

Repeatable human checklist: record client/OS version and time; import link;
confirm connected state/dialog updates; send and receive a non-sensitive test
message; view photo/video; download a larger file and optionally verify its hash;
briefly disable networking and restore it; fully close and reopen Telegram;
switch Wi-Fi/mobile if available. Mark unavailable actions NOT_EXECUTED. Synthetic
nonce-matched resPQ evidence alone never marks these application checks PASS.

Safe current entry diagnostics (no full private URLs):

```
sudo twebproxy foreign-node diagnose
sudo twebproxy status martins.ortositi.ru --json
sudo twebproxy audit martins.ortositi.ru --json
sudo python3 /root/twebproxy-gate3/tools-bridge-host-diagnostics.py
```

Safe current foreign diagnostics, from the preserved source workspace:

```
sudo python3 /root/projects/twebproxy/gate3/tools/bridge-host-diagnostics.py
```

The portable script is also supplied at `source/tools/bridge-host-diagnostics.py`.
It exports unit states, enforced IP policy, owned nft rules, private route and
secret-file permissions. It never prints configs, private key bytes, MTProxy
argv or credentials; a proc policy failure is tested without reading the secret.
Do not substitute raw `ps`, full service status or arbitrary journal dumps in a
shared report: stock MTProxy necessarily receives its secret in argv. Redact
account names, dialogs, phone numbers and private links from client screenshots.
