#!/usr/bin/env bash
# Verify the harness end to end. Safe to run any time.
#
# NOTE: matching is done with bash pattern tests, not `grep -q`.
# `grep -q` exits on first match, which SIGPIPEs the upstream command; with
# `set -o pipefail` that turns a successful match into a pipeline failure.
# Capture into a variable first, then match in the shell.
set -uo pipefail

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# has <text> <pattern> -> 0 when the pattern appears in the text
has() { [[ "$1" == *"$2"* ]]; }

echo "=== launchd services ==="
svc=$(launchctl list 2>/dev/null)
if has "$svc" "headroom" || has "$svc" "rtk"; then
  ok "services loaded"
else
  bad "no headroom/rtk launchd service"
fi

echo "=== ports ==="
listeners=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null)
has "$listeners" ":8080" && ok "rtk-proxy on 8080" || bad "rtk-proxy not listening on 8080"
has "$listeners" ":8787" && ok "headroom on 8787" || bad "headroom not listening on 8787"

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
has "$pipeline_out" "Pipeline: rtk:posthook" \
  && ok "pipeline = rtk:posthook" || bad "pipeline is not rtk:posthook"

echo "=== headroom kompress ==="
warmup=$(curl -s -m 10 http://127.0.0.1:8787/debug/warmup 2>/dev/null)
if has "$warmup" '"kompress":{"status":"loaded"'; then
  ok "kompress loaded"
else
  bad "kompress not loaded"
fi

echo "=== mcp servers ==="
mcp_out=$(opencode mcp list 2>&1)
if has "$mcp_out" "failed"; then
  bad "at least one MCP server failed"
  echo "$mcp_out" | grep "failed" | sed 's/^/  FAIL /'
else
  ok "all MCP servers connected"
fi
echo "$mcp_out" | grep "connected" | sed 's/^/  ok   /'

echo "=== plugins ==="
plugin_out=$(opencode plugin list 2>&1)
has "$plugin_out" "rea-guard" && ok "rea-guard loaded" || bad "rea-guard not loaded"
has "$plugin_out" "rtk" && ok "rtk loaded" || bad "rtk not loaded"

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
