# Stage H verification

User experience and guided setup. Model tests through the real prompts
(stdin, and a pseudo-terminal where `read -p` prompts or the first-run language
selection must be visible); the host boundary (systemd, nft, ip, dig, curl,
Caddy/Nginx/certbot) is modeled by the Stage C1–E harness layers.

| Check | What it proves |
|---|---|
| H1 | quick setup asks only hostname, setup type, website and TLS, and creates profile `default` (new secret, `https`, automatic ports) with `STOCK`; advanced setup still asks every value |
| H2 | Ctrl-D at the setup type, website or plan, "no" at the plan and the default "no" on a DNS mismatch create nothing; an invalid hostname is asked again, three invalid names abort |
| H3 | first run on a terminal: language selection, prerequisites, Quick setup first, Russian text |
| H4 | main menu order and routing of all eight items; 0 and Ctrl-D return; network compatibility is no longer duplicated in Settings |
| H5 | `dpi list-methods`: six IDs, original one-line descriptions, direction, overhead, IPv4-wide effect, no-guarantee note, revert command, no "best mode"; menu: STOCK intro, explained choices, shared-IPv4 consent (Enter and Ctrl-D change nothing, "y" applies) |
| H6 | `show`: connection steps, only the two existing link forms and the site URL, honest client-support note, troubleshooting commands (EN/RU) |
| H7 | compact status prints a next step for a stopped relay; one next step per check family (an UNKNOWN TLS state reads "not confirmed", never "failed"); `--json` is unchanged |
| H8 | help: quick start in EN/RU, printed literally (shell-function tripwires for `sudo`/`twebproxy` prove nothing is executed); NO_COLOR leaves no ANSI |
| `heredoc-guard.sh` | no backtick in an unquoted heredoc of the manager (a draft of the help once executed `sudo twebproxy`) |

```sh
bash tests/stageh/run-stage-h-suite.sh            # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/stageh/ux-fixture.sh [<manager>]
bash tests/stageh/heredoc-guard.sh [<manager>]
bash tests/stageh/h-scope-invariants.sh <v0.2.21 source tree>
```

Not proven here: real Caddy/Nginx/ACME, a public website, real Telegram
clients on desktop and mobile, real network compatibility effects — RC lab
gates.
