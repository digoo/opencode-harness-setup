#!/usr/bin/env bash
# Verify the harness end to end. Safe to run any time.
set -uo pipefail

fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "=== launchd services ==="
launchctl list 2>/dev/null | grep -qiE "headroom|rtk" \
  && ok "services loaded" || bad "no headroom/rtk launchd service"

echo "=== ports ==="
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -q ":8080" \
  && ok "rtk-proxy on 8080" || bad "rtk-proxy not listening on 8080"
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -q ":8787" \
  && ok "headroom on 8787" || bad "headroom not listening on 8787"

echo "=== chain ==="
headroom_up=$(curl -s -m 5 http://127.0.0.1:8787/readyz 2>/dev/null \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).checks.upstream.url)}catch(e){console.log('none')}})")
[ "$headroom_up" = "http://127.0.0.1:8080" ] \
  && ok "headroom -> rtk-proxy" || bad "headroom upstream is $headroom_up"

rtk_up=$(rtk-proxy config get 2>/dev/null \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).openai_upstream)}catch(e){console.log('none')}})")
[ -n "$rtk_up" ] && [ "$rtk_up" != "none" ] \
  && ok "rtk-proxy upstream = $rtk_up" || bad "rtk-proxy upstream unknown"

echo "=== rtk pipeline ==="
pipeline_out=$(rtk pipeline show 2>&1)
echo "$pipeline_out" | grep -qF "Pipeline: rtk:posthook" \
  && ok "pipeline = rtk:posthook" || bad "pipeline is not rtk:posthook"

echo "=== mcp servers ==="
mcp_out=$(opencode mcp list 2>&1)
echo "$mcp_out" | grep -q "failed" \
  && bad "at least one MCP server failed" \
  || ok "all MCP servers connected"
echo "$mcp_out" | grep "connected" | sed 's/^/  ok   /'

echo "=== plugins ==="
plugin_out=$(opencode plugin list 2>&1)
echo "$plugin_out" | grep -q "rea-guard" \
  && ok "rea-guard loaded" || bad "rea-guard not loaded"
echo "$plugin_out" | grep -q "rtk " \
  && ok "rtk loaded" || bad "rtk not loaded"

echo "=== models live ==="
for m in kpa/gpt-5-6-luna kpa/claude-opus-5-5; do
  out=$(opencode run --model "$m" "reply exactly OK" 2>&1 | tail -n 1)
  [ "$out" = "OK" ] && ok "$m" || bad "$m -> $out"
done

echo "=== savings ==="
rtk gain 2>&1 | grep -E "Tokens saved" | head -n 1
headroom savings 2>&1 | grep -iE "opencode" | head -n 1

echo "=== docs ==="
if [ -f README.md ]; then
  anchor_fail=$(node -e "
const fs=require('fs');
const md=fs.readFileSync('README.md','utf8');
const slug=(t)=>t.toLowerCase().replace(/[^\w\s-]/g,'').trim().replace(/ /g,'-');
const heads=new Set([...md.matchAll(/^#{1,6} (.+)\$/gm)].map(m=>slug(m[1])));
const links=[...new Set([...md.matchAll(/\]\(#([^)]+)\)/g)].map(m=>m[1]))];
const missing=links.filter(l=>!heads.has(l));
if(missing.length){console.log(missing.join(' '));process.exit(1)}
")
  if [ -z "$anchor_fail" ]; then
    ok "all README anchors resolve"
  else
    bad "broken README anchors: $anchor_fail"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fail check(s) failed"
  exit 1
fi
