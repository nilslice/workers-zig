/**
 * workers-zig JS shim
 *
 * ES-module entry point for Cloudflare Workers.  Instantiates the Zig-compiled
 * Wasm module using JSPI (JS Promise Integration) so that Zig code can call
 * async Workers APIs (KV, R2, D1 …) as ordinary synchronous extern functions.
 *
 * If JSPI is not available, falls back to non-JSPI mode (async bindings will
 * throw at runtime).
 */
import wasm from "./worker.wasm";
import { connect as _socketConnect } from "cloudflare:sockets";
import { DurableObject as _DurableObjectBase, WorkflowEntrypoint as _WorkflowBase } from "cloudflare:workers";

// ---------------------------------------------------------------------------
// Handle table
// ---------------------------------------------------------------------------
const _h = new Map();
let _n = 1;
function store(o) { const id = _n++; _h.set(id, o); return id; }
function get(id)  { return _h.get(id); }
function drop(id) { _h.delete(id); }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
let _inst = null;
function mem() { return _inst.exports.memory; }

// Async operation queue – filled by non-suspending schedulers, drained by flush.
let _asyncPending = [];

// Streaming response – when Wasm starts a stream, this promise resolves so the
// JS fetch handler can return the Response before the Wasm handler finishes.
let _streamResolve = null;

// WebSocket – similar early-return mechanism for 101 Switching Protocols.
let _wsResolve = null;

function readStr(ptr, len) {
  return new TextDecoder().decode(new Uint8Array(mem().buffer, ptr, len));
}

const encoder = new TextEncoder();

// ---------------------------------------------------------------------------
// Detect JSPI support
// ---------------------------------------------------------------------------
const HAS_JSPI = typeof WebAssembly.Suspending === "function"
              && typeof WebAssembly.promising === "function";

/** Wrap an async function for use as a Wasm import.  With JSPI the Wasm stack
 *  is suspended while the Promise is in-flight.  Without JSPI we just store
 *  the function directly – it will be called synchronously and must not await. */
function susp(fn) {
  return HAS_JSPI ? new WebAssembly.Suspending(fn) : fn;
}

// ---------------------------------------------------------------------------
// Import object
// ---------------------------------------------------------------------------
const env_imports = {

  // -- String / bytes --------------------------------------------------------
  js_string_len(h) {
    const s = get(h);
    return typeof s === "string" ? encoder.encode(s).length : 0;
  },
  js_string_read(h, ptr) {
    const s = get(h);
    if (typeof s === "string") {
      const enc = encoder.encode(s);
      new Uint8Array(mem().buffer, ptr, enc.length).set(enc);
    }
  },
  js_bytes_len(h) {
    const b = get(h);
    return b instanceof Uint8Array ? b.byteLength : (b instanceof ArrayBuffer ? b.byteLength : 0);
  },
  js_bytes_read(h, ptr) {
    const b = get(h);
    const src = b instanceof ArrayBuffer ? new Uint8Array(b) : b;
    if (src) new Uint8Array(mem().buffer, ptr, src.byteLength).set(src);
  },
  js_release(h) { drop(h); },
  js_store_string(ptr, len) { return store(readStr(ptr, len)); },

  // -- Generic property access -----------------------------------------------
  js_get_string_prop(obj, np, nl) {
    const name = readStr(np, nl);
    const val = get(obj)?.[name];
    if (val == null || typeof val !== "string") return 0;
    return store(val);
  },
  js_get_int_prop(obj, np, nl) {
    const name = readStr(np, nl);
    const val = get(obj)?.[name];
    if (typeof val === "number") return BigInt(Math.trunc(val));
    if (typeof val === "boolean") return val ? 1n : 0n;
    return 0n;
  },
  js_get_float_prop(obj, np, nl) {
    const name = readStr(np, nl);
    const val = get(obj)?.[name];
    return typeof val === "number" ? val : 0.0;
  },

  // -- Request ---------------------------------------------------------------
  // Method indices match std.http.Method enum:
  // GET=0, HEAD=1, POST=2, PUT=3, DELETE=4, CONNECT=5, OPTIONS=6, TRACE=7, PATCH=8
  request_method(h) {
    const m = ["GET","HEAD","POST","PUT","DELETE","CONNECT","OPTIONS","TRACE","PATCH"];
    const idx = m.indexOf(get(h).method);
    return idx >= 0 ? idx : 0;
  },
  request_url(h) { return store(get(h).url); },
  request_header(h, np, nl) {
    const val = get(h).headers.get(readStr(np, nl));
    return val != null ? store(val) : 0;
  },
  request_body_len(h) {
    const b = get(h)._bodyBytes;
    return b ? b.byteLength : 0;
  },
  request_body_read(h, ptr) {
    const b = get(h)._bodyBytes;
    if (b) new Uint8Array(mem().buffer, ptr, b.byteLength).set(new Uint8Array(b));
  },
  request_cf(h) {
    const cf = get(h).cf;
    return cf ? store(JSON.stringify(cf)) : 0;
  },
  request_headers_len(h) {
    let count = 0;
    get(h).headers.forEach(() => count++);
    return count;
  },
  request_headers_entries(h) {
    const entries = [];
    get(h).headers.forEach((v, k) => entries.push(k + "\0" + v));
    return store(entries.join("\n"));
  },

  // -- Response --------------------------------------------------------------
  response_new()                       { return store({ status: 200, headers: new Headers(), body: null }); },
  response_set_status(h, s)            { get(h).status = s; },
  response_set_header(h, np, nl, vp, vl) { get(h).headers.set(readStr(np, nl), readStr(vp, vl)); },
  response_set_body(h, ptr, len)       { get(h).body = new Uint8Array(mem().buffer.slice(ptr, ptr + len)); },
  response_redirect(up, ul, status) {
    const url = readStr(up, ul);
    const s = status || 302;
    return store({ status: s, headers: new Headers({ Location: url }), body: null });
  },
  response_clone(h) {
    const r = get(h);
    const cloned = {
      status: r.status,
      headers: new Headers(r.headers),
      body: r.body ? new Uint8Array(r.body) : null,
    };
    return store(cloned);
  },

  // -- Context (ExecutionContext) ---------------------------------------------
  ctx_wait_until(ch, ph) { get(ch).waitUntil(Promise.resolve(get(ph))); },
  ctx_pass_through_on_exception(ch) { get(ch).passThroughOnException(); },

  // -- Env -------------------------------------------------------------------
  env_get_text_binding(h, np, nl) {
    const v = get(h)?.[readStr(np, nl)];
    return (v != null && typeof v === "string") ? store(v) : 0;
  },
  env_get_binding(h, np, nl) {
    const v = get(h)?.[readStr(np, nl)];
    return v != null ? store(v) : 0;
  },

  // -- KV (JSPI) -------------------------------------------------------------
  kv_get: susp(async (kvH, kp, kl) => {
    const val = await get(kvH).get(readStr(kp, kl), "text");
    return val != null ? store(val) : 0;
  }),
  kv_get_blob: susp(async (kvH, kp, kl) => {
    const val = await get(kvH).get(readStr(kp, kl), "arrayBuffer");
    return val != null ? store(new Uint8Array(val)) : 0;
  }),
  kv_get_with_metadata: susp(async (kvH, kp, kl) => {
    const { value, metadata } = await get(kvH).getWithMetadata(readStr(kp, kl), "text");
    if (value == null) return 0;
    return store({ _value: store(value), _metadata: metadata != null ? store(JSON.stringify(metadata)) : 0 });
  }),
  kv_meta_value(h) { return get(h)?._value ?? 0; },
  kv_meta_metadata(h) { return get(h)?._metadata ?? 0; },
  kv_put_string: susp(async (kvH, kp, kl, vp, vl, ttl, expiration, mp, ml) => {
    const opts = {};
    if (ttl > 0) opts.expirationTtl = Number(ttl);
    if (expiration > 0) opts.expiration = Number(expiration);
    if (ml > 0) opts.metadata = JSON.parse(readStr(mp, ml));
    await get(kvH).put(readStr(kp, kl), readStr(vp, vl), opts);
  }),
  kv_put_blob: susp(async (kvH, kp, kl, vp, vl, ttl, expiration, mp, ml) => {
    const opts = {};
    if (ttl > 0) opts.expirationTtl = Number(ttl);
    if (expiration > 0) opts.expiration = Number(expiration);
    if (ml > 0) opts.metadata = JSON.parse(readStr(mp, ml));
    const bytes = new Uint8Array(mem().buffer.slice(vp, vp + vl));
    await get(kvH).put(readStr(kp, kl), bytes, opts);
  }),
  kv_delete: susp(async (kvH, kp, kl) => {
    await get(kvH).delete(readStr(kp, kl));
  }),
  kv_list: susp(async (kvH, pp, pl, cp, cl, limit) => {
    const opts = {};
    if (pl > 0) opts.prefix = readStr(pp, pl);
    if (cl > 0) opts.cursor = readStr(cp, cl);
    if (limit > 0 && limit < 1000) opts.limit = limit;
    const result = await get(kvH).list(opts);
    return store(JSON.stringify(result));
  }),

  // -- R2 (JSPI) -------------------------------------------------------------
  r2_head: susp(async (bH, kp, kl) => {
    const obj = await get(bH).head(readStr(kp, kl));
    if (!obj) return 0;
    return store({ key: obj.key, version: obj.version, size: obj.size,
                   etag: obj.etag, httpEtag: obj.httpEtag });
  }),
  r2_get: susp(async (bH, kp, kl) => {
    const obj = await get(bH).get(readStr(kp, kl));
    if (!obj) return 0;
    const body = new Uint8Array(await obj.arrayBuffer());
    const bodyH = store(body);
    return store({ key: obj.key, version: obj.version, size: obj.size,
                   etag: obj.etag, httpEtag: obj.httpEtag, bodyBytes: bodyH });
  }),
  r2_put: susp(async (bH, kp, kl, bp, bl, ctp, ctl) => {
    const key = readStr(kp, kl);
    const body = new Uint8Array(mem().buffer.slice(bp, bp + bl));
    const opts = {};
    if (ctl > 0) opts.httpMetadata = { contentType: readStr(ctp, ctl) };
    const obj = await get(bH).put(key, body, opts);
    return store({ key: obj.key, version: obj.version, size: obj.size,
                   etag: obj.etag, httpEtag: obj.httpEtag });
  }),
  r2_delete: susp(async (bH, kp, kl) => {
    await get(bH).delete(readStr(kp, kl));
  }),
  r2_list: susp(async (bH, pp, pl, cp, cl, limit) => {
    const opts = {};
    if (pl > 0) opts.prefix = readStr(pp, pl);
    if (cl > 0) opts.cursor = readStr(cp, cl);
    if (limit > 0 && limit < 1000) opts.limit = limit;
    const result = await get(bH).list(opts);
    const serialized = {
      objects: result.objects.map(o => ({
        key: o.key, version: o.version, size: o.size, etag: o.etag,
      })),
      truncated: result.truncated,
      cursor: result.truncated ? result.cursor : undefined,
    };
    return store(JSON.stringify(serialized));
  }),

  // -- D1 (JSPI) -------------------------------------------------------------
  d1_exec: susp(async (dbH, sp, sl) => {
    const result = await get(dbH).exec(readStr(sp, sl));
    return store({
      results: JSON.stringify([]),
      success: true,
      rows_read: result.count ?? 0,
      rows_written: result.count ?? 0,
    });
  }),
  d1_query_all: susp(async (dbH, sp, sl, pp, pl) => {
    const sql = readStr(sp, sl);
    const params = JSON.parse(readStr(pp, pl));
    const stmt = get(dbH).prepare(sql).bind(...params);
    const result = await stmt.all();
    return store({
      results: JSON.stringify(result.results ?? []),
      success: result.success,
      rows_read: result.meta?.rows_read ?? 0,
      rows_written: result.meta?.rows_written ?? 0,
    });
  }),
  d1_query_first: susp(async (dbH, sp, sl, pp, pl) => {
    const sql = readStr(sp, sl);
    const params = JSON.parse(readStr(pp, pl));
    const stmt = get(dbH).prepare(sql).bind(...params);
    const row = await stmt.first();
    return row != null ? store(JSON.stringify(row)) : 0;
  }),
  d1_query_run: susp(async (dbH, sp, sl, pp, pl) => {
    const sql = readStr(sp, sl);
    const params = JSON.parse(readStr(pp, pl));
    const stmt = get(dbH).prepare(sql).bind(...params);
    const result = await stmt.run();
    return store({
      results: JSON.stringify([]),
      success: result.success,
      rows_read: result.meta?.rows_read ?? 0,
      rows_written: result.meta?.rows_written ?? 0,
    });
  }),

  // -- Fetch (outbound HTTP) -------------------------------------------------
  fetch_create_request(up, ul, method) {
    const methods = ["GET","HEAD","POST","PUT","DELETE","CONNECT","OPTIONS","TRACE","PATCH"];
    return store({
      url: readStr(up, ul),
      method: methods[method] ?? "GET",
      headers: new Headers(),
      body: null,
    });
  },
  fetch_request_set_header(reqH, np, nl, vp, vl) {
    get(reqH).headers.set(readStr(np, nl), readStr(vp, vl));
  },
  fetch_request_set_body(reqH, bp, bl) {
    get(reqH).body = new Uint8Array(mem().buffer.slice(bp, bp + bl));
  },
  fetch_request_set_form_data(reqH, objH) {
    const obj = get(objH);
    get(reqH).body = obj._fd || obj; // FormData wrapper or raw JS object
  },
  fetch_send: susp(async (reqH) => {
    const req = get(reqH);
    const opts = { method: req.method, headers: req.headers };
    if (req.body) opts.body = req.body;
    drop(reqH);
    const resp = await fetch(req.url, opts);
    // For WebSocket upgrades (101), preserve the webSocket and skip body read.
    if (resp.webSocket) {
      return store({
        status: resp.status,
        _headers: resp.headers,
        _body: 0,
        _url: resp.url || "",
        _redirected: !!resp.redirected,
        _webSocket: resp.webSocket,
      });
    }
    const bodyBuf = new Uint8Array(await resp.arrayBuffer());
    return store({
      status: resp.status,
      _headers: resp.headers,
      _body: store(bodyBuf),
      _url: resp.url || "",
      _redirected: !!resp.redirected,
    });
  }),
  fetch_response_status(h) { return get(h)?.status ?? 0; },
  fetch_response_header(h, np, nl) {
    const val = get(h)?._headers?.get(readStr(np, nl));
    return val != null ? store(val) : 0;
  },
  fetch_response_body(h) { return get(h)?._body ?? 0; },
  fetch_response_url(h) { return store(get(h)?._url ?? ""); },
  fetch_response_redirected(h) { return get(h)?._redirected ? 1 : 0; },
  // Extract WebSocket from a fetch response (for outbound WS connections).
  fetch_response_websocket(h) {
    const ws = get(h)?._webSocket;
    return ws ? store(ws) : 0;
  },

  // -- Async scheduling (non-suspending) -------------------------------------
  // These kick off Promises immediately but do NOT suspend Wasm.
  // They return an index into _asyncPending.

  async_kv_get(kvH, kp, kl) {
    const id = _asyncPending.length;
    _asyncPending.push(get(kvH).get(readStr(kp, kl), "text"));
    return id;
  },
  async_kv_get_blob(kvH, kp, kl) {
    const id = _asyncPending.length;
    _asyncPending.push(
      get(kvH).get(readStr(kp, kl), "arrayBuffer")
        .then(v => v != null ? new Uint8Array(v) : null)
    );
    return id;
  },
  async_kv_put(kvH, kp, kl, vp, vl, ttl) {
    const key = readStr(kp, kl);
    const val = readStr(vp, vl);
    const opts = {};
    if (ttl > 0n) opts.expirationTtl = Number(ttl);
    const id = _asyncPending.length;
    _asyncPending.push(get(kvH).put(key, val, opts));
    return id;
  },
  async_kv_delete(kvH, kp, kl) {
    const id = _asyncPending.length;
    _asyncPending.push(get(kvH).delete(readStr(kp, kl)));
    return id;
  },

  async_r2_get(bH, kp, kl) {
    const key = readStr(kp, kl);
    const id = _asyncPending.length;
    _asyncPending.push(
      get(bH).get(key).then(async obj => {
        if (!obj) return null;
        const body = new Uint8Array(await obj.arrayBuffer());
        const bodyH = store(body);
        return { key: obj.key, version: obj.version, size: obj.size,
                 etag: obj.etag, httpEtag: obj.httpEtag, bodyBytes: bodyH };
      })
    );
    return id;
  },
  async_r2_head(bH, kp, kl) {
    const key = readStr(kp, kl);
    const id = _asyncPending.length;
    _asyncPending.push(
      get(bH).head(key).then(obj => {
        if (!obj) return null;
        return { key: obj.key, version: obj.version, size: obj.size,
                 etag: obj.etag, httpEtag: obj.httpEtag };
      })
    );
    return id;
  },
  async_r2_put(bH, kp, kl, bp, bl, ctp, ctl) {
    const key = readStr(kp, kl);
    const body = new Uint8Array(mem().buffer.slice(bp, bp + bl));
    const opts = {};
    if (ctl > 0) opts.httpMetadata = { contentType: readStr(ctp, ctl) };
    const id = _asyncPending.length;
    _asyncPending.push(
      get(bH).put(key, body, opts).then(obj => {
        return { key: obj.key, version: obj.version, size: obj.size,
                 etag: obj.etag, httpEtag: obj.httpEtag };
      })
    );
    return id;
  },
  async_r2_delete(bH, kp, kl) {
    const id = _asyncPending.length;
    _asyncPending.push(get(bH).delete(readStr(kp, kl)));
    return id;
  },

  async_d1_exec(dbH, sp, sl) {
    const sql = readStr(sp, sl);
    const id = _asyncPending.length;
    _asyncPending.push(
      get(dbH).exec(sql).then(r => ({
        results: JSON.stringify([]),
        success: true,
        rows_read: r.count ?? 0,
        rows_written: r.count ?? 0,
      }))
    );
    return id;
  },
  async_d1_query_all(dbH, sp, sl, pp, pl) {
    const sql = readStr(sp, sl);
    const params = JSON.parse(readStr(pp, pl));
    const id = _asyncPending.length;
    _asyncPending.push(
      get(dbH).prepare(sql).bind(...params).all().then(r => ({
        results: JSON.stringify(r.results ?? []),
        success: r.success,
        rows_read: r.meta?.rows_read ?? 0,
        rows_written: r.meta?.rows_written ?? 0,
      }))
    );
    return id;
  },
  async_d1_query_first(dbH, sp, sl, pp, pl) {
    const sql = readStr(sp, sl);
    const params = JSON.parse(readStr(pp, pl));
    const id = _asyncPending.length;
    _asyncPending.push(
      get(dbH).prepare(sql).bind(...params).first().then(r =>
        r != null ? JSON.stringify(r) : null
      )
    );
    return id;
  },
  async_d1_query_run(dbH, sp, sl, pp, pl) {
    const sql = readStr(sp, sl);
    const params = JSON.parse(readStr(pp, pl));
    const id = _asyncPending.length;
    _asyncPending.push(
      get(dbH).prepare(sql).bind(...params).run().then(r => ({
        results: JSON.stringify([]),
        success: r.success,
        rows_read: r.meta?.rows_read ?? 0,
        rows_written: r.meta?.rows_written ?? 0,
      }))
    );
    return id;
  },

  async_fetch(reqH) {
    const req = get(reqH);
    const opts = { method: req.method, headers: req.headers };
    if (req.body) opts.body = req.body;
    drop(reqH);
    const id = _asyncPending.length;
    _asyncPending.push(
      fetch(req.url, opts).then(async resp => {
        const bodyBuf = new Uint8Array(await resp.arrayBuffer());
        return {
          status: resp.status,
          _headers: resp.headers,
          _body: store(bodyBuf),
          _url: resp.url || "",
          _redirected: !!resp.redirected,
        };
      })
    );
    return id;
  },

  // -- Async flush (JSPI-suspending) -----------------------------------------
  // Single suspension point: awaits ALL pending promises via Promise.all.
  async_flush: susp(async () => {
    if (_asyncPending.length === 0) return 0;
    const results = await Promise.all(_asyncPending);
    _asyncPending = [];
    const handles = results.map(r => r != null ? store(r) : 0);
    return store(handles);
  }),

  // -- Async result retrieval (non-suspending) -------------------------------
  async_get_result(resultsH, index) {
    const arr = get(resultsH);
    return (arr && index < arr.length) ? arr[index] : 0;
  },
  async_release_results(resultsH) {
    const arr = get(resultsH);
    if (arr) {
      for (const h of arr) { if (h > 0) drop(h); }
      drop(resultsH);
    }
  },

  // -- Streaming response ----------------------------------------------------
  // NON-suspending: creates TransformStream, resolves early-response promise.
  response_stream_start(status) {
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const streamObj = { writer, readable, status, headers: new Headers() };
    const h = store(streamObj);
    // Signal the JS fetch handler to return this response immediately.
    if (_streamResolve) {
      _streamResolve(streamObj);
      _streamResolve = null;
    }
    return h;
  },
  response_stream_set_header(h, np, nl, vp, vl) {
    get(h).headers.set(readStr(np, nl), readStr(vp, vl));
  },
  // JSPI-suspending: flushes chunk to client.
  response_stream_write: susp(async (h, ptr, len) => {
    const chunk = new Uint8Array(mem().buffer.slice(ptr, ptr + len));
    await get(h).writer.write(chunk);
  }),
  response_stream_close: susp(async (h) => {
    await get(h).writer.close();
  }),

  // -- Cache -----------------------------------------------------------------
  cache_default() {
    return store(caches.default);
  },
  cache_open: susp(async (np, nl) => {
    const cache = await caches.open(readStr(np, nl));
    return store(cache);
  }),
  cache_match: susp(async (cacheH, up, ul) => {
    const url = "http://workers-zig.local/" + readStr(up, ul).replace(/^\//, "");
    const resp = await get(cacheH).match(url);
    if (!resp) return 0;
    const body = new Uint8Array(await resp.arrayBuffer());
    return store({
      status: resp.status,
      headers: resp.headers,
      body: body.length > 0 ? body : null,
    });
  }),
  cache_put: susp(async (cacheH, up, ul, respH) => {
    const url = "http://workers-zig.local/" + readStr(up, ul).replace(/^\//, "");
    const resp = get(respH);
    const jsResp = new Response(resp.body, {
      status: resp.status,
      headers: resp.headers,
    });
    await get(cacheH).put(url, jsResp);
  }),
  cache_delete: susp(async (cacheH, up, ul) => {
    const url = "http://workers-zig.local/" + readStr(up, ul).replace(/^\//, "");
    const ok = await get(cacheH).delete(url);
    return ok ? 1 : 0;
  }),

  cache_match_request: susp(async (cacheH, reqH) => {
    const rd = get(reqH);
    const req = new Request(rd.url, { method: rd.method, headers: rd.headers });
    const resp = await get(cacheH).match(req);
    if (!resp) return 0;
    const body = new Uint8Array(await resp.arrayBuffer());
    return store({
      status: resp.status,
      headers: resp.headers,
      body: body.length > 0 ? body : null,
    });
  }),
  cache_put_request: susp(async (cacheH, reqH, respH) => {
    const rd = get(reqH);
    const req = new Request(rd.url, { method: rd.method, headers: rd.headers });
    const resp = get(respH);
    const jsResp = new Response(resp.body, {
      status: resp.status,
      headers: resp.headers,
    });
    await get(cacheH).put(req, jsResp);
  }),
  cache_delete_request: susp(async (cacheH, reqH) => {
    const rd = get(reqH);
    const req = new Request(rd.url, { method: rd.method, headers: rd.headers });
    const ok = await get(cacheH).delete(req);
    return ok ? 1 : 0;
  }),

  // -- WebSocket --------------------------------------------------------------
  ws_pair_new() {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    return store({ client, server, _queue: [], _resolve: null, _closed: false });
  },
  ws_accept(pairH) {
    const pair = get(pairH);
    pair.server.accept();

    // Queue incoming events so ws_receive can pull them synchronously or await.
    pair.server.addEventListener("message", (ev) => {
      const msg = typeof ev.data === "string"
        ? { type: 0, data: ev.data }
        : { type: 1, data: new Uint8Array(ev.data instanceof ArrayBuffer ? ev.data : ev.data.buffer) };
      if (pair._resolve) {
        const r = pair._resolve;
        pair._resolve = null;
        r(store(msg));
      } else {
        pair._queue.push(msg);
      }
    });
    pair.server.addEventListener("close", (ev) => {
      pair._closed = true;
      const msg = { type: 2, code: ev.code || 1005, reason: ev.reason || "" };
      if (pair._resolve) {
        const r = pair._resolve;
        pair._resolve = null;
        r(store(msg));
      } else {
        pair._queue.push(msg);
      }
    });
    pair.server.addEventListener("error", () => {
      pair._closed = true;
      const msg = { type: 3 };
      if (pair._resolve) {
        const r = pair._resolve;
        pair._resolve = null;
        r(store(msg));
      } else {
        pair._queue.push(msg);
      }
    });

    // Signal the JS fetch handler to return the 101 response immediately.
    if (_wsResolve) {
      _wsResolve(pair);
      _wsResolve = null;
    }
  },
  // Accept an outbound WebSocket obtained via fetch (client-side).
  // Sets up the same event queue as ws_accept but does NOT trigger _wsResolve.
  ws_client_accept(rawWsH) {
    const rawWs = get(rawWsH);
    rawWs.accept();
    const obj = { _ws: rawWs, _queue: [], _resolve: null, _closed: false };
    rawWs.addEventListener("message", (ev) => {
      const msg = typeof ev.data === "string"
        ? { type: 0, data: ev.data }
        : { type: 1, data: new Uint8Array(ev.data instanceof ArrayBuffer ? ev.data : ev.data.buffer) };
      if (obj._resolve) {
        const r = obj._resolve;
        obj._resolve = null;
        r(store(msg));
      } else {
        obj._queue.push(msg);
      }
    });
    rawWs.addEventListener("close", (ev) => {
      obj._closed = true;
      const msg = { type: 2, code: ev.code || 1005, reason: ev.reason || "" };
      if (obj._resolve) {
        const r = obj._resolve;
        obj._resolve = null;
        r(store(msg));
      } else {
        obj._queue.push(msg);
      }
    });
    rawWs.addEventListener("error", () => {
      obj._closed = true;
      const msg = { type: 3 };
      if (obj._resolve) {
        const r = obj._resolve;
        obj._resolve = null;
        r(store(msg));
      } else {
        obj._queue.push(msg);
      }
    });
    return store(obj);
  },
  ws_send_text(h, ptr, len) {
    const o = get(h);
    (o._ws || o.server).send(readStr(ptr, len));
  },
  ws_send_binary(h, ptr, len) {
    const o = get(h);
    (o._ws || o.server).send(new Uint8Array(mem().buffer.slice(ptr, ptr + len)));
  },
  ws_close(h, code, rp, rl) {
    const reason = rl > 0 ? readStr(rp, rl) : undefined;
    const ws = get(h);
    const target = ws._ws || ws.server;
    // Codes 1005 and 1006 are reserved and cannot be sent explicitly.
    if (code > 0 && code !== 1005 && code !== 1006) {
      target.close(code, reason);
    } else {
      target.close();
    }
  },
  ws_receive: susp(async (h) => {
    const obj = get(h);
    if (obj._queue.length > 0) {
      return store(obj._queue.shift());
    }
    if (obj._closed && obj._queue.length === 0) return 0;
    return new Promise((resolve) => {
      obj._resolve = (h) => resolve(h);
    });
  }),
  ws_event_type(h) { return get(h).type; },
  ws_event_text_len(h) { return encoder.encode(get(h).data).length; },
  ws_event_text_read(h, ptr) {
    const bytes = encoder.encode(get(h).data);
    new Uint8Array(mem().buffer, ptr, bytes.length).set(bytes);
  },
  ws_event_binary_len(h) { return get(h).data.byteLength; },
  ws_event_binary_read(h, ptr) {
    new Uint8Array(mem().buffer, ptr, get(h).data.byteLength).set(get(h).data);
  },
  ws_event_close_code(h) { return get(h).code || 1005; },
  ws_event_close_reason_len(h) { return encoder.encode(get(h).reason || "").length; },
  ws_event_close_reason_read(h, ptr) {
    const bytes = encoder.encode(get(h).reason || "");
    new Uint8Array(mem().buffer, ptr, bytes.length).set(bytes);
  },

  // -- Durable Objects: Namespace / Id / Stub --------------------------------
  do_ns_id_from_name(nsH, np, nl) {
    return store(get(nsH).idFromName(readStr(np, nl)));
  },
  do_ns_id_from_string(nsH, sp, sl) {
    return store(get(nsH).idFromString(readStr(sp, sl)));
  },
  do_ns_new_unique_id(nsH) {
    return store(get(nsH).newUniqueId());
  },
  do_ns_get(nsH, idH) {
    return store(get(nsH).get(get(idH)));
  },
  do_id_to_string(idH) {
    return store(get(idH).toString());
  },
  do_id_equals(idH1, idH2) {
    return get(idH1).equals(get(idH2)) ? 1 : 0;
  },
  do_id_name(idH) {
    const n = get(idH).name;
    return n != null ? store(n) : 0;
  },
  do_stub_fetch: susp(async (stubH, reqH) => {
    const stub = get(stubH);
    const req = get(reqH);
    const opts = { method: req.method, headers: req.headers };
    if (req.body) opts.body = req.body;
    drop(reqH);
    const resp = await stub.fetch(req.url, opts);
    const bodyBuf = new Uint8Array(await resp.arrayBuffer());
    return store({
      status: resp.status,
      _headers: resp.headers,
      _body: store(bodyBuf),
      _url: resp.url || "",
      _redirected: !!resp.redirected,
    });
  }),

  // -- Durable Objects: State / Storage -------------------------------------
  do_state_id(stateH) {
    return store(get(stateH).id);
  },
  do_storage_get: susp(async (stateH, kp, kl) => {
    const val = await get(stateH).storage.get(readStr(kp, kl));
    if (val === undefined || val === null) return 0;
    return store(typeof val === "string" ? val : JSON.stringify(val));
  }),
  do_storage_put: susp(async (stateH, kp, kl, vp, vl) => {
    await get(stateH).storage.put(readStr(kp, kl), readStr(vp, vl));
  }),
  do_storage_delete: susp(async (stateH, kp, kl) => {
    const result = await get(stateH).storage.delete(readStr(kp, kl));
    return result ? 1 : 0;
  }),
  do_storage_delete_all: susp(async (stateH) => {
    await get(stateH).storage.deleteAll();
  }),
  do_storage_list: susp(async (stateH, optsH) => {
    const opts = optsH > 0 ? get(optsH) : {};
    const map = await get(stateH).storage.list(opts);
    const obj = {};
    for (const [k, v] of map) {
      obj[k] = typeof v === "string" ? v : JSON.stringify(v);
    }
    if (optsH > 0) drop(optsH);
    return store(JSON.stringify(obj));
  }),
  do_storage_list_options(pp, pl, sp, sl, ep, el, limit, reverse) {
    const opts = {};
    if (pl > 0) opts.prefix = readStr(pp, pl);
    if (sl > 0) opts.start = readStr(sp, sl);
    if (el > 0) opts.end = readStr(ep, el);
    if (limit > 0) opts.limit = limit;
    if (reverse) opts.reverse = true;
    return store(opts);
  },
  do_storage_get_alarm: susp(async (stateH) => {
    const alarm = await get(stateH).storage.getAlarm();
    return alarm !== null ? alarm : -1.0;
  }),
  do_storage_set_alarm: susp(async (stateH, timeMs) => {
    await get(stateH).storage.setAlarm(timeMs);
  }),
  do_storage_delete_alarm: susp(async (stateH) => {
    await get(stateH).storage.deleteAlarm();
  }),

  // -- Durable Objects: SQL Storage (synchronous – no JSPI) -----------------
  // exec: materializes all results into a JSON object with metadata.
  do_sql_exec(stateH, sp, sl, pp, pl) {
    const sql = readStr(sp, sl);
    const params = pl > 0 ? JSON.parse(readStr(pp, pl)) : [];
    const cursor = get(stateH).storage.sql.exec(sql, ...params);
    const rows = [...cursor];
    return store({
      results: JSON.stringify(rows),
      columns: JSON.stringify(cursor.columnNames),
      rows_read: cursor.rowsRead,
      rows_written: cursor.rowsWritten,
    });
  },

  // cursor_open: returns a handle to a live cursor for row-at-a-time iteration.
  do_sql_cursor_open(stateH, sp, sl, pp, pl) {
    const sql = readStr(sp, sl);
    const params = pl > 0 ? JSON.parse(readStr(pp, pl)) : [];
    const cursor = get(stateH).storage.sql.exec(sql, ...params);
    return store(cursor);
  },

  // cursor_next: returns a JSON string of the next row, or null_handle if done.
  do_sql_cursor_next(cursorH) {
    const cursor = get(cursorH);
    const result = cursor.next();
    if (result.done) return 0;
    return store(JSON.stringify(result.value));
  },

  // cursor_column_names: returns a JSON array of column names.
  do_sql_cursor_column_names(cursorH) {
    return store(JSON.stringify(get(cursorH).columnNames));
  },

  // cursor_rows_read: returns number of rows read so far.
  do_sql_cursor_rows_read(cursorH) { return get(cursorH).rowsRead; },

  // cursor_rows_written: returns number of rows written so far.
  do_sql_cursor_rows_written(cursorH) { return get(cursorH).rowsWritten; },

  // database_size: returns the SQLite database size in bytes.
  do_sql_database_size(stateH) { return get(stateH).storage.sql.databaseSize; },

  // -- Durable Objects: Facets -----------------------------------------------
  do_facets_get: susp(async (stateH, np, nl, classH, idp, idl) => {
    const state = get(stateH);
    const facetName = readStr(np, nl);
    const doClass = get(classH);
    const idStr = idl > 0 ? readStr(idp, idl) : null;

    const fetcher = state.facets.get(facetName, () => {
      const opts = { class: doClass };
      if (idStr) opts.id = idStr;
      return opts;
    });
    return store(fetcher);
  }),
  do_facets_abort(stateH, np, nl, rp, rl) {
    get(stateH).facets.abort(readStr(np, nl), readStr(rp, rl));
  },
  do_facets_delete(stateH, np, nl) {
    get(stateH).facets.delete(readStr(np, nl));
  },

  // -- Containers (on DurableObjectState) ------------------------------------
  // Sync methods
  ct_running(stateH) {
    const c = get(stateH).container;
    return c && c.running ? 1 : 0;
  },
  ct_start(stateH, optsH) {
    const opts = optsH ? get(optsH) : undefined;
    if (optsH) drop(optsH);
    get(stateH).container.start(opts);
  },
  ct_signal(stateH, signo) {
    get(stateH).container.signal(signo);
  },
  ct_get_tcp_port(stateH, port) {
    return store(get(stateH).container.getTcpPort(port));
  },
  // JSPI-suspending methods
  ct_monitor: susp(async (stateH) => {
    await get(stateH).container.monitor();
  }),
  ct_destroy: susp(async (stateH, rp, rl) => {
    const reason = rl > 0 ? readStr(rp, rl) : undefined;
    await get(stateH).container.destroy(reason);
  }),
  ct_set_inactivity_timeout: susp(async (stateH, ms) => {
    await get(stateH).container.setInactivityTimeout(ms);
  }),
  ct_intercept_outbound_http: susp(async (stateH, ap, al, fetcherH) => {
    const addr = readStr(ap, al);
    const binding = get(fetcherH);
    await get(stateH).container.interceptOutboundHttp(addr, binding);
  }),
  ct_intercept_all_outbound_http: susp(async (stateH, fetcherH) => {
    const binding = get(fetcherH);
    await get(stateH).container.interceptAllOutboundHttp(binding);
  }),
  ct_intercept_outbound_https: susp(async (stateH, ap, al, fetcherH) => {
    const addr = readStr(ap, al);
    const binding = get(fetcherH);
    await get(stateH).container.interceptOutboundHttps(addr, binding);
  }),
  ct_snapshot_directory: susp(async (stateH, dp, dl, np, nl) => {
    const dir = readStr(dp, dl);
    const name = nl > 0 ? readStr(np, nl) : undefined;
    const snap = await get(stateH).container.snapshotDirectory({ dir, name });
    return store(snap);
  }),
  ct_snapshot_container: susp(async (stateH, np, nl) => {
    const name = nl > 0 ? readStr(np, nl) : undefined;
    const snap = await get(stateH).container.snapshotContainer({ name });
    return store(snap);
  }),
  // Startup options builder (non-suspending)
  ct_opts_new(enableInternet) {
    return store({ enableInternet: !!enableInternet });
  },
  ct_opts_set_entrypoint(optsH, ep, el) {
    // Entrypoint is a string array — we accept a JSON array string.
    get(optsH).entrypoint = JSON.parse(readStr(ep, el));
  },
  ct_opts_set_env(optsH, kp, kl, vp, vl) {
    const o = get(optsH);
    if (!o.env) o.env = {};
    o.env[readStr(kp, kl)] = readStr(vp, vl);
  },
  ct_opts_set_label(optsH, kp, kl, vp, vl) {
    const o = get(optsH);
    if (!o.labels) o.labels = {};
    o.labels[readStr(kp, kl)] = readStr(vp, vl);
  },
  ct_opts_set_container_snapshot(optsH, snapH) {
    get(optsH).containerSnapshot = get(snapH);
  },
  ct_opts_add_dir_snapshot(optsH, snapH, mp, ml) {
    const o = get(optsH);
    if (!o.directorySnapshots) o.directorySnapshots = [];
    const entry = { snapshot: get(snapH) };
    if (ml > 0) entry.mountPoint = readStr(mp, ml);
    o.directorySnapshots.push(entry);
  },

  // -- Worker Loader: builder ------------------------------------------------
  wl_code_new(cdp, cdl, mmp, mml) {
    return store({
      compatibilityDate: readStr(cdp, cdl),
      mainModule: readStr(mmp, mml),
      modules: {},
      compatibilityFlags: [],
    });
  },
  wl_code_set_compat_flag(codeH, fp, fl) {
    get(codeH).compatibilityFlags.push(readStr(fp, fl));
  },
  wl_code_set_cpu_ms(codeH, ms) {
    const c = get(codeH);
    if (!c.limits) c.limits = {};
    c.limits.cpuMs = ms;
  },
  wl_code_set_sub_requests(codeH, n) {
    const c = get(codeH);
    if (!c.limits) c.limits = {};
    c.limits.subRequests = n;
  },
  wl_code_set_env_json(codeH, jp, jl) {
    get(codeH).env = JSON.parse(readStr(jp, jl));
  },
  wl_code_set_global_outbound(codeH, fetcherH) {
    get(codeH).globalOutbound = fetcherH === 0 ? null : get(fetcherH);
  },
  wl_code_add_module_string(codeH, np, nl, mtype, cp, cl) {
    const types = ["js", "cjs", "text", "data", "json", "py", "wasm"];
    const name = readStr(np, nl);
    const content = readStr(cp, cl);
    const typeKey = types[mtype];
    if (typeKey === "json") {
      get(codeH).modules[name] = { json: JSON.parse(content) };
    } else {
      get(codeH).modules[name] = { [typeKey]: content };
    }
  },
  wl_code_add_module_bytes(codeH, np, nl, mtype, cp, cl) {
    const name = readStr(np, nl);
    const buf = new Uint8Array(mem().buffer, cp, cl).slice().buffer;
    const typeKey = mtype === 6 ? "wasm" : "data";
    get(codeH).modules[name] = { [typeKey]: buf };
  },

  // -- Worker Loader: operations (JSPI-suspending) ---------------------------
  wl_get: susp(async (loaderH, np, nl, codeH) => {
    const name = nl > 0 ? readStr(np, nl) : null;
    const code = get(codeH);
    drop(codeH);
    const stub = get(loaderH).get(name, () => code);
    return store(stub);
  }),
  wl_load(loaderH, codeH) {
    const code = get(codeH);
    drop(codeH);
    return store(get(loaderH).load(code));
  },

  // -- WorkerStub methods ----------------------------------------------------
  wl_stub_get_entrypoint(stubH, np, nl) {
    const name = nl > 0 ? readStr(np, nl) : undefined;
    return store(get(stubH).getEntrypoint(name));
  },
  wl_stub_get_do_class(stubH, np, nl) {
    const name = nl > 0 ? readStr(np, nl) : undefined;
    return store(get(stubH).getDurableObjectClass(name));
  },
  wl_stub_fetch: susp(async (stubH, reqH) => {
    const stub = get(stubH);
    const req = get(reqH);
    const url = req.url || req._url;
    const opts = { method: req.method || "GET" };
    if (req.headers) opts.headers = req.headers;
    if (req._bodyBytes) opts.body = req._bodyBytes;
    const resp = await stub.fetch(url, opts);
    // Convert native Response to our internal format for fetch_response_* shim functions.
    const bodyBytes = await resp.arrayBuffer();
    const body = new Uint8Array(bodyBytes);
    return store({
      status: resp.status,
      _headers: resp.headers,
      _body: store(body),
      _url: resp.url || "",
      _redirected: !!resp.redirected,
    });
  }),

  // -- Workers AI (JSPI) ----------------------------------------------------
  ai_run: susp(async (aiH, mp, ml, ip, il) => {
    const model = readStr(mp, ml);
    const input = JSON.parse(readStr(ip, il));
    const opts = input.__options; delete input.__options;
    let result = await get(aiH).run(model, input, opts);
    // Normalize OpenAI choices[] format to simple { response, usage } format.
    if (result && result.choices && Array.isArray(result.choices)) {
      const msg = result.choices[0]?.message;
      const normalized = {
        response: msg?.content ?? msg?.reasoning ?? null,
        usage: result.usage ?? null,
      };
      if (msg?.tool_calls) normalized.tool_calls = msg.tool_calls;
      result = normalized;
    }
    // Ensure response field is always a string (JSON mode returns objects).
    if (result && typeof result.response === 'object' && result.response !== null) {
      result.response = JSON.stringify(result.response);
    }
    return store(JSON.stringify(result));
  }),
  ai_run_with_binary: susp(async (aiH, mp, ml, ip, il, bp, bl, fp, fl) => {
    const model = readStr(mp, ml);
    const input = JSON.parse(readStr(ip, il));
    const opts = input.__options; delete input.__options;
    const field = readStr(fp, fl);
    const bytes = new Uint8Array(mem().buffer.slice(bp, bp + bl));
    input[field] = [...bytes];
    const result = await get(aiH).run(model, input, opts);
    return store(JSON.stringify(result));
  }),
  ai_run_binary_output: susp(async (aiH, mp, ml, ip, il) => {
    const model = readStr(mp, ml);
    const input = JSON.parse(readStr(ip, il));
    const opts = input.__options; delete input.__options;
    const isMultipart = input.__multipart; delete input.__multipart;
    let actualInput = input;
    if (isMultipart) {
      const form = new FormData();
      for (const [k, v] of Object.entries(input)) form.append(k, String(v));
      const formResp = new Response(form);
      actualInput = { multipart: { body: formResp.body, contentType: formResp.headers.get('content-type') } };
    }
    const result = await get(aiH).run(model, actualInput, opts);
    // Handle various binary response types from Workers AI
    if (result instanceof ReadableStream) {
      const reader = result.getReader();
      const chunks = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
      }
      const total = chunks.reduce((s, c) => s + c.byteLength, 0);
      const bytes = new Uint8Array(total);
      let offset = 0;
      for (const c of chunks) { bytes.set(c, offset); offset += c.byteLength; }
      return store(bytes);
    }
    if (result instanceof Uint8Array) return store(result);
    if (result instanceof ArrayBuffer) return store(new Uint8Array(result));
    // Some models return { image: "base64..." } or { audio: "base64..." }
    if (typeof result === "object" && result !== null) {
      const b64 = result.image || result.audio;
      if (typeof b64 === "string") {
        const binary = atob(b64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return store(bytes);
      }
    }
    // Fallback: return 0 (no data)
    return 0;
  }),
  ai_run_stream: susp(async (aiH, mp, ml, ip, il) => {
    const model = readStr(mp, ml);
    const input = JSON.parse(readStr(ip, il));
    const opts = input.__options; delete input.__options;
    input.stream = true;
    const stream = await get(aiH).run(model, input, opts);
    return store(stream.getReader());
  }),
  ai_stream_next: susp(async (readerH) => {
    const { done, value } = await get(readerH).read();
    if (done) return 0;
    let text = new TextDecoder().decode(value);
    // Normalize OpenAI streaming SSE format: data: {"choices":[{"delta":{"content":"token"}}]}
    // → data: {"response":"token"}
    text = text.replace(/^data: ({.+)$/gm, (_, json) => {
      try {
        const obj = JSON.parse(json);
        if (obj.choices && Array.isArray(obj.choices)) {
          const delta = obj.choices[0]?.delta;
          const normalized = { response: delta?.content ?? delta?.reasoning ?? null };
          if (obj.usage) normalized.usage = obj.usage;
          return 'data: ' + JSON.stringify(normalized);
        }
      } catch (_e) { /* not JSON, pass through */ }
      return 'data: ' + json;
    });
    return store(text);
  }),
  ai_models: susp(async (aiH) => {
    const result = await get(aiH).models();
    return store(JSON.stringify(result));
  }),
  ai_run_websocket: susp(async (aiH, mp, ml, ip, il) => {
    const model = readStr(mp, ml);
    const input = JSON.parse(readStr(ip, il));
    const opts = input.__options || {};
    delete input.__options;
    opts.websocket = true;
    const resp = await get(aiH).run(model, input, opts);
    return store(resp);
  }),

  // -- Queues: Producer (JSPI-suspending) ------------------------------------
  queue_send: susp(async (queueH, bp, bl, ct, delay) => {
    const queue = get(queueH);
    const body = JSON.parse(readStr(bp, bl));
    const opts = {};
    const CT_MAP = ["json", "text", "bytes", "v8"];
    if (ct < CT_MAP.length) opts.contentType = CT_MAP[ct];
    if (delay > 0) opts.delaySeconds = delay;
    await queue.send(body, opts);
  }),
  queue_send_batch: susp(async (queueH, bp, bl, delay) => {
    const queue = get(queueH);
    const batch = JSON.parse(readStr(bp, bl));
    const opts = {};
    if (delay > 0) opts.delaySeconds = delay;
    await queue.sendBatch(batch, opts);
  }),

  // -- Queues: Consumer (non-suspending) -------------------------------------
  queue_batch_queue_name(h) { return store(get(h).queue); },
  queue_batch_len(h)        { return get(h).messages.length; },
  queue_batch_msg(h, i)     { return store(get(h).messages[i]); },
  queue_batch_ack_all(h)    { get(h).ackAll(); },
  queue_batch_retry_all(h, delay) {
    const opts = delay > 0 ? { delaySeconds: delay } : undefined;
    get(h).retryAll(opts);
  },
  queue_msg_id(h)           { return store(get(h).id); },
  queue_msg_timestamp(h)    { return get(h).timestamp.getTime(); },
  queue_msg_body(h)         {
    const b = get(h).body;
    return store(typeof b === "string" ? b : JSON.stringify(b));
  },
  queue_msg_attempts(h)     { return get(h).attempts; },
  queue_msg_ack(h)          { get(h).ack(); },
  queue_msg_retry(h, delay) {
    const opts = delay > 0 ? { delaySeconds: delay } : undefined;
    get(h).retry(opts);
  },

  // -- Analytics Engine (fire-and-forget) ------------------------------------
  ae_write_data_point(dsH, jp, jl) {
    const ds = get(dsH);
    const point = JSON.parse(readStr(jp, jl));
    ds.writeDataPoint(point);
  },

  // -- Rate Limiting (JSPI-suspending) --------------------------------------
  rate_limit: susp(async (rlH, kp, kl) => {
    const rl = get(rlH);
    const key = readStr(kp, kl);
    const outcome = await rl.limit({ key });
    return outcome.success ? 1 : 0;
  }),

  // -- Hyperdrive (property getters) ----------------------------------------
  hyperdrive_connection_string(h) { return store(get(h).connectionString); },
  hyperdrive_host(h)              { return store(get(h).host); },
  hyperdrive_port(h)              { return get(h).port; },
  hyperdrive_user(h)              { return store(get(h).user); },
  hyperdrive_password(h)          { return store(get(h).password); },
  hyperdrive_database(h)          { return store(get(h).database); },

  // -- Service Binding (JSPI-suspending) ------------------------------------
  service_binding_fetch: susp(async (svcH, reqH) => {
    const svc = get(svcH);
    const req = get(reqH);
    const opts = { method: req.method, headers: req.headers };
    if (req.body) opts.body = req.body;
    drop(reqH);
    const resp = await svc.fetch(req.url, opts);
    const bodyBuf = new Uint8Array(await resp.arrayBuffer());
    return store({
      status: resp.status,
      _headers: resp.headers,
      _body: store(bodyBuf),
      _url: resp.url || "",
      _redirected: !!resp.redirected,
    });
  }),

  // -- Crypto (Web Crypto API) ------------------------------------------------
  crypto_digest: susp(async (algo, dp, dl) => {
    const algos = ["SHA-1", "SHA-256", "SHA-384", "SHA-512", "MD5"];
    const data = new Uint8Array(mem().buffer.slice(dp, dp + dl));
    const hash = await crypto.subtle.digest(algos[algo] || "SHA-256", data);
    return store(new Uint8Array(hash));
  }),
  crypto_hmac: susp(async (algo, kp, kl, dp, dl) => {
    const algos = ["SHA-1", "SHA-256", "SHA-384", "SHA-512", "MD5"];
    const hashName = algos[algo] || "SHA-256";
    const keyData = new Uint8Array(mem().buffer.slice(kp, kp + kl));
    const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: hashName }, false, ["sign"]);
    const sig = await crypto.subtle.sign("HMAC", key, new Uint8Array(mem().buffer.slice(dp, dp + dl)));
    return store(new Uint8Array(sig));
  }),
  crypto_hmac_verify: susp(async (algo, kp, kl, sp, sl, dp, dl) => {
    const algos = ["SHA-1", "SHA-256", "SHA-384", "SHA-512", "MD5"];
    const hashName = algos[algo] || "SHA-256";
    const keyData = new Uint8Array(mem().buffer.slice(kp, kp + kl));
    const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: hashName }, false, ["verify"]);
    const sig = new Uint8Array(mem().buffer.slice(sp, sp + sl));
    const data = new Uint8Array(mem().buffer.slice(dp, dp + dl));
    const ok = await crypto.subtle.verify("HMAC", key, sig, data);
    return ok ? 1 : 0;
  }),
  crypto_timing_safe_equal(ap, al, bp, bl) {
    if (al !== bl) return 0;
    const a = new Uint8Array(mem().buffer.slice(ap, ap + al));
    const b = new Uint8Array(mem().buffer.slice(bp, bp + bl));
    return crypto.subtle.timingSafeEqual(a, b) ? 1 : 0;
  },

  // -- EventSource (SSE) -----------------------------------------------------
  eventsource_connect(up, ul) {
    const url = readStr(up, ul);
    const es = new EventSource(url);
    // Wrap in our own object that queues events for pull-based consumption.
    const wrapper = { _es: es, _queue: [], _resolve: null, _done: false };
    es.onmessage = (e) => {
      const evt = { type: e.type || "message", data: e.data || "", lastEventId: e.lastEventId || "" };
      if (wrapper._resolve) { const r = wrapper._resolve; wrapper._resolve = null; r(evt); }
      else wrapper._queue.push(evt);
    };
    es.addEventListener("error", () => {
      wrapper._done = true;
      if (wrapper._resolve) { const r = wrapper._resolve; wrapper._resolve = null; r(null); }
    });
    return store(wrapper);
  },
  eventsource_from_stream(streamH) {
    const stream = get(streamH);
    const es = EventSource.from(stream);
    const wrapper = { _es: es, _queue: [], _resolve: null, _done: false };
    es.onmessage = (e) => {
      const evt = { type: e.type || "message", data: e.data || "", lastEventId: e.lastEventId || "" };
      if (wrapper._resolve) { const r = wrapper._resolve; wrapper._resolve = null; r(evt); }
      else wrapper._queue.push(evt);
    };
    es.addEventListener("error", () => {
      wrapper._done = true;
      if (wrapper._resolve) { const r = wrapper._resolve; wrapper._resolve = null; r(null); }
    });
    return store(wrapper);
  },
  eventsource_next: susp(async (wrapH) => {
    const w = get(wrapH);
    if (w._queue.length > 0) {
      return store(JSON.stringify(w._queue.shift()));
    }
    if (w._done) return 0;
    const evt = await new Promise(resolve => { w._resolve = resolve; });
    if (!evt) return 0;
    return store(JSON.stringify(evt));
  }),
  eventsource_ready_state(wrapH) { return get(wrapH)?._es?.readyState ?? 2; },
  eventsource_close(wrapH) {
    const w = get(wrapH);
    if (w?._es) w._es.close();
    w._done = true;
    if (w._resolve) { const r = w._resolve; w._resolve = null; r(null); }
  },

  // -- FormData ---------------------------------------------------------------
  formdata_from_request: susp(async (reqH) => {
    const req = get(reqH);
    // Build a native Request to parse the body as FormData.
    const nativeReq = new Request(req.url || "https://dummy/", {
      method: req.method || "POST",
      headers: req.headers,
      body: req._bodyBytes || undefined,
    });
    const fd = await nativeReq.formData();
    // Convert to an array of entries for indexed access.
    const entries = [];
    for (const [name, value] of fd.entries()) {
      entries.push({ name, value });
    }
    return store({ _fd: fd, _entries: entries });
  }),
  formdata_new() {
    const fd = new FormData();
    return store({ _fd: fd, _entries: [] });
  },
  formdata_get(fdH, np, nl) {
    const name = readStr(np, nl);
    const val = get(fdH)._fd.get(name);
    if (val == null) return 0;
    if (typeof val === "string") return store(val);
    // File — return text representation
    return store(val.name || "[file]");
  },
  formdata_get_all(fdH, np, nl) {
    const name = readStr(np, nl);
    const vals = get(fdH)._fd.getAll(name).map(v => typeof v === "string" ? v : v.name);
    return store(JSON.stringify(vals));
  },
  formdata_has(fdH, np, nl) {
    return get(fdH)._fd.has(readStr(np, nl)) ? 1 : 0;
  },
  formdata_keys(fdH) {
    const keys = [...get(fdH)._fd.keys()];
    return store(JSON.stringify(keys));
  },
  formdata_len(fdH) { return get(fdH)._entries.length; },
  formdata_entry_name(fdH, idx) {
    const e = get(fdH)._entries[idx];
    return e ? store(e.name) : 0;
  },
  formdata_entry_is_file(fdH, idx) {
    const e = get(fdH)._entries[idx];
    return (e && typeof e.value !== "string") ? 1 : 0;
  },
  formdata_entry_value(fdH, idx) {
    const e = get(fdH)._entries[idx];
    return (e && typeof e.value === "string") ? store(e.value) : 0;
  },
  formdata_entry_file_data: susp(async (fdH, idx) => {
    const e = get(fdH)._entries[idx];
    if (!e || typeof e.value === "string") return 0;
    const buf = await e.value.arrayBuffer();
    return store(new Uint8Array(buf));
  }),
  formdata_entry_file_name(fdH, idx) {
    const e = get(fdH)._entries[idx];
    return (e && typeof e.value !== "string") ? store(e.value.name || "") : 0;
  },
  formdata_entry_file_type(fdH, idx) {
    const e = get(fdH)._entries[idx];
    return (e && typeof e.value !== "string" && e.value.type) ? store(e.value.type) : 0;
  },
  formdata_delete(fdH, np, nl) {
    get(fdH)._fd.delete(readStr(np, nl));
    // Rebuild entries array
    const w = get(fdH);
    w._entries = [...w._fd.entries()].map(([name, value]) => ({ name, value }));
  },
  formdata_set(fdH, np, nl, vp, vl) {
    const w = get(fdH);
    const name = readStr(np, nl);
    const val = readStr(vp, vl);
    w._fd.set(name, val);
    w._entries = [...w._fd.entries()].map(([n, v]) => ({ name: n, value: v }));
  },
  formdata_append(fdH, np, nl, vp, vl) {
    const w = get(fdH);
    const name = readStr(np, nl);
    const val = readStr(vp, vl);
    w._fd.append(name, val);
    w._entries.push({ name, value: val });
  },
  formdata_append_file(fdH, np, nl, dp, dl, fp, fl) {
    const w = get(fdH);
    const name = readStr(np, nl);
    const data = new Uint8Array(mem().buffer.slice(dp, dp + dl));
    const filename = readStr(fp, fl);
    const blob = new Blob([data]);
    const file = new File([blob], filename);
    w._fd.append(name, file, filename);
    w._entries.push({ name, value: file });
  },

  // -- HTMLRewriter -----------------------------------------------------------
  html_rewriter_transform(respH, rp, rl) {
    const rules = JSON.parse(readStr(rp, rl));
    const rw = new HTMLRewriter();
    for (const rule of rules) {
      const { selector, action } = rule;
      if (selector === "__document_end__") {
        rw.onDocument({
          end(end) { end[action](rule.content, rule.html ? { html: true } : undefined); },
        });
        continue;
      }
      rw.on(selector, {
        element(el) {
          switch (action) {
            case "setAttribute": el.setAttribute(rule.name, rule.value); break;
            case "removeAttribute": el.removeAttribute(rule.name); break;
            case "setInnerContent": el.setInnerContent(rule.content, rule.html ? { html: true } : undefined); break;
            case "before": el.before(rule.content, rule.html ? { html: true } : undefined); break;
            case "after": el.after(rule.content, rule.html ? { html: true } : undefined); break;
            case "prepend": el.prepend(rule.content, rule.html ? { html: true } : undefined); break;
            case "append": el.append(rule.content, rule.html ? { html: true } : undefined); break;
            case "replace": el.replace(rule.content, rule.html ? { html: true } : undefined); break;
            case "remove": el.remove(); break;
            case "removeAndKeepContent": el.removeAndKeepContent(); break;
          }
        },
      });
    }
    // Build a native Response from our internal response object.
    const resp = get(respH);
    const body = resp._body ? get(resp._body) : resp.body;
    const nativeResp = new Response(body, {
      status: resp.status,
      headers: resp.headers || resp._headers,
    });
    const transformed = rw.transform(nativeResp);
    // Convert back to our internal format.
    return store({
      status: transformed.status,
      headers: transformed.headers,
      body: transformed.body,
      _isNative: true,
    });
  },

  // -- TCP Sockets ------------------------------------------------------------
  socket_connect(hp, hl, port, secureTransport, allowHalfOpen) {
    const hostname = readStr(hp, hl);
    const stMap = ["off", "on", "starttls"];
    const opts = {};
    if (secureTransport < 3) opts.secureTransport = stMap[secureTransport];
    if (allowHalfOpen) opts.allowHalfOpen = true;
    // connect() is imported from cloudflare:sockets at module scope
    const socket = _socketConnect({ hostname, port }, opts);
    return store(socket);
  },
  socket_get_writer(socketH) {
    return store(get(socketH).writable.getWriter());
  },
  socket_get_reader(socketH) {
    return store(get(socketH).readable.getReader());
  },
  socket_write: susp(async (writerH, ptr, len) => {
    const bytes = new Uint8Array(mem().buffer.slice(ptr, ptr + len));
    await get(writerH).write(bytes);
  }),
  socket_read: susp(async (readerH) => {
    const { value, done } = await get(readerH).read();
    if (done || !value) return 0;
    return store(new Uint8Array(value));
  }),
  socket_close: susp(async (socketH) => {
    await get(socketH).close();
  }),
  socket_close_writer: susp(async (writerH) => {
    await get(writerH).close();
  }),
  socket_start_tls(socketH) {
    const newSocket = get(socketH).startTls();
    return store(newSocket);
  },
  socket_opened: susp(async (socketH) => {
    const info = await get(socketH).opened;
    return store(JSON.stringify(info || {}));
  }),

  // -- Dynamic Dispatch (dispatch namespace) ---------------------------------
  dispatch_ns_get(nsH, np, nl, cpuMs, subReqs, op, ol) {
    const ns = get(nsH);
    const name = readStr(np, nl);
    const options = {};
    if (cpuMs > 0 || subReqs > 0) {
      options.limits = {};
      if (cpuMs > 0) options.limits.cpuMs = cpuMs;
      if (subReqs > 0) options.limits.subRequests = subReqs;
    }
    if (ol > 0) options.outbound = JSON.parse(readStr(op, ol));
    return store(ns.get(name, {}, options));
  },
  dispatch_ns_fetch: susp(async (fetcherH, reqH) => {
    const fetcher = get(fetcherH);
    const req = get(reqH);
    const opts = { method: req.method, headers: req.headers };
    if (req.body) opts.body = req.body;
    drop(reqH);
    const resp = await fetcher.fetch(req.url, opts);
    const bodyBuf = new Uint8Array(await resp.arrayBuffer());
    return store({
      status: resp.status,
      _headers: resp.headers,
      _body: store(bodyBuf),
      _url: resp.url || "",
      _redirected: !!resp.redirected,
    });
  }),

  // -- Vectorize (JSPI-suspending) -------------------------------------------
  vectorize_describe: susp(async (idxH) => {
    const info = await get(idxH).describe();
    return store(JSON.stringify(info));
  }),
  vectorize_query: susp(async (idxH, vp, vl, op, ol) => {
    // vp/vl is raw f32 bytes
    const floats = new Float32Array(mem().buffer.slice(vp, vp + vl));
    const vector = Array.from(floats);
    const opts = JSON.parse(readStr(op, ol));
    const result = await get(idxH).query(vector, opts);
    return store(JSON.stringify(result));
  }),
  vectorize_query_by_id: susp(async (idxH, ip, il, op, ol) => {
    const vectorId = readStr(ip, il);
    const opts = JSON.parse(readStr(op, ol));
    const result = await get(idxH).queryById(vectorId, opts);
    return store(JSON.stringify(result));
  }),
  vectorize_insert: susp(async (idxH, jp, jl) => {
    const vectors = JSON.parse(readStr(jp, jl));
    const result = await get(idxH).insert(vectors);
    return store(JSON.stringify(result));
  }),
  vectorize_upsert: susp(async (idxH, jp, jl) => {
    const vectors = JSON.parse(readStr(jp, jl));
    const result = await get(idxH).upsert(vectors);
    return store(JSON.stringify(result));
  }),
  vectorize_delete_by_ids: susp(async (idxH, jp, jl) => {
    const ids = JSON.parse(readStr(jp, jl));
    const result = await get(idxH).deleteByIds(ids);
    return store(JSON.stringify(result));
  }),
  vectorize_get_by_ids: susp(async (idxH, jp, jl) => {
    const ids = JSON.parse(readStr(jp, jl));
    const result = await get(idxH).getByIds(ids);
    return store(JSON.stringify(result));
  }),

  // -- Workflows (binding API — managing instances) --------------------------
  workflow_create: susp(async (bindingH, idp, idl, pp, pl) => {
    const wf = get(bindingH);
    const opts = {};
    if (idl > 0) opts.id = readStr(idp, idl);
    if (pl > 0) opts.params = JSON.parse(readStr(pp, pl));
    const instance = await wf.create(opts);
    return store(instance);
  }),
  workflow_get: susp(async (bindingH, idp, idl) => {
    const wf = get(bindingH);
    const instance = await wf.get(readStr(idp, idl));
    return store(instance);
  }),
  workflow_instance_id(instanceH) {
    return store(get(instanceH).id);
  },
  workflow_instance_pause: susp(async (instanceH) => {
    await get(instanceH).pause();
  }),
  workflow_instance_resume: susp(async (instanceH) => {
    await get(instanceH).resume();
  }),
  workflow_instance_terminate: susp(async (instanceH) => {
    await get(instanceH).terminate();
  }),
  workflow_instance_restart: susp(async (instanceH) => {
    await get(instanceH).restart();
  }),
  workflow_instance_status: susp(async (instanceH) => {
    const s = await get(instanceH).status();
    return store(JSON.stringify(s));
  }),
  workflow_instance_send_event: susp(async (instanceH, tp, tl, pp, pl) => {
    await get(instanceH).sendEvent({
      type: readStr(tp, tl),
      payload: JSON.parse(readStr(pp, pl)),
    });
  }),

  // -- Workflows (entrypoint API — step operations) -------------------------
  workflow_event_payload(eventH) {
    const event = get(eventH);
    const p = event.payload;
    return store(typeof p === "string" ? p : JSON.stringify(p));
  },
  workflow_event_timestamp(eventH) {
    const event = get(eventH);
    const ts = event.timestamp;
    return ts instanceof Date ? ts.getTime() : (typeof ts === "number" ? ts : 0);
  },
  workflow_event_instance_id(eventH) {
    return store(get(eventH).instanceId);
  },
  workflow_step_do: susp(async (stepH, np, nl, cp, cl, callbackIdx) => {
    const step = get(stepH);
    const name = readStr(np, nl);
    const configJson = readStr(cp, cl);
    const config = JSON.parse(configJson);
    const jsConfig = {};
    if (config.retries) {
      jsConfig.retries = {
        limit: config.retries.limit,
        delay: config.retries.delay,
        backoff: config.retries.backoff,
      };
    }
    if (config.timeout) jsConfig.timeout = config.timeout;
    // Call step.do with a real callback that invokes the Zig function.
    // On replay, step.do skips this callback entirely and returns cached result.
    // On first run, we create a new JSPI-suspendable stack so the callback
    // can itself call async imports (fetch, KV, etc.).
    const result = await step.do(name, jsConfig, async () => {
      const table = _inst.exports.__indirect_function_table;
      const fn = table.get(callbackIdx);
      let resultH;
      if (HAS_JSPI) {
        const promFn = WebAssembly.promising(fn);
        resultH = await promFn();
      } else {
        resultH = fn();
      }
      // The callback returns a handle to a JS value — retrieve and return it.
      const val = get(resultH);
      drop(resultH);
      return val;
    });
    return store(typeof result === "string" ? result : JSON.stringify(result));
  }),
  workflow_step_sleep: susp(async (stepH, np, nl, dp, dl) => {
    const step = get(stepH);
    await step.sleep(readStr(np, nl), readStr(dp, dl));
  }),
  workflow_step_sleep_until: susp(async (stepH, np, nl, ts) => {
    const step = get(stepH);
    await step.sleepUntil(readStr(np, nl), new Date(ts));
  }),
  workflow_step_wait_for_event: susp(async (stepH, np, nl, tp, tl, top, tol) => {
    const step = get(stepH);
    const name = readStr(np, nl);
    const opts = { type: readStr(tp, tl) };
    if (tol > 0) opts.timeout = readStr(top, tol);
    const event = await step.waitForEvent(name, opts);
    return store(JSON.stringify(event));
  }),

  // -- Email ------------------------------------------------------------------
  email_from(h)  { return store(get(h).from); },
  email_to(h)    { return store(get(h).to); },
  email_raw_size(h) { return get(h).rawSize || 0; },
  email_header(h, np, nl) {
    const name = readStr(np, nl);
    const val = get(h).headers.get(name);
    return val != null ? store(val) : 0;
  },
  email_raw_body: susp(async (h) => {
    const msg = get(h);
    const reader = msg.raw.getReader();
    const chunks = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
    }
    const total = chunks.reduce((s, c) => s + c.byteLength, 0);
    const result = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) { result.set(c, offset); offset += c.byteLength; }
    return store(result);
  }),
  email_set_reject(h, rp, rl) { get(h).setReject(readStr(rp, rl)); },
  email_forward: susp(async (h, rp, rl) => {
    await get(h).forward(readStr(rp, rl));
  }),
  email_reply: susp(async (h, rp, rl) => {
    const raw = readStr(rp, rl);
    // Create a simple EmailMessage-like object for reply
    const msg = new Response(raw);
    await get(h).reply(msg);
  }),

  // -- Send Email --------------------------------------------------------------
  send_email: susp(async (bindingH, jp, jl) => {
    const binding = get(bindingH);
    const msg = JSON.parse(readStr(jp, jl));
    const result = await binding.send(msg);
    return store(JSON.stringify(result));
  }),

  // -- Scheduled event -------------------------------------------------------
  scheduled_cron(h)  { return store(get(h).cron); },
  scheduled_time(h)  { return get(h).scheduledTime; },

  // -- Timers ----------------------------------------------------------------
  js_sleep: susp(async (ms) => { await new Promise(r => setTimeout(r, ms)); }),

  // -- Time ------------------------------------------------------------------
  js_now() { return Date.now(); },

  // -- Console ---------------------------------------------------------------
  console_log(ptr, len) { console.log(readStr(ptr, len)); },
  console_error(ptr, len) { console.error(readStr(ptr, len)); },
};

// ---------------------------------------------------------------------------
// WASI shim – wasi_snapshot_preview1
//
// Provides the subset of WASI syscalls that Zig's standard library uses on
// wasm32-wasi: time, randomness, and fd I/O for debug/panic output.
// ---------------------------------------------------------------------------
const WASI_SUCCESS = 0;
const WASI_EBADF = 8;
const WASI_EINVAL = 28;
const WASI_ENOSYS = 52;

const wasi_imports = {
  // -- Clock ----------------------------------------------------------------
  // clock_res_get(clock_id: u32, retptr: u32) -> errno
  // Returns the resolution of the given clock in nanoseconds.
  clock_res_get(clock_id, retptr) {
    const view = new DataView(mem().buffer);
    // Report 1ms resolution (1_000_000 ns) — matches Date.now() precision.
    view.setBigUint64(retptr, 1_000_000n, true);
    return WASI_SUCCESS;
  },

  // clock_time_get(clock_id: u32, precision: u64, retptr: u32) -> errno
  // Returns nanoseconds since epoch. All clock IDs map to Date.now().
  clock_time_get(clock_id, precision_lo, precision_hi, retptr) {
    const view = new DataView(mem().buffer);
    const now_ns = BigInt(Date.now()) * 1_000_000n;
    view.setBigUint64(retptr, now_ns, true);
    return WASI_SUCCESS;
  },

  // -- Random ---------------------------------------------------------------
  // random_get(buf: u32, buf_len: u32) -> errno
  random_get(buf, buf_len) {
    const bytes = new Uint8Array(mem().buffer, buf, buf_len);
    crypto.getRandomValues(bytes);
    return WASI_SUCCESS;
  },

  // -- File descriptor I/O --------------------------------------------------
  // fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) -> errno
  // Only handles stdout(1) and stderr(2) — routes to console.log/error.
  fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) {
    if (fd !== 1 && fd !== 2) return WASI_EBADF;
    const view = new DataView(mem().buffer);
    let written = 0;
    let output = "";
    for (let i = 0; i < iovs_len; i++) {
      const ptr = view.getUint32(iovs_ptr + i * 8, true);
      const len = view.getUint32(iovs_ptr + i * 8 + 4, true);
      output += new TextDecoder().decode(new Uint8Array(mem().buffer, ptr, len));
      written += len;
    }
    if (fd === 1) console.log(output);
    else console.error(output);
    view.setUint32(nwritten_ptr, written, true);
    return WASI_SUCCESS;
  },

  // fd_read(fd, iovs_ptr, iovs_len, nread_ptr) -> errno
  // stdin is not supported in Workers.
  fd_read(fd, iovs_ptr, iovs_len, nread_ptr) {
    const view = new DataView(mem().buffer);
    view.setUint32(nread_ptr, 0, true);
    return WASI_SUCCESS;
  },

  // fd_seek(fd, offset_lo, offset_hi, whence, newoffset_ptr) -> errno
  fd_seek(fd, offset_lo, offset_hi, whence, newoffset_ptr) {
    return WASI_ENOSYS;
  },

  // fd_filestat_get(fd, retptr) -> errno
  fd_filestat_get(fd, retptr) {
    return WASI_ENOSYS;
  },

  // fd_pwrite(fd, iovs_ptr, iovs_len, offset_lo, offset_hi, nwritten_ptr) -> errno
  fd_pwrite(fd, iovs_ptr, iovs_len, offset_lo, offset_hi, nwritten_ptr) {
    // Delegate to fd_write for stdout/stderr
    return wasi_imports.fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr);
  },

  // fd_close(fd) -> errno
  fd_close(fd) { return WASI_SUCCESS; },

  // proc_exit(code) — terminates the Wasm instance.
  proc_exit(code) { throw new Error(`[workers-zig] proc_exit(${code})`); },

  // fd_pread(fd, iovs_ptr, iovs_len, offset_lo, offset_hi, nread_ptr) -> errno
  fd_pread(fd, iovs_ptr, iovs_len, offset_lo, offset_hi, nread_ptr) {
    const view = new DataView(mem().buffer);
    view.setUint32(nread_ptr, 0, true);
    return WASI_ENOSYS;
  },

  // fd_sync(fd) -> errno
  fd_sync(fd) { return WASI_ENOSYS; },

  // fd_filestat_set_times(fd, atim_lo, atim_hi, mtim_lo, mtim_hi, fst_flags) -> errno
  fd_filestat_set_times(fd, atim_lo, atim_hi, mtim_lo, mtim_hi, fst_flags) { return WASI_ENOSYS; },

  // fd_filestat_set_size(fd, size_lo, size_hi) -> errno
  fd_filestat_set_size(fd, size_lo, size_hi) { return WASI_ENOSYS; },

  // fd_readdir(fd, buf, buf_len, cookie_lo, cookie_hi, bufused_ptr) -> errno
  fd_readdir(fd, buf, buf_len, cookie_lo, cookie_hi, bufused_ptr) {
    const view = new DataView(mem().buffer);
    view.setUint32(bufused_ptr, 0, true);
    return WASI_ENOSYS;
  },

  // -- Path operations (not supported in Workers) ----------------------------
  path_open(fd, dirflags, path, path_len, oflags, fs_rights_base_lo, fs_rights_base_hi, fs_rights_inheriting_lo, fs_rights_inheriting_hi, fdflags, opened_fd_ptr) { return WASI_ENOSYS; },
  path_filestat_get(fd, flags, path, path_len, retptr) { return WASI_ENOSYS; },
  path_create_directory(fd, path, path_len) { return WASI_ENOSYS; },
  path_link(old_fd, old_flags, old_path, old_path_len, new_fd, new_path, new_path_len) { return WASI_ENOSYS; },
  path_symlink(old_path, old_path_len, fd, new_path, new_path_len) { return WASI_ENOSYS; },
  path_readlink(fd, path, path_len, buf, buf_len, bufused_ptr) {
    const view = new DataView(mem().buffer);
    view.setUint32(bufused_ptr, 0, true);
    return WASI_ENOSYS;
  },
  path_rename(fd, old_path, old_path_len, new_fd, new_path, new_path_len) { return WASI_ENOSYS; },
  path_remove_directory(fd, path, path_len) { return WASI_ENOSYS; },
  path_unlink_file(fd, path, path_len) { return WASI_ENOSYS; },

  // -- Stubs for env/args/prestat --------------------------------------------
  environ_get(environ, environ_buf) { return WASI_SUCCESS; },
  environ_sizes_get(count_ptr, buf_size_ptr) {
    const view = new DataView(mem().buffer);
    view.setUint32(count_ptr, 0, true);
    view.setUint32(buf_size_ptr, 0, true);
    return WASI_SUCCESS;
  },
  args_get(argv, argv_buf) { return WASI_SUCCESS; },
  args_sizes_get(argc_ptr, buf_size_ptr) {
    const view = new DataView(mem().buffer);
    view.setUint32(argc_ptr, 0, true);
    view.setUint32(buf_size_ptr, 0, true);
    return WASI_SUCCESS;
  },
  fd_prestat_get(fd, retptr) { return WASI_EBADF; },
  fd_prestat_dir_name(fd, path, path_len) { return WASI_EBADF; },
  fd_fdstat_get(fd, retptr) { return WASI_EBADF; },
  sched_yield() { return WASI_SUCCESS; },
  poll_oneoff(in_ptr, out_ptr, nsubscriptions, nevents_ptr) { return WASI_ENOSYS; },
};

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------
async function init() {
  if (_inst) return;
  _inst = await WebAssembly.instantiate(wasm, {
    env: env_imports,
    wasi_snapshot_preview1: wasi_imports,
  });
}

// ---------------------------------------------------------------------------
// Durable Object class factory
//
// Creates a JS class for a Durable Object type by looking up the
// corresponding Wasm exports: do_<name>_fetch, do_<name>_alarm, etc.
// Usage (in a wrapper entry.js):
//   import { _makeDOClass } from "./shim.js";
//   export const Counter = _makeDOClass("Counter");
// ---------------------------------------------------------------------------
export function _makeDOClass(name) {
  const cls = class extends _DurableObjectBase {
    constructor(state, env) {
      super(state, env);
      this._stateH = store(state);
      this._envH = store(env);
    }

    async fetch(request) {
      await init();
      const fn = _inst.exports[`do_${name}_fetch`];
      if (!fn) throw new Error(`[workers-zig] DO class "${name}" has no fetch export`);

      const bodyBytes = request.body ? await request.arrayBuffer() : null;
      const reqData = {
        method: request.method,
        url: request.url,
        headers: request.headers,
        _bodyBytes: bodyBytes,
      };
      const rh = store(reqData);

      try {
        const fetchFn = HAS_JSPI ? WebAssembly.promising(fn) : fn;
        const handle = HAS_JSPI
          ? await fetchFn(this._stateH, this._envH, rh)
          : fn(this._stateH, this._envH, rh);

        if (handle === 0) {
          drop(rh);
          return new Response(null, { status: 204 });
        }

        const resp = get(handle);
        const out = new Response(resp.body, {
          status: resp.status,
          headers: resp.headers,
        });
        drop(handle);
        drop(rh);
        return out;
      } catch (e) {
        drop(rh);
        console.error(`[workers-zig] DO ${name}.fetch error:`, e);
        return new Response("Internal Server Error\n" + e.stack, { status: 500 });
      }
    }

    async alarm(alarmInfo) {
      await init();
      const fn = _inst.exports[`do_${name}_alarm`];
      if (!fn) return;

      try {
        const alarmFn = HAS_JSPI ? WebAssembly.promising(fn) : fn;
        HAS_JSPI
          ? await alarmFn(this._stateH, this._envH)
          : fn(this._stateH, this._envH);
      } catch (e) {
        console.error(`[workers-zig] DO ${name}.alarm error:`, e);
      }
    }
  };
  return cls;
}

// ---------------------------------------------------------------------------
// Workflow class factory
//
// Creates a JS class for a Workflow type by looking up the corresponding
// Wasm export: wf_<name>_run. The class extends WorkflowEntrypoint from
// cloudflare:workers.
// Usage (in entry.js):
//   import { _makeWorkflowClass } from "./shim.js";
//   export const MyWorkflow = _makeWorkflowClass("MyWorkflow");
// ---------------------------------------------------------------------------
export function _makeWorkflowClass(name) {
  const cls = class extends _WorkflowBase {
    async run(event, step) {
      await init();
      const fn = _inst.exports[`wf_${name}_run`];
      if (!fn) throw new Error(`[workers-zig] Workflow "${name}" has no run export`);

      const eventH = store(event);
      const stepH = store(step);
      const envH = store(this.env);

      try {
        const runFn = HAS_JSPI ? WebAssembly.promising(fn) : fn;
        HAS_JSPI
          ? await runFn(eventH, stepH, envH)
          : fn(eventH, stepH, envH);
      } catch (e) {
        console.error(`[workers-zig] Workflow ${name}.run error:`, e);
        throw e;
      } finally {
        drop(eventH);
        drop(stepH);
        drop(envH);
      }
    }
  };
  return cls;
}

// ---------------------------------------------------------------------------
// Workers entry point
// ---------------------------------------------------------------------------
export default {
  async scheduled(event, workerEnv, ctx) {
    await init();
    if (!_inst.exports.scheduled) return;   // user didn't define a handler

    const eh = store(event);
    const envH = store(workerEnv);
    const ch = store(ctx);

    try {
      const scheduledFn = HAS_JSPI
        ? WebAssembly.promising(_inst.exports.scheduled)
        : _inst.exports.scheduled;

      HAS_JSPI
        ? await scheduledFn(eh, envH, ch)
        : scheduledFn(eh, envH, ch);
    } catch (e) {
      console.error("[workers-zig] scheduled handler error:", e);
    } finally {
      drop(eh);
      drop(envH);
      drop(ch);
    }
  },

  async queue(batch, workerEnv, ctx) {
    await init();
    if (!_inst.exports.queue) return;   // user didn't define a handler

    const bh = store(batch);
    const envH = store(workerEnv);
    const ch = store(ctx);

    try {
      const queueFn = HAS_JSPI
        ? WebAssembly.promising(_inst.exports.queue)
        : _inst.exports.queue;

      HAS_JSPI
        ? await queueFn(bh, envH, ch)
        : queueFn(bh, envH, ch);
    } catch (e) {
      console.error("[workers-zig] queue handler error:", e);
      throw e; // re-throw so the batch is retried
    } finally {
      drop(bh);
      drop(envH);
      drop(ch);
    }
  },

  async email(message, workerEnv, ctx) {
    await init();
    if (!_inst.exports.email) return;

    const mh = store(message);
    const envH = store(workerEnv);
    const ch = store(ctx);

    try {
      const emailFn = HAS_JSPI
        ? WebAssembly.promising(_inst.exports.email)
        : _inst.exports.email;

      HAS_JSPI
        ? await emailFn(mh, envH, ch)
        : emailFn(mh, envH, ch);
    } catch (e) {
      console.error("[workers-zig] email handler error:", e);
      throw e;
    } finally {
      drop(mh);
      drop(envH);
      drop(ch);
    }
  },

  async tail(events, workerEnv, ctx) {
    await init();
    if (!_inst.exports.tail) return;   // user didn't define a handler

    // Serialize TraceItem[] to JSON and pass as a string handle.
    const jsonStr = JSON.stringify(events, (key, value) => {
      // Convert Date objects to millisecond timestamps
      if (value instanceof Date) return value.getTime();
      return value;
    });
    const eventsH = store(jsonStr);
    const envH = store(workerEnv);
    const ch = store(ctx);

    try {
      const tailFn = HAS_JSPI
        ? WebAssembly.promising(_inst.exports.tail)
        : _inst.exports.tail;

      HAS_JSPI
        ? await tailFn(eventsH, envH, ch)
        : tailFn(eventsH, envH, ch);
    } catch (e) {
      console.error("[workers-zig] tail handler error:", e);
    } finally {
      drop(eventsH);
      drop(envH);
      drop(ch);
    }
  },

  async fetch(request, workerEnv, ctx) {
    await init();

    const bodyBytes = request.body ? await request.arrayBuffer() : null;
    const reqData = {
      method: request.method,
      url: request.url,
      headers: request.headers,
      _bodyBytes: bodyBytes,
      cf: request.cf || null,
    };

    const rh = store(reqData);
    const eh = store(workerEnv);
    const ch = store(ctx);

    try {
      const fetchFn = HAS_JSPI
        ? WebAssembly.promising(_inst.exports.fetch)
        : _inst.exports.fetch;

      // Set up promises that resolve if Wasm starts streaming or a WebSocket.
      // response_stream_start() / ws_accept() (non-suspending) resolve these,
      // then the next JSPI-suspending call gives the JS event loop a chance to
      // pick up the resolved promise via the race.
      const streamPromise = new Promise(r => { _streamResolve = r; });
      const wsPromise = new Promise(r => { _wsResolve = r; });

      const wasmPromise = HAS_JSPI
        ? fetchFn(rh, eh, ch)
        : Promise.resolve(fetchFn(rh, eh, ch));

      // Race: normal return vs. early streaming / websocket signal.
      const result = await Promise.race([
        wasmPromise.then(handle => ({ type: "normal", handle })),
        streamPromise.then(streamObj => ({ type: "stream", streamObj })),
        wsPromise.then(pair => ({ type: "websocket", pair })),
      ]);

      if (result.type === "websocket") {
        const p = result.pair;
        // Wasm is still running the receive loop — keep it alive.
        ctx.waitUntil(wasmPromise.catch(e => {
          console.error("[workers-zig] websocket handler error:", e);
        }).finally(() => { drop(rh); drop(eh); drop(ch); }));
        _streamResolve = null;
        return new Response(null, {
          status: 101,
          webSocket: p.client,
        });
      }

      if (result.type === "stream") {
        const s = result.streamObj;
        _wsResolve = null;
        // Wasm is still writing chunks in the background — keep it alive.
        // Handles are cleaned up when the Wasm handler finishes.
        ctx.waitUntil(wasmPromise.catch(e => {
          console.error("[workers-zig] streaming handler error:", e);
        }).finally(() => { drop(rh); drop(eh); drop(ch); }));
        return new Response(s.readable, {
          status: s.status,
          headers: s.headers,
        });
      }

      // Normal (buffered) response.
      _streamResolve = null;
      _wsResolve = null;
      const resp = get(result.handle);
      const out = new Response(resp.body, {
        status: resp.status,
        headers: resp.headers,
      });
      drop(result.handle);
      drop(rh); drop(eh); drop(ch);
      return out;
    } catch (e) {
      _streamResolve = null;
      _wsResolve = null;
      console.error("[workers-zig] handler error:", e);
      drop(rh); drop(eh); drop(ch);
      return new Response("Internal Server Error\n" + e.stack, { status: 500 });
    }
  },
};
