# v0.2.26-beta — focused correction

Historical correction-stage record; the subsequent integration starts from GitHub
main4049dee on a dedicated review branch. See [current pre-RC](PRERC-v0.2.26.md)
for the integration identity and open updater blocker. References below to
base6f8b4b2 describe the accepted input artifact, not the new integration commit.

Unpublished development candidate. No release, deployment or architecture change.
Implementation continues the complete Smart Defaults artifact whose SHA256 is
`7bddd9f5a9f1956f941a420bc4c15e21f6bfdcd7f210b5de7fac78b1ab26f3be`.
Both artifact manifests/CRC and every product file against the worktree were
verified before edits: no newer product changes needed reconciliation.

## Corrections

1. `stage4_confirm_restore` matched one character, unlike `yesno`. A case statement
   now accepts explicit `y/Y/yes/YES/Yes/д/Д/да/ДА/Да`. The complete-line reader,
   default-NO refusal code1, input-closure code130 and restore transactions remain.
   Python `confirmed` accepts the same affirmative vocabulary; its two confirmation
   prompts retain the newline so an unfinished affirmative plus EOF cannot approve.
2. English-only Bridge errors bypassed the bilingual catalog. Sixteen messages
   now use existing `ui_msg` infrastructure with actionable RU/EN explanations;
   the Russian help line is translated. JSON field names/payloads are unchanged.
   The official localization audit passes without changing the audit itself.
3. On Bash5.2.21, returning a failure from the inherited fatal ERR handler while
   unwinding `bridge_launcher → foreign_node_cmd → main` emitted `pop_var_context`.
   The handler now exits with its saved original status. No global `set -e`
   disabling or success conversion was introduced. Existing best-effort snapshots
   remain; a snapshot failure cannot replace the original code. Interactive menu
   boundaries still display the failure and return to the menu.

Before/after evidence includes actual Bash code7 with the original diagnostic,
restore `да` decline/code1 versus acceptance/code0, and the official audit failure
versus PASS. The new 10-case suite exercises RU/EN affirmative/negative/default/
EOF/incomplete inputs, real child process failures (1/7/23/130), clean JSON/raw
stdout, successful CLI and a failed diagnostic collector. Test transports are
explicit doubles; this is not new SSH or Telegram application acceptance.

## Reproducibility and security

Bridge menu tests and controller unit tests use scoped inert Paramiko import
doubles for their pre-network guard/confirmation fixtures. The standalone menu
suite also runs with `python3 -S`, omitting global site-packages. The production
verified launcher, its dependency checks/wheels and privileged agent are unchanged.
Regenerate the controller bundle digest with `tools/bridge-bundle.py` after edits;
no integrity bypass is used.

129 protected Bash functions (updater/helper, firewall/guard/procfs and DPI) are
byte-identical to the input candidate; the confirmation reader is the sole Stage4
exception. Accepted v0.2.24 firewall/procfs function comparison also passes.
Bridge Bash control flow is unchanged after normalizing only localized error
messages. In controller `add`/`main`, only the two confirmation calls changed;
all other provisioning behavior is unchanged, checked by AST comparison.

Read `tests/tui-smart-defaults/README.md`; the all-in-one delivery contains current
`REPORT.md`, `RESULTS.json`, RED/GREEN logs, comparison evidence and reproducible
Git history/patch. Source remains at original base commit6f8b4b2 plus an uncommitted
delta; exact patch/source manifests identify the correction, not a fabricated commit.

## Documentation and acceptance limits

GitHub main was independently checked as
`4049dee7d0f9a0cc19da896d1ca9ccf4bb4abc9c` (v0.2.25-beta). README and the primary
roadmap combine that authoritative documentation with the unpublished candidate
status. `roadmap-test.md` is preserved byte-for-byte. Architecture/security docs
retain the published single-VPS and RU Entry → loopback forwarder → WireGuard →
foreign stock MTProxy boundaries. No experiment in roadmap-test is authorized.

Gate2 remains conditional17PASS/0FAIL/8NOT_EXECUTED. Gate3 includes operator-reported
iOS13.1.2 messages/media/network-switch tests and server corroboration, not an
independent whole-file hash, new Desktop test or full RC campaign. The original
VM/real-host evidence is retained as historical, not relabelled as this pass.

No live RU/Foreign/production access, network/firewall mutation, VPS reboot, Git
reset, push, merge or release occurred. New public DNS/TLS, client, two-VPS,
platform and cold-boot acceptance remain NOT_EXECUTED. The focused correction
does not establish RC or production readiness.
