#!/usr/bin/env bash
# TEST MODEL ONLY, not nft validation. Converts the finite generated rules for
# existing fixtures; real-kernel validation is a separate mandatory gate.
set -Eeuo pipefail
live="${1:?live rules file}"
[[ -s "$live" ]] || exit 1
if [[ -n "${MOCK_NFT_LIVE_JSON:-}" ]]; then cat "$MOCK_NFT_LIVE_JSON"; exit; fi
jq -Rn --argjson pad "${MOCK_NFT_PAD_LINES:-0}" '
  def eqm($l;$r): {match:{op:"==",left:$l,right:$r}};
  def p($p;$f): {payload:{protocol:$p,field:$f}};
  def num: if startswith("0x") then .[2:]|explode|reduce .[] as $c (0;.*16+(if $c<=57 then $c-48 else $c-87 end)) else tonumber end;
  def rule:
    capture("^\\s*ip saddr (?<ip>[0-9.]+) tcp sport (?<port>[0-9]+) (?<rest>.*)$") as $r |
    {rule:{family:"ip",table:"twebproxy_dpi",chain:"output",
      comment:(try ($r.rest|capture("comment \"(?<c>[^\"]+)\"").c) catch ""),
      expr:([eqm(p("ip";"saddr");$r.ip),eqm(p("tcp";"sport");($r.port|tonumber))] +
        (if ($r.rest|test("^tcp flags & \\(fin \\| syn \\| rst \\| ack\\) == \\(syn \\| ack\\) tcp window set [0-9]+ counter")) then
          [eqm({"&":[p("tcp";"flags"),["fin","syn","rst","ack"]]};["syn","ack"]),
           {mangle:{key:p("tcp";"window"),value:($r.rest|capture("window set (?<v>[0-9]+)").v|tonumber)}},{counter:{packets:7,bytes:420}}]
         elif ($r.rest|test("^tcp flags & \\(fin \\| syn \\| rst \\| ack\\) == \\(syn \\| ack\\) tcp option maxseg size set [0-9]+ counter")) then
          [eqm({"&":[p("tcp";"flags"),["fin","syn","rst","ack"]]};["syn","ack"]),
           {mangle:{key:{"tcp option":{name:"maxseg",field:"size"}},value:($r.rest|capture("size set (?<v>[0-9]+)").v|tonumber)}},{counter:{packets:7,bytes:420}}]
         elif ($r.rest|test("^meta mark & ")) then
          ($r.rest|capture("^meta mark & (?<mark>[^ ]+) == (?<zero>[^ ]+) ct reply packets (?<lo>[0-9]+)-(?<hi>[0-9]+) counter queue num (?<q>[0-9]+) bypass")) as $q |
          [eqm({"&":[{meta:{key:"mark"}},($q.mark|num)]};($q.zero|num)),
           eqm({ct:{key:"packets",dir:"reply"}};{range:[($q.lo|tonumber),($q.hi|tonumber)]}),
           {counter:{packets:7,bytes:420}},{queue:{num:($q.q|tonumber),flags:"bypass"}}]
         else [{accept:null}] end))}};
  [inputs] as $lines |
  {nftables:([{metainfo:{json_schema_version:1,version:"fixture",padding:("padding\n" * $pad)}},
             {table:{family:"ip",name:"twebproxy_dpi",handle:1}},
             {chain:{family:"ip",table:"twebproxy_dpi",name:"output",type:"filter",hook:"output",prio:-150,policy:"accept",handle:2}}] +
            [$lines[]|select(test("^\\s*ip saddr "))|rule])}
' < "$live"
