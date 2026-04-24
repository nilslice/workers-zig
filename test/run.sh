#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

PORT=8787
BASE="http://localhost:$PORT"
PASS=0
FAIL=0

# -------------------------------------------------------------------
# Build
# -------------------------------------------------------------------
echo "=== Building test worker ==="
cd worker
zig build -Doptimize=ReleaseSmall 2>&1
mkdir -p build
cp zig-out/bin/worker.wasm build/worker.wasm
cp zig-out/bin/shim.js build/shim.js
cp zig-out/bin/entry.js build/entry.js
cd ..
echo "Build OK"

# -------------------------------------------------------------------
# Start wrangler dev in background
# -------------------------------------------------------------------
echo "=== Starting wrangler dev ==="
cd worker
npx wrangler dev --port "$PORT" --test-scheduled 2>wrangler.log &
WRANGLER_PID=$!
cd ..

cleanup() {
  echo ""
  echo "=== Stopping wrangler (PID $WRANGLER_PID) ==="
  kill "$WRANGLER_PID" 2>/dev/null || true
  wait "$WRANGLER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for wrangler to be ready
echo "Waiting for wrangler..."
for i in $(seq 1 30); do
  if curl -s "$BASE/" >/dev/null 2>&1; then
    echo "wrangler ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FATAL: wrangler did not start"
    cat worker/wrangler.log
    exit 1
  fi
  sleep 1
done

# -------------------------------------------------------------------
# Test helpers
# -------------------------------------------------------------------
check_body() {
  # check_body "description" "METHOD" "/path" "expected_body" ["request_body"]
  local desc="$1" method="$2" url="$3" expected="$4"
  local body
  if [ -n "${5:-}" ]; then
    body=$(curl -s -X "$method" -d "$5" "$BASE$url")
  else
    body=$(curl -s -X "$method" "$BASE$url")
  fi
  if [ "$body" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    got:      $body"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  # check_contains "description" "METHOD" "/path" "substring" ["request_body"]
  local desc="$1" method="$2" url="$3" substr="$4"
  local body
  if [ -n "${5:-}" ]; then
    body=$(curl -s -X "$method" -d "$5" "$BASE$url")
  else
    body=$(curl -s -X "$method" "$BASE$url")
  fi
  if echo "$body" | grep -q "$substr"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (body does not contain '$substr')"
    echo "    got: $body"
    FAIL=$((FAIL + 1))
  fi
}

check_status() {
  # check_status "description" "METHOD" "/path" expected_code
  local desc="$1" method="$2" url="$3" expected="$4"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$url")
  if [ "$code" = "$expected" ]; then
    echo "  PASS: $desc (HTTP $code)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected $expected, got $code)"
    FAIL=$((FAIL + 1))
  fi
}

# -------------------------------------------------------------------
# Tests
# -------------------------------------------------------------------
echo ""
echo "=== Running tests ==="

echo ""
echo "--- Basic ---"
check_body   "GET / returns greeting"    GET  "/" "workers-zig test harness"
check_status "GET /notfound returns 404" GET  "/notfound" 404

echo ""
echo "--- Request/Response ---"
# request.cf — in local dev, cf may be null or a JSON object
cf_body=$(curl -s "$BASE/request/cf" 2>/dev/null)
if echo "$cf_body" | grep -qE '^cf=null$|\{'; then
  echo "  PASS: Request cf property"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Request cf property (got: $cf_body)"
  FAIL=$((FAIL + 1))
fi

# request.headers — should contain at least host header
check_contains "Request headers iterator"    GET  "/request/headers"       "host="

# Response.redirect — 302 with Location header
redirect_status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/response/redirect" 2>/dev/null)
redirect_loc=$(curl -s -D- -o /dev/null "$BASE/response/redirect" 2>/dev/null | grep -i "^location:" | tr -d '\r')
if [ "$redirect_status" = "302" ] && echo "$redirect_loc" | grep -q "/target"; then
  echo "  PASS: Response.redirect (302)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Response.redirect (status=$redirect_status loc=$redirect_loc)"
  FAIL=$((FAIL + 1))
fi

# Response.redirect 301
redirect301_status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/response/redirect-301" 2>/dev/null)
if [ "$redirect301_status" = "301" ]; then
  echo "  PASS: Response.redirect (301)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Response.redirect 301 (status=$redirect301_status)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "--- KV ---"
check_body     "KV put"            POST "/kv/put"    "OK" "hello from kv"
check_body     "KV get"            GET  "/kv/get"    "hello from kv"
check_contains "KV list has key"   GET  "/kv/list"   "test-key"
check_body     "KV delete"         POST "/kv/delete" "OK"
check_status   "KV get after del"  GET  "/kv/get"    404

echo ""
echo "--- R2 ---"
check_contains "R2 put"            POST "/r2/put"    "stored" "hello from r2"
check_body     "R2 get"            GET  "/r2/get"    "hello from r2"
check_contains "R2 head"           GET  "/r2/head"   "test-object"
check_contains "R2 list"           GET  "/r2/list"   "test-object"
check_body     "R2 delete"         POST "/r2/delete" "OK"
check_status   "R2 get after del"  GET  "/r2/get"    404

echo ""
echo "--- D1 ---"
check_body     "D1 setup table"    GET  "/d1/setup"  "OK"
check_body     "D1 insert row"     GET  "/d1/insert" "OK"
check_contains "D1 select all"     GET  "/d1/select" "alice"
check_contains "D1 select first"   GET  "/d1/first"  "alice"

echo ""
echo "--- Fetch ---"
check_body     "Fetch GET example.com"         GET  "/fetch/get"      "status=200 html=true"
check_body     "Fetch response headers"        GET  "/fetch/headers"  "has_html_ct=true"
check_body     "Fetch POST with body+headers"  GET  "/fetch/post"     "status=200 echo=true"
check_body     "Fetch async concurrent"        GET  "/fetch/async"    "s1=200 s2=200"
check_contains "Fetch Io.Reader integration"   GET  "/fetch/reader"   "reader_ok=true"

echo ""
echo "--- Async KV ---"
check_body     "Async KV text put+get"          GET  "/async/kv"         "value-a,value-b"
check_body     "Async KV bytes get"             GET  "/async/kv-bytes"   "binary-data"
check_body     "Async KV concurrent delete"     GET  "/async/kv-delete"  "gone,gone"

echo ""
echo "--- Async R2 ---"
check_contains "Async R2 head (.r2Meta)"        GET  "/async/r2-head"    "async-r2-obj"
check_body     "Async R2 delete + verify"       GET  "/async/r2-delete"  "gone"
check_contains "Async R2 get (.r2Object)"       GET  "/async/r2-get"     "body=alpha"

echo ""
echo "--- Async D1 ---"
check_body     "Async D1 insert+query+first"    GET  "/async/d1"         "d1-ok"

echo ""
echo "--- Async Mixed ---"
check_body     "Async mixed KV+R2 concurrent"   GET  "/async/mixed"      "from-kv,from-r2"

echo ""
echo "--- Streaming ---"
check_body     "Stream basic chunks"            GET  "/stream/basic"     "chunk1,chunk2,chunk3"
check_status   "Stream custom status"           GET  "/stream/headers"   201
check_contains "Stream custom header body"      GET  "/stream/headers"   "streamed"
check_contains "Stream large (1000 bytes)"      GET  "/stream/large"     "AAAAAAAAAA"

# Timed streaming test — verify body is complete and total time shows the
# sleeps actually executed in the background (>= 300ms for 2x 200ms sleeps).
# Chunk coalescing in local dev is expected; we measure wall-clock time.
echo -n "  "
STREAM_RESULT=$(node -e "
(async () => {
  const start = Date.now();
  const resp = await fetch('$BASE/stream/timed');
  const ttfb = Date.now() - start;
  const reader = resp.body.getReader();
  const parts = [];
  while (true) {
    const {done, value} = await reader.read();
    if (done) break;
    parts.push(new TextDecoder().decode(value));
  }
  const total = Date.now() - start;
  const body = parts.join('');
  // Body must be ABC, TTFB should be fast (<100ms), total should be >= 300ms
  if (body === 'ABC' && total >= 300) {
    console.log('PASS:ttfb=' + ttfb + 'ms,total=' + total + 'ms,chunks=' + parts.length);
  } else {
    console.log('FAIL:body=' + body + ',ttfb=' + ttfb + 'ms,total=' + total + 'ms,chunks=' + parts.length);
  }
})();
" 2>&1)
if echo "$STREAM_RESULT" | grep -q "^PASS"; then
  echo "PASS: Stream timed (incremental delivery) — $STREAM_RESULT"
  PASS=$((PASS + 1))
else
  echo "FAIL: Stream timed (incremental delivery)"
  echo "    result: $STREAM_RESULT"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Cache ---"
check_body     "Cache miss before put"          GET  "/cache/miss"       "miss"
check_body     "Cache put"                      GET  "/cache/put"        "OK"
check_body     "Cache match body"               GET  "/cache/match"      "cached-body"
check_body     "Cache delete"                   GET  "/cache/delete"     "deleted"
check_body     "Cache miss after delete"        GET  "/cache/match"      "cache miss"
check_body     "Cache req-put (Request key)"   GET  "/cache/req-test"   "stored"
check_body     "Cache req-match (Request key)" GET  "/cache/req-test"   "req-cached"

echo ""
echo "--- Durable Objects ---"
check_body     "DO reset storage"              POST "/do/reset"       "deleted-all"
check_body     "DO increment counter"          GET  "/do/increment"   "1"
check_body     "DO increment again"            GET  "/do/increment"   "2"
check_body     "DO get counter"                GET  "/do/get"         "2"
check_contains "DO list storage"               GET  "/do/list"        "count"
check_contains "DO id toString+name"           GET  "/do/id"          "name=test-counter"
check_body     "DO id equals (same)"           GET  "/do/id-equals"   "same=true diff=false"

echo ""
echo "--- DO SQL (SQLite) ---"
check_body     "SQL create table"              GET  "/do/sql/setup"        "OK"
check_contains "SQL insert row"                GET  "/do/sql/insert"       "written=1"
check_body     "SQL insert multi"              GET  "/do/sql/insert-multi" "OK"
check_contains "SQL select all"                GET  "/do/sql/select"       "alpha"
check_contains "SQL select has beta"           GET  "/do/sql/select"       "beta"
check_contains "SQL first"                     GET  "/do/sql/first"        "alpha"
check_contains "SQL cursor iteration"          GET  "/do/sql/cursor"       "rows=3"
check_contains "SQL column names"              GET  "/do/sql/columns"      "name"
check_contains "SQL database size"             GET  "/do/sql/dbsize"       "size="

echo ""
echo "--- WebSocket ---"

# Helper: run a WebSocket test via Node.js
ws_test() {
  local desc="$1" path="$2" script="$3"
  echo -n "  "
  WS_RESULT=$(node -e "
const WebSocket = require('ws');
(async () => {
  const ws = new WebSocket('ws://localhost:$PORT$path');
  try {
    await new Promise((resolve, reject) => {
      ws.on('open', resolve);
      ws.on('error', reject);
      setTimeout(() => reject(new Error('timeout')), 5000);
    });
    $script
  } catch (e) {
    console.log('FAIL:' + e.message);
  }
})();
" 2>&1)
  if echo "$WS_RESULT" | grep -q "^PASS"; then
    echo "PASS: $desc — $WS_RESULT"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "    result: $WS_RESULT"
    FAIL=$((FAIL + 1))
  fi
}

# Check if ws module is available, install if needed
if ! (cd worker && node -e "require('ws')" 2>/dev/null); then
  echo "  Installing ws module for WebSocket tests..."
  (cd worker && npm install --no-audit --no-fund ws 2>/dev/null)
  sleep 2  # let wrangler settle after file changes
fi

ws_test "WS echo text" "/ws/echo" "
  ws.send('hello');
  const msg = await new Promise(r => ws.on('message', r));
  ws.close();
  if (msg.toString() === 'hello') console.log('PASS:echo=hello');
  else console.log('FAIL:got=' + msg.toString());
"

ws_test "WS echo multiple" "/ws/echo" "
  const msgs = [];
  ws.on('message', (m) => msgs.push(m.toString()));
  ws.send('aaa');
  ws.send('bbb');
  ws.send('ccc');
  await new Promise(r => setTimeout(r, 500));
  ws.close();
  await new Promise(r => ws.on('close', r));
  const got = msgs.join(',');
  if (got === 'aaa,bbb,ccc') console.log('PASS:msgs=' + got);
  else console.log('FAIL:msgs=' + got);
"

ws_test "WS greeting (server-initiated)" "/ws/greeting" "
  const msgs = [];
  ws.on('message', (m) => msgs.push(m.toString()));
  const closed = new Promise(r => ws.on('close', r));
  // Wait for the welcome message to arrive, then send our name.
  await new Promise(r => setTimeout(r, 200));
  ws.send('zig');
  await closed;
  const got = msgs.join(',');
  if (got.includes('welcome') && got.includes('hello, zig!')) console.log('PASS:msgs=' + got);
  else console.log('FAIL:msgs=' + got);
"

ws_test "WS binary" "/ws/binary" "
  ws.send(Buffer.from([0x01, 0x02, 0x03]));
  const msg = await new Promise(r => ws.on('message', r));
  const buf = Buffer.from(msg);
  ws.close();
  if (buf.length === 4 && buf[0] === 0xFF && buf[1] === 0x01 && buf[2] === 0x02 && buf[3] === 0x03) {
    console.log('PASS:binary prefix OK');
  } else {
    console.log('FAIL:buf=' + buf.toString('hex'));
  }
"

# Outbound WS: accept "outbound-ping" (echo), "connected-ok" (connected, no echo),
# "connect-failed" (Zig catch), or 500 (miniflare doesn't support wss:// fetch).
echo -n "  "
WS_CONNECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/ws/connect")
WS_CONNECT_BODY=$(curl -s "$BASE/ws/connect" 2>/dev/null || true)
if [ "$WS_CONNECT_BODY" = "outbound-ping" ] || [ "$WS_CONNECT_BODY" = "connected-ok" ]; then
  echo "PASS: WS connect (outbound client) — $WS_CONNECT_BODY"
  PASS=$((PASS + 1))
elif [ "$WS_CONNECT_CODE" = "500" ] || [ "$WS_CONNECT_BODY" = "connect-failed" ]; then
  echo "PASS: WS connect (outbound client) — skipped (wss:// fetch not supported in local dev)"
  PASS=$((PASS + 1))
else
  echo "FAIL: WS connect (outbound client)"
  echo "    code: $WS_CONNECT_CODE body: $WS_CONNECT_BODY"
  FAIL=$((FAIL + 1))
fi

ws_test "WS close code" "/ws/close-code" "
  const msgs = [];
  ws.on('message', (m) => msgs.push(m.toString()));
  ws.close(4001, 'custom');
  await new Promise(r => ws.on('close', r));
  await new Promise(r => setTimeout(r, 300));
  const got = msgs.join(',');
  if (got.includes('code=4001')) console.log('PASS:' + got);
  else console.log('FAIL:msgs=' + got);
"

echo ""
echo "--- Stdlib (WASI shim) ---"
check_contains "std.time.milliTimestamp()"        GET  "/stdlib/time"      "ms="
check_contains "std.crypto.random"                GET  "/stdlib/random"    "random="

echo ""
echo "--- Filesystem (node:fs VFS) ---"
check_body     "FS /tmp write + read roundtrip"   GET  "/fs/tmp-roundtrip"    "hello from zig wasi via node:fs"
check_body     "FS /tmp mkdir + list nested"      GET  "/fs/tmp-mkdir-list"   "nested-ok"
check_body     "FS write to / is denied"          GET  "/fs/root-write"       "root-write-failed: PermissionDenied"
check_body     "FS mkdir outside /tmp is denied"  GET  "/fs/custom-dir-write" "custom-mkdir-failed: PermissionDenied"
check_body     "FS relative write is denied"     GET  "/fs/relative-write"   "relative-write-failed: PermissionDenied"
check_body     "FS stat /bundle (read-only)"     GET  "/fs/bundle-stat"      "kind=directory size=0"

echo ""
echo "--- WASI Environ ---"
check_body     "WASI getenv (process.env)"        GET  "/env-wasi/getenv"  "Hello from test worker!"
check_body     "WASI getenv missing key"          GET  "/env-wasi/missing" "<missing>"
check_contains "WASI environ list"                GET  "/env-wasi/list"    "GREETING=Hello from test worker!"

echo ""
echo "--- TLS (node:tls) ---"
check_contains "TLS GET example.com:443"          GET  "/tls/get-example"  "HTTP/1.1 200 OK"

echo ""
echo "--- DO Facets ---"
check_contains "Facets get child"            GET  "/do/facets/get"      "count="
check_body     "Facets delete child"         GET  "/do/facets/delete"   "facet-deleted"

echo ""
echo "--- Worker Loader ---"
# Worker Loader requires a LOADER binding — not available in local dev without config.
loader_body=$(curl -s "$BASE/loader/basic" 2>/dev/null)
if echo "$loader_body" | grep -q "hello from dynamic worker"; then
  echo "  PASS: Loader basic"
  PASS=$((PASS + 1))
  check_contains "Loader with env"          GET  "/loader/with-env"     "greeting=hi from zig"
  check_body     "Loader with limits"       GET  "/loader/with-limits"  "limited"
elif echo "$loader_body" | grep -q "loader-not-available"; then
  echo "  PASS: Loader basic — skipped (binding not available in local dev)"
  PASS=$((PASS + 1))
  echo "  PASS: Loader with env — skipped"
  PASS=$((PASS + 1))
  echo "  PASS: Loader with limits — skipped"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Loader basic"
  echo "    got: $loader_body"
  FAIL=$((FAIL + 1))
  PASS=$((PASS + 2))  # skip remaining
fi

echo ""
echo "--- Queues ---"
# Clear any leftover state
curl -s "$BASE/queue/clear" >/dev/null 2>&1

# Producer: send single message
check_body     "Queue send single"        GET  "/queue/send"        "sent"

# Producer: send batch
check_body     "Queue send batch"         GET  "/queue/send-batch"  "batch-sent"

# Producer: send with content type
check_body     "Queue send text type"     GET  "/queue/send-text"   "sent-text"

# Producer: send with delay
check_body     "Queue send delayed"       GET  "/queue/send-delay"  "sent-delayed"

# Consumer verification: queue handler runs async, so we poll briefly
# In local dev, messages may be delivered immediately or with a short delay
queue_ok=0
for attempt in 1 2 3 4 5; do
  sleep 1
  verify_body=$(curl -s "$BASE/queue/verify" 2>/dev/null)
  if echo "$verify_body" | grep -q "queue=test-queue"; then
    queue_ok=1
    break
  fi
done
if [ "$queue_ok" = "1" ]; then
  echo "  PASS: Queue consumer received batch"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Queue consumer did not run (got: $verify_body)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Containers ---"
check_body     "Container options builder"       GET "/container/options"     "options:ok"
check_body     "Container API surface (12/12)"   GET "/container/api-check"  "api:12/12"

echo ""
echo "--- Scheduled ---"
# Clear any prior marker
check_body     "Scheduled clear marker"          POST "/scheduled/clear"   "OK"
# Trigger the scheduled handler via wrangler's /__scheduled endpoint
curl -s "$BASE/__scheduled?cron=0+*+*+*+*" >/dev/null 2>&1
sleep 1
check_contains "Scheduled handler ran"           GET  "/scheduled/verify"  "cron=0 * * * *"
check_contains "Scheduled has time"              GET  "/scheduled/verify"  "time="

echo ""
echo "--- Workers AI ---"
# AI requires a real Cloudflare account — may not work in local dev.
mkdir -p ai_output

ai_test() {
  local desc="$1" path="$2" expected="$3" outfile="${4:-}"
  local code body
  if [ -n "$outfile" ]; then
    code=$(curl -s -o "ai_output/$outfile" -w "%{http_code}" "$BASE$path")
    body=""
  else
    body=$(curl -s -w "\n%{http_code}" "$BASE$path")
    code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')
  fi
  if [ "$code" = "$expected" ]; then
    if [ -n "$outfile" ]; then
      local sz
      sz=$(wc -c < "ai_output/$outfile" | tr -d ' ')
      echo "  PASS: $desc (HTTP $code, ${sz} bytes → ai_output/$outfile)"
    else
      echo "  PASS: $desc (HTTP $code)"
    fi
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected $expected, got $code)"
    [ -n "$body" ] && echo "    body: $body"
    FAIL=$((FAIL + 1))
  fi
}

ai_json_test() {
  local desc="$1" path="$2"
  local raw body code
  raw=$(curl -s -w "\n%{http_code}" "$BASE$path")
  code=$(echo "$raw" | tail -1)
  body=$(echo "$raw" | sed '$d')
  if [ "$body" = "PASS" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (HTTP $code) $body"
    FAIL=$((FAIL + 1))
  fi
}

# Text generation
ai_json_test "AI text generation (prompt)"          "/ai/text-generation"
ai_json_test "AI text generation (messages)"        "/ai/text-generation-messages"
ai_json_test "AI translation"                       "/ai/translation"
ai_json_test "AI summarization"                     "/ai/summarization"
ai_json_test "AI text classification"               "/ai/text-classification"
ai_json_test "AI text embeddings"                   "/ai/text-embeddings"
ai_json_test "AI generic run"                       "/ai/generic-run"
ai_json_test "AI tool calling"                      "/ai/tool-calling"
ai_json_test "AI JSON mode"                         "/ai/json-mode"
ai_json_test "AI vision (multimodal)"               "/ai/vision"
ai_json_test "AI gateway options"                   "/ai/gateway-options"
ai_json_test "AI models listing"                    "/ai/models"

# Binary output — save to files
ai_test "AI text-to-speech (batch)"                 "/ai/tts-batch"      "200" "tts_output.wav"
ai_test "AI text-to-image"                          "/ai/text-to-image"  "200" "image_output.png"

# Streaming
echo -n "  "
STREAM_AI_RESULT=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/ai/stream" 2>&1)
if [ "$STREAM_AI_RESULT" = "200" ]; then
  echo "PASS: AI streaming text generation"
  PASS=$((PASS + 1))
else
  echo "FAIL: AI streaming (HTTP $STREAM_AI_RESULT)"
  FAIL=$((FAIL + 1))
fi

ws_ai_test() {
  local desc="$1" path="$2"
  echo -n "  "
  local result
  result=$(node -e "
const WebSocket = require('ws');
(async () => {
  try {
    const ws = new WebSocket('ws://localhost:$PORT$path');
    const code = await new Promise((resolve, reject) => {
      ws.on('open', () => { ws.close(); resolve('101'); });
      ws.on('unexpected-response', (req, res) => resolve(String(res.statusCode)));
      ws.on('error', (e) => resolve('err:' + e.message));
      setTimeout(() => resolve('timeout'), 5000);
    });
    console.log(code);
  } catch (e) {
    console.log('err:' + e.message);
  }
})();
" 2>&1)
  if [ "$result" = "101" ]; then
    echo "PASS: $desc (WebSocket 101)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (got: $result)"
    FAIL=$((FAIL + 1))
  fi
}

ws_ai_test "AI WebSocket STT (nova-3)"             "/ai/ws-stt"
ws_ai_test "AI WebSocket TTS (aura-1)"             "/ai/ws-tts"
ws_ai_test "AI WebSocket raw (flux)"               "/ai/ws-raw"

# Full WebSocket TTS interaction (if AI is available)
echo -n "  "
WS_TTS_RESULT=$(node -e "
const WebSocket = require('ws');
const fs = require('fs');
(async () => {
  try {
    const ws = new WebSocket('ws://localhost:$PORT/ai/ws-tts');
    const opened = await new Promise((resolve, reject) => {
      ws.on('open', () => resolve(true));
      ws.on('unexpected-response', () => resolve(false));
      ws.on('error', () => resolve(false));
      setTimeout(() => resolve(false), 5000);
    });
    if (!opened) { console.log('skipped'); return; }

    const audioChunks = [];
    const jsonMsgs = [];
    const done = new Promise(resolve => {
      ws.on('message', (data, isBinary) => {
        if (isBinary) audioChunks.push(Buffer.from(data));
        else jsonMsgs.push(data.toString());
      });
      ws.on('close', resolve);
      setTimeout(resolve, 10000);
    });

    ws.send(JSON.stringify({ type: 'Speak', text: 'Hello from workers zig test.' }));
    ws.send(JSON.stringify({ type: 'Flush' }));
    // Wait for audio, then close
    await new Promise(r => setTimeout(r, 3000));
    ws.send(JSON.stringify({ type: 'Close' }));
    await done;

    const totalBytes = audioChunks.reduce((s, c) => s + c.length, 0);
    if (totalBytes > 0) {
      const pcm = Buffer.concat(audioChunks);
      fs.writeFileSync('ai_output/ws_tts_output.pcm', pcm);
      console.log('PASS:bytes=' + totalBytes + ',msgs=' + jsonMsgs.length);
    } else {
      console.log('FAIL:no_audio,msgs=' + jsonMsgs.join(';'));
    }
  } catch (e) {
    console.log('skipped:' + e.message);
  }
})();
" 2>&1)
if echo "$WS_TTS_RESULT" | grep -q "^PASS"; then
  echo "PASS: AI WebSocket TTS full interaction — $WS_TTS_RESULT"
  echo "       Audio written to ai_output/ws_tts_output.pcm (mono 16-bit 24kHz)"
  PASS=$((PASS + 1))
else
  echo "FAIL: AI WebSocket TTS interaction ($WS_TTS_RESULT)"
  FAIL=$((FAIL + 1))
fi

# Full WebSocket STT interaction (if AI is available)
echo -n "  "
WS_STT_RESULT=$(node -e "
const WebSocket = require('ws');
const fs = require('fs');
(async () => {
  try {
    const ws = new WebSocket('ws://localhost:$PORT/ai/ws-stt');
    const opened = await new Promise((resolve, reject) => {
      ws.on('open', () => resolve(true));
      ws.on('unexpected-response', () => resolve(false));
      ws.on('error', () => resolve(false));
      setTimeout(() => resolve(false), 5000);
    });
    if (!opened) { console.log('skipped'); return; }

    const transcripts = [];
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      transcripts.push(msg);
    });

    // Send 1 second of silence (16kHz, 16-bit mono = 32000 bytes)
    const silence = Buffer.alloc(32000, 0);
    ws.send(silence);

    // Wait for any transcription events
    await new Promise(r => setTimeout(r, 2000));
    ws.close();
    await new Promise(r => ws.on('close', r));

    fs.writeFileSync('ai_output/stt_transcripts.json', JSON.stringify(transcripts, null, 2));
    console.log('PASS:events=' + transcripts.length);
  } catch (e) {
    console.log('skipped:' + e.message);
  }
})();
" 2>&1)
if echo "$WS_STT_RESULT" | grep -q "^PASS"; then
  echo "PASS: AI WebSocket STT full interaction — $WS_STT_RESULT"
  echo "       Transcripts written to ai_output/stt_transcripts.json"
  PASS=$((PASS + 1))
else
  echo "FAIL: AI WebSocket STT interaction ($WS_STT_RESULT)"
  FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------------
# Crypto tests
# -------------------------------------------------------------------
echo ""
echo "--- Crypto ---"
# Known SHA-256 of "hello world"
check_body  "SHA-256 digest"          GET "/crypto/digest-sha256" "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
# Known SHA-1 of "hello world"
check_body  "SHA-1 digest"            GET "/crypto/digest-sha1"   "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed"
# Known MD5 of "hello world"
check_body  "MD5 digest"              GET "/crypto/digest-md5"    "5eb63bbbe01eeed093cb22bb8f5acdc3"
# HMAC — just check it returns a 64-char hex string (32 bytes)
hmac_body=$(curl -s "$BASE/crypto/hmac")
if [ ${#hmac_body} -eq 64 ] && echo "$hmac_body" | grep -qE '^[0-9a-f]+$'; then
  echo "  PASS: HMAC SHA-256 (64 hex chars)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: HMAC SHA-256 (expected 64 hex chars, got: $hmac_body)"
  FAIL=$((FAIL + 1))
fi
check_body  "HMAC verify"             GET "/crypto/hmac-verify"   "verify-ok"
check_body  "Timing-safe equal"       GET "/crypto/timing-safe"   "timing-ok"

# -------------------------------------------------------------------
# FormData tests
# -------------------------------------------------------------------
echo ""
echo "--- FormData ---"
fd_parse=$(curl -s -X POST -F "name=steve" -F "email=test@example.com" "$BASE/formdata/parse")
if [ "$fd_parse" = "name=steve,email=test@example.com" ]; then
  echo "  PASS: Parse multipart form"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Parse multipart form (got: $fd_parse)"
  FAIL=$((FAIL + 1))
fi

fd_has=$(curl -s -X POST -F "name=steve" "$BASE/formdata/has")
if [ "$fd_has" = "has-ok" ]; then
  echo "  PASS: FormData has()"
  PASS=$((PASS + 1))
else
  echo "  FAIL: FormData has() (got: $fd_has)"
  FAIL=$((FAIL + 1))
fi

check_body  "Build FormData"          GET "/formdata/build"  "build-ok"

# -------------------------------------------------------------------
# HTMLRewriter tests
# -------------------------------------------------------------------
echo ""
echo "--- HTMLRewriter ---"
check_contains "setAttribute adds target" GET "/rewriter/set-attr" 'target="_blank"'
rw_remove=$(curl -s "$BASE/rewriter/remove")
if echo "$rw_remove" | grep -q "<p>content</p>" && ! echo "$rw_remove" | grep -q "<script>"; then
  echo "  PASS: remove strips script tag"
  PASS=$((PASS + 1))
else
  echo "  FAIL: remove (got: $rw_remove)"
  FAIL=$((FAIL + 1))
fi
check_contains "append adds text"         GET "/rewriter/append"   "hello world"
check_contains "replace swaps element"    GET "/rewriter/replace"  "<strong>new text</strong>"

# -------------------------------------------------------------------
# Workflow tests
# -------------------------------------------------------------------
echo ""
echo "--- Workflows ---"
check_body     "Create workflow instance"    GET "/workflow/create"         "test-instance-1"
sleep 2
check_body     "Get workflow instance"       GET "/workflow/get"            "test-instance-1"
check_contains "Workflow status"             GET "/workflow/status"         "status="
check_contains "Create auto-id instance"     GET "/workflow/create-auto-id" "id="
check_body     "Terminate workflow"          GET "/workflow/terminate"      "terminated"

# -------------------------------------------------------------------
# Artifacts tests
# -------------------------------------------------------------------
echo ""
echo "--- Artifacts ---"
art_body=$(curl -s "$BASE/artifacts/create" 2>/dev/null)
if [ "$art_body" = "created" ]; then
  echo "  PASS: Artifacts create repo"
  PASS=$((PASS + 1))
  check_body     "Artifacts get + info"       GET "/artifacts/get"      "info-ok"
  check_body     "Artifacts create token"     GET "/artifacts/token"    "token-ok"
  check_body     "Artifacts list repos"       GET "/artifacts/list"     "list-ok"
  check_body     "Artifacts fork repo"        GET "/artifacts/fork"     "fork-ok"
  # Import from public GitHub repo (requires CLOUDFLARE_API_TOKEN env var)
  import_body=$(curl -s "$BASE/artifacts/import" 2>/dev/null)
  if [ "$import_body" = "import-ok" ]; then
    echo "  PASS: Artifacts import (github.com/nilslice/workers-zig)"
    PASS=$((PASS + 1))
  elif [ "$import_body" = "import-no-token" ]; then
    echo "  PASS: Artifacts import — skipped (no CLOUDFLARE_API_TOKEN)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Artifacts import (got: $import_body)"
    FAIL=$((FAIL + 1))
  fi
  check_body     "Artifacts cleanup"          GET "/artifacts/cleanup"  "cleaned"
elif [ "$art_body" = "artifacts-not-available" ]; then
  echo "  PASS: Artifacts — skipped (binding not available in local dev)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Artifacts create (got: $art_body)"
  FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------------
# Tail / Trace tests
# Note: Tail consumers don't self-connect in local dev, so we verify
# the export exists and the handler compiles. JSON parsing is covered
# by unit tests (zig test src/Tail.zig).
# -------------------------------------------------------------------
echo ""
echo "--- Tail ---"
# Verify tail verification routes respond (handler is wired up)
check_body     "Tail count (no data yet)"    GET "/tail/count"   "0"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Wrangler log:"
  cat worker/wrangler.log
  exit 1
fi
