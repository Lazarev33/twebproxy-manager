#!/bin/bash
# Explicit atomic model. Deliberate faults never touch host nft.
set -euo pipefail
root="${BF_TEST_ROOT:?}"
printf '%s\n' "$*" >> "$root/nft.calls"
case "$*" in
  "list table inet twebproxy_guard")
    [[ -f "$root/guard" ]] || exit 1
    printf 'table inet twebproxy_guard { # progname nft\n\tflags owner\n}\n'; exit 0;;
  *"list tables inet")
    [[ ! -e "$root/fail-query" ]] || exit 1
    if [[ -f "$root/live" ]]; then
      printf '{"nftables":[{"table":{"family":"inet","name":"twebproxy_backend"}}]}\n'
    else printf '{"nftables":[]}\n'; fi
    exit 0;;
  *"list table inet twebproxy_backend")
    if [[ -f "$root/fail-query-once" ]]; then rm "$root/fail-query-once"; exit 1; fi
    [[ ! -e "$root/fail-query" && -f "$root/live" ]] || exit 1
    if [[ "$*" != *"-j"* ]]; then cat "$root/live"; exit; fi
    ports="$(sed -n 's/.*dport { \([^}]*\) } drop/\1/p' "$root/live" | tr -d ' ')"
    jq -n --arg ports "$ports" '
      {nftables: ([
        {metainfo:{json_schema_version:1}},
        {table:{family:"inet",name:"twebproxy_backend",handle:1}},
        {chain:{family:"inet",table:"twebproxy_backend",name:"input",type:"filter",hook:"input",prio:-5,policy:"accept",handle:2}}
      ] + (if $ports == "" then [] else [
        {rule:{family:"inet",table:"twebproxy_backend",chain:"input",handle:3,expr:[
          {match:{op:"!=",left:{meta:{key:"iifname"}},right:"lo"}},
          {match:{op:"==",left:{payload:{protocol:"tcp",field:"dport"}},right:{set:($ports|split(",")|map(tonumber))}}},
          {drop:null}
        ]}}
      ] end))}'
    exit 0;;
  "delete table inet twebproxy_backend")
    rm -f "$root/live"; exit 0;;
esac
file="${*: -1}"
[[ -f "$file" ]] || exit 1
[[ ! -f "$root/fail-check" ]] || exit 1
grep -q '^table inet twebproxy_backend {' "$file" || exit 1
grep -q '^add table inet twebproxy_backend$' "$file" || {
  # Only the old helper's separate load reaches this branch.
  [[ ! -f "$root/fail-apply" ]] || exit 1
  cp "$file" "$root/live"; exit 0
}
grep -q '^delete table inet twebproxy_backend$' "$file" || exit 1
[[ "$*" != *"-c"* ]] || exit 0
if [[ -e "$root/fail-apply" ]]; then rm -f "$root/fail-apply"; exit 1; fi
sed -n '/^table inet twebproxy_backend {/,$p' "$file" > "$root/live.new"
mv "$root/live.new" "$root/live"
if [[ -f "$root/fail-post-verify" ]]; then
  rm "$root/fail-post-verify"; touch "$root/fail-query-once"
fi
if [[ -f "$root/fail-after-commit" ]]; then
  # The kernel committed, but the client reports failure (e.g. timeout kill).
  rm "$root/fail-after-commit"
  [[ ! -f "$root/fail-rollback" ]] || mv "$root/fail-rollback" "$root/fail-apply"
  exit 124
fi
