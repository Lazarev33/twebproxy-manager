# Architecture

## Components

`TWebProxy Manager` is control-plane tooling. It is not in the data path after installation.

Runtime data path:

```text
Telegram Desktop
  -> HTTPS/WSS :443
  -> Caddy/Nginx/existing frontend
  -> 127.0.0.1:<relay>
  -> tproxy-server
  -> 127.0.0.1:<backend>
  -> official MTProxy
  -> Telegram infrastructure
```

## Processes

Per hostname:

```text
twebproxy@<hostname>.service
```

Per profile:

```text
twebproxy-mtproxy@<hostname>--<profile>.service
```

Shared services:

```text
twebproxy-firewall.service
twebproxy-refresh-mtproxy.timer
```

## State

Canonical manager state is root-owned under `/etc/twebproxy`. Generated `config.json` and `profiles.json` are reconstructed from instance/profile env state by `repair`.

Runtime services do not need directory traversal into root-only state. systemd `LoadCredential` exposes only required files through each unit's credential directory.

## Network boundaries

- public: TCP 443, and TCP 80 when managed ACME/redirect requires it;
- relay/admin: loopback only;
- tproxy-server -> MTProxy backend: loopback connection;
- stock MTProxy may create wildcard listeners for backend/stats ports;
- manager-owned nftables input hook drops non-loopback traffic to every registered backend/stats port.

## Update model

Relay update is transactional at binary level:

```text
fetch -> go test -> build candidate -> config check all instances
-> backup old binary -> install candidate -> restart/health
-> rollback old binary on failure
```

MTProxy is separately pinned; it is not silently advanced together with relay.
