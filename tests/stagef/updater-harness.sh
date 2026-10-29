#!/usr/bin/env bash
# Behavioral sandbox for the Stage F updater and supply-chain regressions.
#
# Each command runs the unmodified manager under test in a separate bash process
# with production `set -Eeuo pipefail` and its ERR trap (f_run / f_eval). Only
# paths are rebound, all under the case directory: the real lock, staging,
# backup, install, health gate, rollback, offline restore helper, flock, jq and
# openssl run. The installed manager and every published release are small fake
# managers that answer the health probes (--help, --json overview).
#
# Network boundary: a curl model ($F_CASE/bin/curl) answers only from
# $F_CASE/remote, a modeled GitHub (api.github.com, raw.githubusercontent.com,
# github.com release downloads and their asset hosts). Nothing leaves the host.
# F_LANG=en|ru selects the UI language (default: the manager's, Russian).
# Release-signing keys are ephemeral Ed25519 keys generated per run in
# $F_ROOT/keys; they are test fixtures, never shipped or pinned in the manager.
#
# Remote layout (under $F_CASE/remote):
#   www/<host>/<path>        response body (missing file: HTTP 404)
#   redirect/<host>/<path>   holds the Location URL of a 302
#   fault/<host>/<path>      partial (exit 18 after half the body),
#                            truncate (half the body, exit 0), hang
#   offline                  every request fails (exit 6)
#   requests                 log of every requested and redirected URL
# Faults and barriers on the host side (files in $F_CASE):
#   fail-mv-to               mv onto the named path fails once
#   park-install-dir         the first install into a .twebproxy-stage4 temp file in
#                            that directory parks until $F_CASE/release exists
#                            ($F_CASE/parked marks arrival)
#   fail-install-backup      install into a backup being created fails (disk error)

F_HARNESS="${BASH_SOURCE[0]}"
F_SLUG="Lazarev33/twebproxy-manager"

f_init() { # $1=manager under test
  F_MGR="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
  F_ROOT="$(mktemp -d /tmp/twebproxy-stagef.XXXXXX)"
  F_LOCAL_VERSION="$(sed -nE 's/^MANAGER_VERSION="([^"]*)"$/\1/p' "$F_MGR" | head -n1)"
  export F_MGR F_ROOT F_LOCAL_VERSION F_HARNESS
  install -d -m 0700 "$F_ROOT/keys"
  local k
  for k in A B; do
    openssl genpkey -algorithm ed25519 -out "$F_ROOT/keys/$k.pem" 2>/dev/null || return 1
    openssl pkey -in "$F_ROOT/keys/$k.pem" -pubout -outform DER 2>/dev/null | base64 -w0 > "$F_ROOT/keys/$k.pub" || return 1
  done
}

f_fini() { [[ -z "${F_ROOT:-}" || "${KEEP_STAGEF_TMP:-0}" == 1 ]] || rm -rf -- "$F_ROOT"; }

# ---- sandbox ---------------------------------------------------------------

f_case() { # $1=name: fresh sandbox with two identical installed copies and the helper
  F_CASE="$F_ROOT/$1"
  export F_CASE F_REMOTE="$F_ROOT/$1/remote"
  install -d -o root -g root -m 0700 "$F_CASE" "$F_CASE/usr" "$F_CASE/opt" "$F_CASE/libexec" \
    "$F_CASE/etc" "$F_CASE/var/lib" "$F_CASE/run/lock" "$F_CASE/bin" "$F_REMOTE" "$F_REMOTE/www"
  : > "$F_REMOTE/requests"
  f_write_models
  f_fake_manager "$F_CASE/usr/twebproxy" "$F_LOCAL_VERSION"
  install -o root -g root -m 0755 "$F_CASE/usr/twebproxy" "$F_CASE/opt/twebproxy-manager.sh"
  printf 'MANAGER_VERSION=%s\nTPROXY_UPSTREAM_COMMIT=0123abcd\nMTPROXY_COMMIT=4567ef89\n' "$F_LOCAL_VERSION" > "$F_CASE/etc/global.env"
  chmod 0600 "$F_CASE/etc/global.env"
  F_OLD_HASH="$(f_sha "$F_CASE/usr/twebproxy")"
  F_RUN=0
  f_eval 'stage4_install_restore_helper yes' >/dev/null 2>&1 || { echo "f_case: helper bootstrap failed" >&2; return 1; }
  find /tmp -maxdepth 1 -name 'twebproxy-manager.*' -printf '%f\n' 2>/dev/null | sort > "$F_CASE/tmp-before"
}

# Rebinds every updater path into the case directory (called after sourcing).
f_bind() {
  BASE_DIR="$F_CASE/etc"; GLOBAL_ENV="$BASE_DIR/global.env"; LANGUAGE_FILE="$BASE_DIR/ui-language"
  PROJECT_DIR="$F_CASE/opt"; PROJECT_MANAGER_COPY="$PROJECT_DIR/twebproxy-manager.sh"
  LOG_DIR="$PROJECT_DIR/logs"; LOG_MANAGER_DIR="$LOG_DIR/manager"; LOG_RUNTIME_DIR="$LOG_DIR/runtime"
  LOG_BUNDLE_DIR="$LOG_DIR/bundles"; LOG_FULL_DIR="$LOG_DIR/full"
  MANAGER_BIN="$F_CASE/usr/twebproxy"
  LIBEXEC_DIR="$F_CASE/libexec"; UPDATE_RESTORE_HELPER="$LIBEXEC_DIR/restore-update-backup"
  UPDATE_BACKUP_PARENT="$F_CASE/var/lib/twebproxy"; UPDATE_BACKUP_ROOT="$UPDATE_BACKUP_PARENT/update-backups"
  UPDATE_LOCK_FILE="$F_CASE/run/lock/twebproxy-manager-update.lock"
  UPDATE_CACHE_FILE="$PROJECT_DIR/update-check.env"
  UPDATE_BACKUP_RETENTION=4
  STAGE4_UPDATE_LOCK_FD=""
  # Release-signing trust: key A is pinned unless the case says otherwise.
  case "${F_PIN_KEY:-A}" in
    none) MANAGER_UPDATE_TRUSTED_KEYS=();;
    *) MANAGER_UPDATE_TRUSTED_KEYS=("$(<"$F_ROOT/keys/${F_PIN_KEY:-A}.pub")");;
  esac
  PATH="$F_CASE/bin:$PATH"
  [[ -z "${F_LANG:-}" ]] || UI_LANGUAGE="$F_LANG"
  disable_colors 2>/dev/null || true
}

f_run() { bash -c 'source "$1"; shift; source "$F_MGR"; f_bind; set -Eeuo pipefail; echo "$$" > "$F_CASE/pid"; "$@"' f-run "$F_HARNESS" "$@"; }
f_eval() { bash -c 'source "$1"; source "$F_MGR"; f_bind; set -Eeuo pipefail; echo "$$" > "$F_CASE/pid"; eval "$2"' f-eval "$F_HARNESS" "$1"; }

f_update() { # [args...] -> F_RC, F_OUT (combined output file)
  F_RUN=$((F_RUN + 1)); F_OUT="$F_CASE/out.$F_RUN"
  timeout -k 5 "${F_TIMEOUT:-120}" bash -c 'source "$1"; shift; source "$F_MGR"; f_bind; set -Eeuo pipefail; echo "$$" > "$F_CASE/pid"; manager_update_cmd "$@"' \
    f-update "$F_HARNESS" "$@" > "$F_OUT" 2>&1 < /dev/null
  F_RC=$?
}

f_sha() { sha256sum "$1" | awk '{print $1}'; }

f_fake_manager() { # $1=path $2=MANAGER_VERSION [$3=behavior] [$4=release label] [$5=extra line]
  local path="$1" version="$2" behavior="${3:-good}" label="${4:-$2-beta}" extra="${5:-}"
  install -d -m 0700 "$(dirname -- "$path")"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'MANAGER_VERSION="%s"\nMANAGER_RELEASE_VERSION="%s"\n' "$version" "$label"
    [[ -z "$extra" ]] || printf '%s\n' "$extra"
    printf 'F_BEHAVIOR=%q\nF_CASE=%q\n' "$behavior" "$F_CASE"
    cat <<'EOF'
overview() { printf '{"schema_version":"twebproxy.output.v1","command":"overview","overall":"OK","data":{"manager_version":"%s"}}\n' "$MANAGER_VERSION"; }
case "${1:-}" in
  --help)
    if [[ "$F_BEHAVIOR" == hang-help ]]; then
      echo "$$" > "$F_CASE/hang.pid"; trap '' TERM INT HUP; exec sleep 300
    fi
    printf 'TWebProxy Manager v%s\n' "$MANAGER_RELEASE_VERSION";;
  --json)
    case "$F_BEHAVIOR" in
      bad-overview) printf '{"schema_version":"wrong","command":"overview","data":{}}\n';;
      linger) sleep 120 < /dev/null > /dev/null 2>&1 & echo "$!" > "$F_CASE/linger.pid"
              printf '{"schema_version":"wrong"}\n';;
      corrupt-backup) for f in "$F_CASE"/var/lib/twebproxy/update-backups/update-*/files/twebproxy-manager.sh; do
                        [[ -f "$f" ]] && printf '\n# corrupted during the update\n' >> "$f"
                      done
                      printf '{"schema_version":"wrong"}\n';;
      *) overview;;
    esac;;
  *) exit 2;;
esac
EOF
  } > "$path"
  chmod 0755 "$path"
  [[ "$behavior" != bad-syntax ]] || printf 'if then fi\n' >> "$path"
}

# ---- modeled remote --------------------------------------------------------

f_put() { # $1=URL $2=source file (or - for stdin)
  local rest="${1#https://}" dest
  dest="$F_REMOTE/www/$rest"
  mkdir -p "$(dirname -- "$dest")"
  if [[ "$2" == - ]]; then cat > "$dest"; else cp -- "$2" "$dest"; fi
}

f_redirect() { # $1=URL $2=Location
  local dest="$F_REMOTE/redirect/${1#https://}"
  mkdir -p "$(dirname -- "$dest")"; printf '%s\n' "$2" > "$dest"
}

f_fault() { # $1=URL $2=partial|truncate|hang
  local dest="$F_REMOTE/fault/${1#https://}"
  mkdir -p "$(dirname -- "$dest")"; printf '%s\n' "$2" > "$dest"
}

f_requested() { grep -Fq -- "$1" "$F_REMOTE/requests"; }

# f_publish VERSION [key=value...]: one release on the modeled GitHub.
#   behavior=   candidate behavior (good, bad-overview, hang-help, linger, corrupt-backup, bad-syntax)
#   embedded=   MANAGER_VERSION inside the candidate (default VERSION)
#   label=      MANAGER_RELEASE_VERSION inside the candidate (default VERSION-beta)
#   extra=      one extra line inside the candidate
#   tag= draft= prerelease= html_repo=   release API fields
#   sign=A|B|none   manifest signing key (none: no manifest/signature assets)
#   manifest=   jq filter applied to the manifest before signing
#   tamper=1    change the manifest bytes after signing
#   artifact=   file served instead of the signed candidate (with matching SHA256SUMS)
#   asset_host= host the release-download links redirect to
#   raw_redirect=URL   the raw artifact and SHA256SUMS paths redirect there
#   api=        file served as the releases/latest answer instead
f_publish() {
  local version="$1"; shift
  local behavior=good embedded="$version" label="$version-beta" extra="" tag="v$version" draft=false
  local prerelease=false html_repo="$F_SLUG" sign=A manifest_filter=. tamper=0 artifact="" api=""
  local asset_host=release-assets.githubusercontent.com raw_redirect="" kv
  for kv in "$@"; do
    case "$kv" in
      behavior=*) behavior="${kv#*=}";; embedded=*) embedded="${kv#*=}";; label=*) label="${kv#*=}";;
      extra=*) extra="${kv#*=}";; tag=*) tag="${kv#*=}";; draft=*) draft="${kv#*=}";;
      prerelease=*) prerelease="${kv#*=}";; html_repo=*) html_repo="${kv#*=}";; sign=*) sign="${kv#*=}";;
      manifest=*) manifest_filter="${kv#*=}";; tamper=*) tamper="${kv#*=}";; artifact=*) artifact="${kv#*=}";;
      asset_host=*) asset_host="${kv#*=}";; raw_redirect=*) raw_redirect="${kv#*=}";; api=*) api="${kv#*=}";;
      *) echo "f_publish: unknown option $kv" >&2; return 1;;
    esac
  done
  local pub="$F_CASE/published/$tag" commit sha size served
  mkdir -p "$pub"
  f_fake_manager "$pub/twebproxy-manager.sh" "$embedded" "$behavior" "$label" "$extra"
  F_CANDIDATE="$pub/twebproxy-manager.sh"
  F_CANDIDATE_HASH="$(f_sha "$F_CANDIDATE")"
  commit="$(printf '%s' "$F_CANDIDATE_HASH" | sha1sum | awk '{print $1}')"
  F_COMMIT="$commit"
  sha="$F_CANDIDATE_HASH"; size="$(stat -c %s "$F_CANDIDATE")"
  served="${artifact:-$F_CANDIDATE}"

  if [[ -n "$api" ]]; then
    f_put "https://api.github.com/repos/$F_SLUG/releases/latest" "$api"
  else
    jq -n --arg tag "$tag" --arg html "https://github.com/$html_repo/releases/tag/$tag" \
      --argjson draft "$draft" --argjson prerelease "$prerelease" \
      '{url:"modeled", html_url:$html, tag_name:$tag, name:$tag, draft:$draft, prerelease:$prerelease,
        body:"Release notes mention \"tag_name\": \"v9.9.9\" in passing.", assets:[]}' \
      | f_put "https://api.github.com/repos/$F_SLUG/releases/latest" -
  fi

  local raw="https://raw.githubusercontent.com/$F_SLUG" ref
  for ref in "$tag" "$commit"; do
    if [[ -n "$raw_redirect" ]]; then
      f_redirect "$raw/$ref/twebproxy-manager.sh" "$raw_redirect/twebproxy-manager.sh"
      f_redirect "$raw/$ref/SHA256SUMS" "$raw_redirect/SHA256SUMS"
      f_put "$raw_redirect/twebproxy-manager.sh" "$served"
      printf '%s  twebproxy-manager.sh\n' "$(f_sha "$served")" | f_put "$raw_redirect/SHA256SUMS" -
    else
      f_put "$raw/$ref/twebproxy-manager.sh" "$served"
      printf '%s  twebproxy-manager.sh\n' "$(f_sha "$served")" | f_put "$raw/$ref/SHA256SUMS" -
    fi
  done

  [[ "$sign" != none ]] || return 0
  jq -cn --arg slug "$F_SLUG" --arg version "$version" --arg label "$label" --arg tag "$tag" \
    --arg commit "$commit" --arg sha "$sha" --argjson size "$size" \
    '{format:"twebproxy.manager-release.v1", repository:$slug, channel:"stable", version:$version,
      release_version:$label, tag:$tag, commit:$commit,
      artifact:{name:"twebproxy-manager.sh", size:$size, sha256:$sha}}' \
    | jq -c "$manifest_filter" > "$pub/manifest.json"
  openssl pkeyutl -sign -inkey "$F_ROOT/keys/$sign.pem" -rawin -in "$pub/manifest.json" -out "$pub/manifest.sig.bin" 2>/dev/null || return 1
  base64 -w0 < "$pub/manifest.sig.bin" > "$pub/manifest.sig"
  printf '\n' >> "$pub/manifest.sig"
  [[ "$tamper" != 1 ]] || sed -i 's/"channel":"stable"/"channel":"stable" /' "$pub/manifest.json"
  local name dl
  for name in twebproxy-manager-release.json twebproxy-manager-release.json.sig; do
    dl="https://github.com/$F_SLUG/releases/download/$tag/$name"
    f_redirect "$dl" "https://$asset_host/github-production-release-asset/1/$tag/$name"
  done
  f_put "https://$asset_host/github-production-release-asset/1/$tag/twebproxy-manager-release.json" "$pub/manifest.json"
  f_put "https://$asset_host/github-production-release-asset/1/$tag/twebproxy-manager-release.json.sig" "$pub/manifest.sig"
}

f_publish_branch() { # $1=branch $2=VERSION [$3=behavior]: a development branch (never a release)
  local raw="https://raw.githubusercontent.com/$F_SLUG/$1" file="$F_CASE/published/branch-$1.sh"
  mkdir -p "$F_CASE/published"
  f_fake_manager "$file" "$2" "${3:-good}"
  F_CANDIDATE="$file"; F_CANDIDATE_HASH="$(f_sha "$file")"
  printf '%s\n' "$2" | f_put "$raw/VERSION" -
  f_put "$raw/twebproxy-manager.sh" "$file"
  printf '%s  twebproxy-manager.sh\n%s  VERSION\n' "$F_CANDIDATE_HASH" "$(printf '%s\n' "$2" | sha256sum | awk '{print $1}')" \
    | f_put "$raw/SHA256SUMS" -
}

# ---- observations ----------------------------------------------------------

f_copies_are() { # $1=hash: both installed copies are root 0755 regular files with this content
  local t
  for t in "$F_CASE/usr/twebproxy" "$F_CASE/opt/twebproxy-manager.sh"; do
    [[ -f "$t" && ! -L "$t" && "$(stat -c '%u:%g:%a' "$t")" == 0:0:755 && "$(f_sha "$t")" == "$1" ]] || return 1
  done
}

f_backup_count() { find "$F_CASE/var/lib/twebproxy/update-backups" -mindepth 1 -maxdepth 1 -name 'update-*' 2>/dev/null | wc -l; }

f_lock_free() { flock -n "$F_CASE/run/lock/twebproxy-manager-update.lock" true; }

f_release_holder() { # stops the f_hold_lock holder and waits until the lock is free
  local i
  kill -KILL "$(<"$F_CASE/holder.pid")" 2>/dev/null
  for ((i = 0; i < 50; i++)); do f_lock_free && return 0; sleep 0.1; done
  return 1
}

# Leftovers of an update: candidate temp files in /tmp (pre-Stage F location),
# the staging directory, and install temp files next to the installed copies.
f_leftovers() {
  local now
  now="$(find /tmp -maxdepth 1 -name 'twebproxy-manager.*' -printf '%f\n' 2>/dev/null | sort)"
  comm -13 "$F_CASE/tmp-before" <(printf '%s\n' "$now" | sed '/^$/d') | sed 's#^#/tmp/#'
  [[ ! -e "$F_CASE/var/lib/twebproxy/update-staging" ]] || echo "$F_CASE/var/lib/twebproxy/update-staging"
  find "$F_CASE/usr" "$F_CASE/opt" -maxdepth 1 -name '.twebproxy-*' 2>/dev/null
}

# Removes what a case left behind outside its own directory (pre-Stage F code
# leaks candidates into /tmp) and stops processes a case started.
f_case_cleanup() {
  local f p
  while IFS= read -r f; do
    [[ "$f" == /tmp/twebproxy-manager.* && -f "$f" ]] && rm -f -- "$f"
  done < <(f_leftovers 2>/dev/null)
  for p in "$F_CASE"/hang.pid "$F_CASE"/linger.pid "$F_CASE"/holder.pid; do
    [[ -f "$p" ]] && kill -KILL "$(<"$p")" 2>/dev/null
  done
  return 0
}

f_hold_lock() { # $1=seconds: another process holds the update lock (pid in holder.pid)
  : > "$F_CASE/run/lock/twebproxy-manager-update.lock"; chmod 0600 "$F_CASE/run/lock/twebproxy-manager-update.lock"
  # The holder process itself becomes the sleep, so killing it releases the lock.
  bash -c 'exec 9>"$1"; flock -x 9; exec sleep "$2"' f-holder "$F_CASE/run/lock/twebproxy-manager-update.lock" "$1" &
  echo "$!" > "$F_CASE/holder.pid"
  disown "$!" 2>/dev/null
  local i
  for ((i = 0; i < 50; i++)); do f_lock_free || return 0; sleep 0.1; done
  return 1
}

f_write_models() {
  cat > "$F_CASE/bin/curl" <<'SH'
#!/bin/bash
# curl model: answers only from $F_REMOTE (see updater-harness.sh).
set -u
out="" fmt="" maxredirs=50 maxsize="" follow=0 fail=0 url=""
while (( $# )); do
  case "$1" in
    -o|--output) out="$2"; shift;;
    -w|--write-out) fmt="$2"; shift;;
    --max-redirs) maxredirs="$2"; shift;;
    --max-filesize) maxsize="$2"; shift;;
    --connect-timeout|--max-time|--retry|-H|--header|--proto|--proto-redir|-A|--user-agent) shift;;
    --fail) fail=1;;
    --location) follow=1;;
    --*) ;;
    -*) [[ "$1" == *f* ]] && fail=1; [[ "$1" == *L* ]] && follow=1;;
    *) url="$1";;
  esac
  shift
done
printf '%s\n' "$url" >> "$F_REMOTE/requests"
[[ ! -e "$F_REMOTE/offline" ]] || { echo 'curl: (6) Could not resolve host (model offline)' >&2; exit 6; }
redirects=0 code=200 file=""
while :; do
  [[ "$url" =~ ^https://[^/]+/ ]] || { echo "curl: (1) Protocol not supported (model): $url" >&2; exit 1; }
  rest="${url#https://}"
  if [[ -f "$F_REMOTE/redirect/$rest" ]]; then
    if (( ! follow )); then code=302; file=""; break; fi
    redirects=$((redirects + 1))
    (( redirects <= maxredirs )) || { echo "curl: (47) Maximum ($maxredirs) redirects followed" >&2; exit 47; }
    url="$(<"$F_REMOTE/redirect/$rest")"
    printf 'redirect-> %s\n' "$url" >> "$F_REMOTE/requests"
    continue
  fi
  file="$F_REMOTE/www/$rest"
  [[ -f "$file" ]] || { code=404; file=""; }
  break
done
if [[ "$code" == 404 ]] && (( fail )); then echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22; fi
fault=""
[[ -z "$file" || ! -f "$F_REMOTE/fault/$rest" ]] || fault="$(<"$F_REMOTE/fault/$rest")"
[[ "$fault" != hang ]] || exec sleep 3600
size=0; [[ -z "$file" ]] || size="$(stat -c %s "$file")"
if [[ -n "$maxsize" ]] && (( size > maxsize )); then echo 'curl: (63) Maximum file size exceeded' >&2; exit 63; fi
emit() {
  if [[ -z "$file" ]]; then [[ "$code" == 404 ]] && printf '404: Not Found'; return 0; fi
  case "$fault" in
    partial|truncate) head -c "$((size / 2))" "$file";;
    *) cat "$file";;
  esac
}
if [[ -n "$out" ]]; then emit > "$out"; else emit; fi
[[ "$fault" != partial ]] || { echo 'curl: (18) transfer closed with outstanding read data remaining' >&2; exit 18; }
if [[ -n "$fmt" ]]; then
  fmt="${fmt//'%{url_effective}'/$url}"; fmt="${fmt//'%{num_redirects}'/$redirects}"; fmt="${fmt//'%{http_code}'/$code}"
  printf "$fmt"
fi
exit 0
SH
  cat > "$F_CASE/bin/mv" <<'SH'
#!/bin/bash
# fault layer: mv onto the path named in $F_CASE/fail-mv-to fails once.
dest="${*: -1}"
if [[ -f "$F_CASE/fail-mv-to" && "$dest" == "$(<"$F_CASE/fail-mv-to")" ]]; then
  rm -f "$F_CASE/fail-mv-to"; echo "mv: cannot move to '$dest': model failure" >&2; exit 1
fi
exec /usr/bin/mv "$@"
SH
  cat > "$F_CASE/bin/install" <<'SH'
#!/bin/bash
# fault: fail-install-backup makes every install into a backup being created fail.
# barrier: the first install into a .twebproxy-stage4 temp file in the directory
# named by $F_CASE/park-install-dir parks until $F_CASE/release exists.
dest="${*: -1}"
if [[ -f "$F_CASE/fail-install-backup" && "$dest" == */update-backups/.incomplete.* ]]; then
  echo "install: cannot create '$dest': model disk failure" >&2; exit 1
fi
if [[ -f "$F_CASE/park-install-dir" && "$(basename -- "$dest")" == .twebproxy-stage4.* \
      && "$(dirname -- "$dest")" == "$(<"$F_CASE/park-install-dir")" ]]; then
  rm -f "$F_CASE/park-install-dir"; : > "$F_CASE/parked"
  while [[ ! -e "$F_CASE/release" ]]; do sleep 0.05; done
fi
exec /usr/bin/install "$@"
SH
  chmod 0755 "$F_CASE"/bin/*
}
