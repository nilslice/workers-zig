const std = @import("std");

/// Opaque handle to a JavaScript object managed by the JS runtime.
pub const Handle = u32;

/// Sentinel value representing null/undefined in JS.
pub const null_handle: Handle = 0;

// ---------------------------------------------------------------------------
// Extern declarations – provided by the JS shim at Wasm instantiation time.
// All live under the "env" import namespace.
//
// Functions marked "JSPI" are wrapped with WebAssembly.Suspending on the JS
// side.  From Zig's perspective they are ordinary synchronous imports – JSPI
// transparently suspends and resumes the Wasm stack.
// ---------------------------------------------------------------------------

// -- String / bytes helpers --------------------------------------------------
pub extern "env" fn js_string_len(handle: Handle) u32;
pub extern "env" fn js_string_read(handle: Handle, ptr: [*]u8) void;
pub extern "env" fn js_bytes_len(handle: Handle) u32;
pub extern "env" fn js_bytes_read(handle: Handle, ptr: [*]u8) void;
pub extern "env" fn js_release(handle: Handle) void;
pub extern "env" fn js_store_string(ptr: [*]const u8, len: u32) Handle;

// -- Generic object property access -----------------------------------------
pub extern "env" fn js_get_string_prop(obj: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn js_get_int_prop(obj: Handle, name_ptr: [*]const u8, name_len: u32) i64;
pub extern "env" fn js_get_float_prop(obj: Handle, name_ptr: [*]const u8, name_len: u32) f64;

// -- Request -----------------------------------------------------------------
pub extern "env" fn request_method(handle: Handle) u32;
pub extern "env" fn request_url(handle: Handle) Handle;
pub extern "env" fn request_header(handle: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn request_body_len(handle: Handle) u32;
pub extern "env" fn request_body_read(handle: Handle, ptr: [*]u8) void;
pub extern "env" fn request_cf(handle: Handle) Handle;
pub extern "env" fn request_headers_entries(handle: Handle) Handle;

// -- Response ----------------------------------------------------------------
pub extern "env" fn response_new() Handle;
pub extern "env" fn response_set_status(handle: Handle, status: u32) void;
pub extern "env" fn response_set_header(
    handle: Handle,
    name_ptr: [*]const u8,
    name_len: u32,
    val_ptr: [*]const u8,
    val_len: u32,
) void;
pub extern "env" fn response_set_body(handle: Handle, ptr: [*]const u8, len: u32) void;
pub extern "env" fn response_redirect(url_ptr: [*]const u8, url_len: u32, status: u32) Handle;
pub extern "env" fn response_clone(handle: Handle) Handle;

// -- Context (ExecutionContext) -----------------------------------------------
pub extern "env" fn ctx_wait_until(ctx: Handle, promise: Handle) void;
pub extern "env" fn ctx_pass_through_on_exception(ctx: Handle) void;

// -- Env (bindings) ----------------------------------------------------------
pub extern "env" fn env_get_text_binding(handle: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn env_get_binding(handle: Handle, name_ptr: [*]const u8, name_len: u32) Handle;

// -- KV (JSPI-suspending) ----------------------------------------------------
pub extern "env" fn kv_get(kv: Handle, key_ptr: [*]const u8, key_len: u32) Handle;
pub extern "env" fn kv_get_blob(kv: Handle, key_ptr: [*]const u8, key_len: u32) Handle;
pub extern "env" fn kv_get_with_metadata(kv: Handle, key_ptr: [*]const u8, key_len: u32) Handle;
pub extern "env" fn kv_meta_value(result: Handle) Handle;
pub extern "env" fn kv_meta_metadata(result: Handle) Handle;
pub extern "env" fn kv_put_string(kv: Handle, key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32, ttl: i64, expiration: i64, meta_ptr: [*]const u8, meta_len: u32) void;
pub extern "env" fn kv_put_blob(kv: Handle, key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32, ttl: i64, expiration: i64, meta_ptr: [*]const u8, meta_len: u32) void;
pub extern "env" fn kv_delete(kv: Handle, key_ptr: [*]const u8, key_len: u32) void;
pub extern "env" fn kv_list(kv: Handle, prefix_ptr: [*]const u8, prefix_len: u32, cursor_ptr: [*]const u8, cursor_len: u32, limit: u32) Handle;

// -- R2 (JSPI-suspending) ----------------------------------------------------
pub extern "env" fn r2_head(bucket: Handle, key_ptr: [*]const u8, key_len: u32) Handle;
pub extern "env" fn r2_get(bucket: Handle, key_ptr: [*]const u8, key_len: u32) Handle;
pub extern "env" fn r2_put(bucket: Handle, key_ptr: [*]const u8, key_len: u32, body_ptr: [*]const u8, body_len: u32, content_type_ptr: [*]const u8, content_type_len: u32) Handle;
pub extern "env" fn r2_delete(bucket: Handle, key_ptr: [*]const u8, key_len: u32) void;
pub extern "env" fn r2_list(bucket: Handle, prefix_ptr: [*]const u8, prefix_len: u32, cursor_ptr: [*]const u8, cursor_len: u32, limit: u32) Handle;

// -- D1 (JSPI-suspending) ----------------------------------------------------
pub extern "env" fn d1_exec(db: Handle, sql_ptr: [*]const u8, sql_len: u32) Handle;
pub extern "env" fn d1_query_all(db: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) Handle;
pub extern "env" fn d1_query_first(db: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) Handle;
pub extern "env" fn d1_query_run(db: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) Handle;

// -- Fetch (outbound HTTP) ---------------------------------------------------
// Request building (non-suspending)
pub extern "env" fn fetch_create_request(url_ptr: [*]const u8, url_len: u32, method: u32) Handle;
pub extern "env" fn fetch_request_set_header(req: Handle, name_ptr: [*]const u8, name_len: u32, val_ptr: [*]const u8, val_len: u32) void;
pub extern "env" fn fetch_request_set_body(req: Handle, body_ptr: [*]const u8, body_len: u32) void;
pub extern "env" fn fetch_request_set_form_data(req: Handle, fd: Handle) void;

// Sync send (JSPI-suspending) – returns response handle
pub extern "env" fn fetch_send(req: Handle) Handle;

// Response reading (non-suspending)
pub extern "env" fn fetch_response_status(resp: Handle) u32;
pub extern "env" fn fetch_response_header(resp: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn fetch_response_body(resp: Handle) Handle;
pub extern "env" fn fetch_response_url(resp: Handle) Handle;
pub extern "env" fn fetch_response_redirected(resp: Handle) u32;

// -- Fetch response WebSocket extraction (non-suspending) -------------------
pub extern "env" fn fetch_response_websocket(resp: Handle) Handle;

// -- Async scheduling (non-suspending) ---------------------------------------
// These start a JS Promise immediately but do NOT suspend Wasm.
// They return a future index into the pending-results array.
pub extern "env" fn async_kv_get(kv: Handle, key_ptr: [*]const u8, key_len: u32) u32;
pub extern "env" fn async_kv_get_blob(kv: Handle, key_ptr: [*]const u8, key_len: u32) u32;
pub extern "env" fn async_kv_put(kv: Handle, key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32, ttl: i64) u32;
pub extern "env" fn async_kv_delete(kv: Handle, key_ptr: [*]const u8, key_len: u32) u32;

pub extern "env" fn async_r2_get(bucket: Handle, key_ptr: [*]const u8, key_len: u32) u32;
pub extern "env" fn async_r2_head(bucket: Handle, key_ptr: [*]const u8, key_len: u32) u32;
pub extern "env" fn async_r2_put(bucket: Handle, key_ptr: [*]const u8, key_len: u32, body_ptr: [*]const u8, body_len: u32, ct_ptr: [*]const u8, ct_len: u32) u32;
pub extern "env" fn async_r2_delete(bucket: Handle, key_ptr: [*]const u8, key_len: u32) u32;

pub extern "env" fn async_d1_exec(db: Handle, sql_ptr: [*]const u8, sql_len: u32) u32;
pub extern "env" fn async_d1_query_all(db: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) u32;
pub extern "env" fn async_d1_query_first(db: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) u32;
pub extern "env" fn async_d1_query_run(db: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) u32;

pub extern "env" fn async_fetch(req: Handle) u32;

// -- Async flush (JSPI-suspending) -------------------------------------------
// Awaits all pending promises via Promise.all.  Returns a handle to the
// results array.  Single JSPI suspension regardless of how many ops queued.
pub extern "env" fn async_flush() Handle;

// -- Async result retrieval (non-suspending) ---------------------------------
pub extern "env" fn async_get_result(results: Handle, index: u32) Handle;
pub extern "env" fn async_release_results(results: Handle) void;

// -- Streaming response ------------------------------------------------------
// response_stream_start is NON-suspending – it creates the TransformStream
// and resolves the early-response promise so the JS fetch handler can return
// the Response immediately.
pub extern "env" fn response_stream_start(status: u32) Handle;
pub extern "env" fn response_stream_set_header(stream: Handle, name_ptr: [*]const u8, name_len: u32, val_ptr: [*]const u8, val_len: u32) void;
// JSPI-suspending – each write flushes to the client.
pub extern "env" fn response_stream_write(stream: Handle, ptr: [*]const u8, len: u32) void;
pub extern "env" fn response_stream_close(stream: Handle) void;

// -- Cache (JSPI-suspending except cache_default) ----------------------------
pub extern "env" fn cache_default() Handle;
pub extern "env" fn cache_open(name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn cache_match(cache: Handle, url_ptr: [*]const u8, url_len: u32) Handle;
pub extern "env" fn cache_put(cache: Handle, url_ptr: [*]const u8, url_len: u32, resp: Handle) void;
pub extern "env" fn cache_delete(cache: Handle, url_ptr: [*]const u8, url_len: u32) u32;
pub extern "env" fn cache_match_request(cache: Handle, req: Handle) Handle;
pub extern "env" fn cache_put_request(cache: Handle, req: Handle, resp: Handle) void;
pub extern "env" fn cache_delete_request(cache: Handle, req: Handle) u32;

// -- Durable Objects: Namespace / Id / Stub (non-suspending except stub_fetch)
pub extern "env" fn do_ns_id_from_name(ns: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn do_ns_id_from_string(ns: Handle, id_ptr: [*]const u8, id_len: u32) Handle;
pub extern "env" fn do_ns_new_unique_id(ns: Handle) Handle;
pub extern "env" fn do_ns_get(ns: Handle, id: Handle) Handle;
pub extern "env" fn do_id_to_string(id: Handle) Handle;
pub extern "env" fn do_id_equals(id1: Handle, id2: Handle) u32;
pub extern "env" fn do_id_name(id: Handle) Handle;
pub extern "env" fn do_stub_fetch(stub: Handle, req: Handle) Handle; // JSPI-suspending

// -- Durable Objects: State / Storage (JSPI-suspending except state_id) ------
pub extern "env" fn do_state_id(state: Handle) Handle;
pub extern "env" fn do_storage_get(state: Handle, key_ptr: [*]const u8, key_len: u32) Handle;
pub extern "env" fn do_storage_put(state: Handle, key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32) void;
pub extern "env" fn do_storage_delete(state: Handle, key_ptr: [*]const u8, key_len: u32) u32;
pub extern "env" fn do_storage_delete_all(state: Handle) void;
pub extern "env" fn do_storage_list(state: Handle, opts: Handle) Handle;
pub extern "env" fn do_storage_list_options(
    prefix_ptr: [*]const u8,
    prefix_len: u32,
    start_ptr: [*]const u8,
    start_len: u32,
    end_ptr: [*]const u8,
    end_len: u32,
    limit: u32,
    reverse: u32,
) Handle;
pub extern "env" fn do_storage_get_alarm(state: Handle) f64;
pub extern "env" fn do_storage_set_alarm(state: Handle, time_ms: f64) void;
pub extern "env" fn do_storage_delete_alarm(state: Handle) void;

// -- Durable Objects: Facets ------------------------------------------------
// facets_get is JSPI-suspending; abort and delete are synchronous.
pub extern "env" fn do_facets_get(state: Handle, name_ptr: [*]const u8, name_len: u32, class_handle: Handle, id_ptr: [*]const u8, id_len: u32) Handle;
pub extern "env" fn do_facets_abort(state: Handle, name_ptr: [*]const u8, name_len: u32, reason_ptr: [*]const u8, reason_len: u32) void;
pub extern "env" fn do_facets_delete(state: Handle, name_ptr: [*]const u8, name_len: u32) void;

// -- Durable Objects: SQL Storage (synchronous – no JSPI) -------------------
pub extern "env" fn do_sql_exec(state: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) Handle;
pub extern "env" fn do_sql_cursor_open(state: Handle, sql_ptr: [*]const u8, sql_len: u32, params_ptr: [*]const u8, params_len: u32) Handle;
pub extern "env" fn do_sql_cursor_next(cursor: Handle) Handle;
pub extern "env" fn do_sql_cursor_column_names(cursor: Handle) Handle;
pub extern "env" fn do_sql_cursor_rows_read(cursor: Handle) f64;
pub extern "env" fn do_sql_cursor_rows_written(cursor: Handle) f64;
pub extern "env" fn do_sql_database_size(state: Handle) f64;

// -- WebSocket ---------------------------------------------------------------
// ws_pair_new and ws_accept are non-suspending.
// ws_receive is JSPI-suspending.
// ws_send_text, ws_send_binary, ws_close are non-suspending.
pub extern "env" fn ws_pair_new() Handle;
pub extern "env" fn ws_accept(pair: Handle) void;
pub extern "env" fn ws_client_accept(raw_ws: Handle) Handle;
pub extern "env" fn ws_send_text(pair: Handle, ptr: [*]const u8, len: u32) void;
pub extern "env" fn ws_send_binary(pair: Handle, ptr: [*]const u8, len: u32) void;
pub extern "env" fn ws_close(pair: Handle, code: u32, reason_ptr: [*]const u8, reason_len: u32) void;
pub extern "env" fn ws_receive(pair: Handle) Handle; // JSPI-suspending
pub extern "env" fn ws_event_type(event: Handle) u32;
pub extern "env" fn ws_event_text_len(event: Handle) u32;
pub extern "env" fn ws_event_text_read(event: Handle, ptr: [*]u8) void;
pub extern "env" fn ws_event_binary_len(event: Handle) u32;
pub extern "env" fn ws_event_binary_read(event: Handle, ptr: [*]u8) void;
pub extern "env" fn ws_event_close_code(event: Handle) u32;
pub extern "env" fn ws_event_close_reason_len(event: Handle) u32;
pub extern "env" fn ws_event_close_reason_read(event: Handle, ptr: [*]u8) void;

// -- Containers (on DurableObjectState) ------------------------------------
// Sync
pub extern "env" fn ct_running(state: Handle) u32;
pub extern "env" fn ct_start(state: Handle, opts: Handle) void;
pub extern "env" fn ct_signal(state: Handle, signo: u32) void;
pub extern "env" fn ct_get_tcp_port(state: Handle, port: u32) Handle;
// JSPI-suspending
pub extern "env" fn ct_monitor(state: Handle) void;
pub extern "env" fn ct_destroy(state: Handle, reason_ptr: [*]const u8, reason_len: u32) void;
pub extern "env" fn ct_set_inactivity_timeout(state: Handle, ms: u32) void;
pub extern "env" fn ct_intercept_outbound_http(state: Handle, addr_ptr: [*]const u8, addr_len: u32, fetcher: Handle) void;
pub extern "env" fn ct_intercept_all_outbound_http(state: Handle, fetcher: Handle) void;
pub extern "env" fn ct_intercept_outbound_https(state: Handle, addr_ptr: [*]const u8, addr_len: u32, fetcher: Handle) void;
pub extern "env" fn ct_snapshot_directory(state: Handle, dir_ptr: [*]const u8, dir_len: u32, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn ct_snapshot_container(state: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
// Startup options builder (non-suspending)
pub extern "env" fn ct_opts_new(enable_internet: u32) Handle;
pub extern "env" fn ct_opts_set_entrypoint(opts: Handle, ep_ptr: [*]const u8, ep_len: u32) void;
pub extern "env" fn ct_opts_set_env(opts: Handle, key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32) void;
pub extern "env" fn ct_opts_set_label(opts: Handle, key_ptr: [*]const u8, key_len: u32, val_ptr: [*]const u8, val_len: u32) void;
pub extern "env" fn ct_opts_set_container_snapshot(opts: Handle, snap: Handle) void;
pub extern "env" fn ct_opts_add_dir_snapshot(opts: Handle, snap: Handle, mp_ptr: [*]const u8, mp_len: u32) void;

// -- Worker Loader: builder (non-suspending) --------------------------------
pub extern "env" fn wl_code_new(compat_date_ptr: [*]const u8, compat_date_len: u32, main_module_ptr: [*]const u8, main_module_len: u32) Handle;
pub extern "env" fn wl_code_set_compat_flag(code: Handle, flag_ptr: [*]const u8, flag_len: u32) void;
pub extern "env" fn wl_code_set_cpu_ms(code: Handle, cpu_ms: u32) void;
pub extern "env" fn wl_code_set_sub_requests(code: Handle, sub_requests: u32) void;
pub extern "env" fn wl_code_set_env_json(code: Handle, json_ptr: [*]const u8, json_len: u32) void;
pub extern "env" fn wl_code_set_global_outbound(code: Handle, fetcher: Handle) void;
pub extern "env" fn wl_code_add_module_string(code: Handle, name_ptr: [*]const u8, name_len: u32, module_type: u32, content_ptr: [*]const u8, content_len: u32) void;
pub extern "env" fn wl_code_add_module_bytes(code: Handle, name_ptr: [*]const u8, name_len: u32, module_type: u32, content_ptr: [*]const u8, content_len: u32) void;

// -- Worker Loader: operations (JSPI-suspending) ----------------------------
pub extern "env" fn wl_get(loader: Handle, name_ptr: [*]const u8, name_len: u32, code: Handle) Handle;
pub extern "env" fn wl_load(loader: Handle, code: Handle) Handle;

// -- Worker Stub (non-suspending) -------------------------------------------
pub extern "env" fn wl_stub_get_entrypoint(stub: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn wl_stub_get_do_class(stub: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn wl_stub_fetch(stub: Handle, req: Handle) Handle; // JSPI-suspending

// -- Queues ------------------------------------------------------------------
// Producer (JSPI-suspending)
pub extern "env" fn queue_send(queue: Handle, body_ptr: [*]const u8, body_len: u32, content_type: u32, delay_seconds: u32) void;
pub extern "env" fn queue_send_batch(queue: Handle, batch_json_ptr: [*]const u8, batch_json_len: u32, delay_seconds: u32) void;
// Consumer: MessageBatch (non-suspending)
pub extern "env" fn queue_batch_queue_name(batch: Handle) Handle;
pub extern "env" fn queue_batch_len(batch: Handle) u32;
pub extern "env" fn queue_batch_msg(batch: Handle, index: u32) Handle;
pub extern "env" fn queue_batch_ack_all(batch: Handle) void;
pub extern "env" fn queue_batch_retry_all(batch: Handle, delay_seconds: u32) void;
// Consumer: Message (non-suspending)
pub extern "env" fn queue_msg_id(msg: Handle) Handle;
pub extern "env" fn queue_msg_timestamp(msg: Handle) f64;
pub extern "env" fn queue_msg_body(msg: Handle) Handle;
pub extern "env" fn queue_msg_attempts(msg: Handle) u32;
pub extern "env" fn queue_msg_ack(msg: Handle) void;
pub extern "env" fn queue_msg_retry(msg: Handle, delay_seconds: u32) void;

// -- Analytics Engine (non-suspending, fire-and-forget) ---------------------
pub extern "env" fn ae_write_data_point(dataset: Handle, json_ptr: [*]const u8, json_len: u32) void;

// -- Rate Limiting (JSPI-suspending) ----------------------------------------
pub extern "env" fn rate_limit(rl: Handle, key_ptr: [*]const u8, key_len: u32) u32;

// -- Hyperdrive (non-suspending property getters) ---------------------------
pub extern "env" fn hyperdrive_connection_string(hd: Handle) Handle;
pub extern "env" fn hyperdrive_host(hd: Handle) Handle;
pub extern "env" fn hyperdrive_port(hd: Handle) u32;
pub extern "env" fn hyperdrive_user(hd: Handle) Handle;
pub extern "env" fn hyperdrive_password(hd: Handle) Handle;
pub extern "env" fn hyperdrive_database(hd: Handle) Handle;

// -- Service Binding (JSPI-suspending) --------------------------------------
pub extern "env" fn service_binding_fetch(service: Handle, req: Handle) Handle;

// -- Dynamic Dispatch (dispatch namespace) ----------------------------------
pub extern "env" fn dispatch_ns_get(ns: Handle, name_ptr: [*]const u8, name_len: u32, cpu_ms: u32, sub_requests: u32, outbound_ptr: [*]const u8, outbound_len: u32) Handle;
pub extern "env" fn dispatch_ns_fetch(fetcher: Handle, req: Handle) Handle; // JSPI-suspending

// -- Vectorize (JSPI-suspending) --------------------------------------------
pub extern "env" fn vectorize_describe(index: Handle) Handle;
pub extern "env" fn vectorize_query(index: Handle, vec_ptr: [*]const u8, vec_len: u32, opts_ptr: [*]const u8, opts_len: u32) Handle;
pub extern "env" fn vectorize_query_by_id(index: Handle, id_ptr: [*]const u8, id_len: u32, opts_ptr: [*]const u8, opts_len: u32) Handle;
pub extern "env" fn vectorize_insert(index: Handle, json_ptr: [*]const u8, json_len: u32) Handle;
pub extern "env" fn vectorize_upsert(index: Handle, json_ptr: [*]const u8, json_len: u32) Handle;
pub extern "env" fn vectorize_delete_by_ids(index: Handle, json_ptr: [*]const u8, json_len: u32) Handle;
pub extern "env" fn vectorize_get_by_ids(index: Handle, json_ptr: [*]const u8, json_len: u32) Handle;

// -- Crypto (Web Crypto API, JSPI-suspending) --------------------------------
pub extern "env" fn crypto_digest(algorithm: u32, data_ptr: [*]const u8, data_len: u32) Handle;
pub extern "env" fn crypto_hmac(algorithm: u32, key_ptr: [*]const u8, key_len: u32, data_ptr: [*]const u8, data_len: u32) Handle;
pub extern "env" fn crypto_hmac_verify(algorithm: u32, key_ptr: [*]const u8, key_len: u32, sig_ptr: [*]const u8, sig_len: u32, data_ptr: [*]const u8, data_len: u32) u32;
pub extern "env" fn crypto_timing_safe_equal(a_ptr: [*]const u8, a_len: u32, b_ptr: [*]const u8, b_len: u32) u32;

// -- EventSource (SSE) -------------------------------------------------------
pub extern "env" fn eventsource_connect(url_ptr: [*]const u8, url_len: u32) Handle;
pub extern "env" fn eventsource_from_stream(stream: Handle) Handle;
pub extern "env" fn eventsource_next(es: Handle) Handle; // JSPI-suspending
pub extern "env" fn eventsource_ready_state(es: Handle) u32;
pub extern "env" fn eventsource_close(es: Handle) void;

// -- FormData ----------------------------------------------------------------
pub extern "env" fn formdata_from_request(req: Handle) Handle; // JSPI-suspending
pub extern "env" fn formdata_new() Handle;
pub extern "env" fn formdata_get(fd: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn formdata_get_all(fd: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn formdata_has(fd: Handle, name_ptr: [*]const u8, name_len: u32) u32;
pub extern "env" fn formdata_keys(fd: Handle) Handle;
pub extern "env" fn formdata_len(fd: Handle) u32;
pub extern "env" fn formdata_entry_name(fd: Handle, index: u32) Handle;
pub extern "env" fn formdata_entry_is_file(fd: Handle, index: u32) u32;
pub extern "env" fn formdata_entry_value(fd: Handle, index: u32) Handle;
pub extern "env" fn formdata_entry_file_data(fd: Handle, index: u32) Handle;
pub extern "env" fn formdata_entry_file_name(fd: Handle, index: u32) Handle;
pub extern "env" fn formdata_entry_file_type(fd: Handle, index: u32) Handle;
pub extern "env" fn formdata_delete(fd: Handle, name_ptr: [*]const u8, name_len: u32) void;
pub extern "env" fn formdata_set(fd: Handle, name_ptr: [*]const u8, name_len: u32, val_ptr: [*]const u8, val_len: u32) void;
pub extern "env" fn formdata_append(fd: Handle, name_ptr: [*]const u8, name_len: u32, val_ptr: [*]const u8, val_len: u32) void;
pub extern "env" fn formdata_append_file(fd: Handle, name_ptr: [*]const u8, name_len: u32, data_ptr: [*]const u8, data_len: u32, filename_ptr: [*]const u8, filename_len: u32) void;

// -- HTMLRewriter (non-suspending, returns transformed Response handle) -------
pub extern "env" fn html_rewriter_transform(resp: Handle, rules_ptr: [*]const u8, rules_len: u32) Handle;

// -- TCP Sockets -------------------------------------------------------------
pub extern "env" fn socket_connect(host_ptr: [*]const u8, host_len: u32, port: u16, secure_transport: u32, allow_half_open: u32) Handle;
pub extern "env" fn socket_get_writer(socket: Handle) Handle;
pub extern "env" fn socket_get_reader(socket: Handle) Handle;
pub extern "env" fn socket_write(writer: Handle, ptr: [*]const u8, len: u32) void; // JSPI-suspending
pub extern "env" fn socket_read(reader: Handle) Handle; // JSPI-suspending, returns bytes handle or null_handle
pub extern "env" fn socket_close(socket: Handle) void; // JSPI-suspending
pub extern "env" fn socket_close_writer(writer: Handle) void; // JSPI-suspending
pub extern "env" fn socket_start_tls(socket: Handle) Handle;
pub extern "env" fn socket_opened(socket: Handle) Handle; // JSPI-suspending

// -- Scheduled event ---------------------------------------------------------
pub extern "env" fn scheduled_cron(handle: Handle) Handle;
pub extern "env" fn scheduled_time(handle: Handle) f64;

// -- Workers AI (JSPI-suspending) -------------------------------------------
pub extern "env" fn ai_run(ai: Handle, model_ptr: [*]const u8, model_len: u32, input_ptr: [*]const u8, input_len: u32) Handle;
pub extern "env" fn ai_run_with_binary(ai: Handle, model_ptr: [*]const u8, model_len: u32, input_ptr: [*]const u8, input_len: u32, binary_ptr: [*]const u8, binary_len: u32, field_ptr: [*]const u8, field_len: u32) Handle;
pub extern "env" fn ai_run_binary_output(ai: Handle, model_ptr: [*]const u8, model_len: u32, input_ptr: [*]const u8, input_len: u32) Handle;
pub extern "env" fn ai_run_stream(ai: Handle, model_ptr: [*]const u8, model_len: u32, input_ptr: [*]const u8, input_len: u32) Handle;
pub extern "env" fn ai_stream_next(reader: Handle) Handle;
pub extern "env" fn ai_models(ai: Handle) Handle;
pub extern "env" fn ai_run_websocket(ai: Handle, model_ptr: [*]const u8, model_len: u32, input_ptr: [*]const u8, input_len: u32) Handle;

// -- Timers (JSPI-suspending) ------------------------------------------------
pub extern "env" fn js_sleep(ms: u32) void;

// -- Time (non-suspending) ---------------------------------------------------
pub extern "env" fn js_now() f64;

// -- Workflows (JSPI-suspending) ---------------------------------------------
// Binding API (managing instances)
pub extern "env" fn workflow_create(binding_h: Handle, id_ptr: ?[*]const u8, id_len: u32, params_ptr: ?[*]const u8, params_len: u32) Handle;
pub extern "env" fn workflow_get(binding_h: Handle, id_ptr: [*]const u8, id_len: u32) Handle;
pub extern "env" fn workflow_instance_id(instance_h: Handle) Handle;
pub extern "env" fn workflow_instance_pause(instance_h: Handle) void;
pub extern "env" fn workflow_instance_resume(instance_h: Handle) void;
pub extern "env" fn workflow_instance_terminate(instance_h: Handle) void;
pub extern "env" fn workflow_instance_restart(instance_h: Handle) void;
pub extern "env" fn workflow_instance_status(instance_h: Handle) Handle;
pub extern "env" fn workflow_instance_send_event(instance_h: Handle, type_ptr: [*]const u8, type_len: u32, payload_ptr: [*]const u8, payload_len: u32) void;
// Entrypoint API (step operations)
pub extern "env" fn workflow_event_payload(event_h: Handle) Handle;
pub extern "env" fn workflow_event_timestamp(event_h: Handle) f64;
pub extern "env" fn workflow_event_instance_id(event_h: Handle) Handle;
pub extern "env" fn workflow_step_do(step_h: Handle, name_ptr: [*]const u8, name_len: u32, config_ptr: [*]const u8, config_len: u32, callback_fn_idx: u32) Handle;
pub extern "env" fn workflow_step_sleep(step_h: Handle, name_ptr: [*]const u8, name_len: u32, dur_ptr: [*]const u8, dur_len: u32) void;
pub extern "env" fn workflow_step_sleep_until(step_h: Handle, name_ptr: [*]const u8, name_len: u32, timestamp_ms: f64) void;
pub extern "env" fn workflow_step_wait_for_event(step_h: Handle, name_ptr: [*]const u8, name_len: u32, type_ptr: [*]const u8, type_len: u32, timeout_ptr: ?[*]const u8, timeout_len: u32) Handle;

// -- Email -------------------------------------------------------------------
pub extern "env" fn email_from(msg_h: Handle) Handle;
pub extern "env" fn email_to(msg_h: Handle) Handle;
pub extern "env" fn email_raw_size(msg_h: Handle) u32;
pub extern "env" fn email_header(msg_h: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn email_raw_body(msg_h: Handle) Handle;
pub extern "env" fn email_set_reject(msg_h: Handle, reason_ptr: [*]const u8, reason_len: u32) void;
pub extern "env" fn email_forward(msg_h: Handle, rcpt_ptr: [*]const u8, rcpt_len: u32) void;
pub extern "env" fn email_reply(msg_h: Handle, raw_ptr: [*]const u8, raw_len: u32) void;

// -- Send Email ---------------------------------------------------------------
pub extern "env" fn send_email(binding_h: Handle, json_ptr: [*]const u8, json_len: u32) Handle;

// -- Artifacts (JSPI-suspending) ---------------------------------------------
// Namespace-level
pub extern "env" fn artifacts_create(ns: Handle, name_ptr: [*]const u8, name_len: u32, opts_ptr: [*]const u8, opts_len: u32) Handle;
pub extern "env" fn artifacts_get(ns: Handle, name_ptr: [*]const u8, name_len: u32) Handle;
pub extern "env" fn artifacts_list(ns: Handle, opts_ptr: [*]const u8, opts_len: u32) Handle;
pub extern "env" fn artifacts_delete(ns: Handle, name_ptr: [*]const u8, name_len: u32) u32;
pub extern "env" fn artifacts_import(ns: Handle, opts_ptr: [*]const u8, opts_len: u32) Handle;
// Repo handle
pub extern "env" fn artifacts_repo_info(repo: Handle) Handle;
pub extern "env" fn artifacts_repo_create_token(repo: Handle, scope_ptr: [*]const u8, scope_len: u32, ttl: u32) Handle;
pub extern "env" fn artifacts_repo_validate_token(repo: Handle, token_ptr: [*]const u8, token_len: u32) Handle;
pub extern "env" fn artifacts_repo_list_tokens(repo: Handle) Handle;
pub extern "env" fn artifacts_repo_revoke_token(repo: Handle, token_ptr: [*]const u8, token_len: u32) u32;
pub extern "env" fn artifacts_repo_fork(repo: Handle, name_ptr: [*]const u8, name_len: u32, opts_ptr: [*]const u8, opts_len: u32) Handle;

// -- Console -----------------------------------------------------------------
pub extern "env" fn console_log(ptr: [*]const u8, len: u32) void;
pub extern "env" fn console_error(ptr: [*]const u8, len: u32) void;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read a JS string handle into a Zig-owned slice. The handle is released
/// after the bytes are copied into `allocator`-managed memory.
pub fn readString(handle: Handle, allocator: std.mem.Allocator) error{ NullHandle, OutOfMemory }![]const u8 {
    if (handle == null_handle) return error.NullHandle;
    const len = js_string_len(handle);
    const buf = try allocator.alloc(u8, len);
    js_string_read(handle, buf.ptr);
    js_release(handle);
    return buf;
}

/// Store a Zig string in the JS handle table, returning a handle.
/// Useful for returning values from workflow step callbacks.
pub fn createStringHandle(str: []const u8) Handle {
    return js_store_string(str.ptr, @intCast(str.len));
}

/// Read a JS bytes handle (Uint8Array) into a Zig-owned slice.
pub fn readBytes(handle: Handle, allocator: std.mem.Allocator) error{ NullHandle, OutOfMemory }![]const u8 {
    if (handle == null_handle) return error.NullHandle;
    const len = js_bytes_len(handle);
    const buf = try allocator.alloc(u8, len);
    js_bytes_read(handle, buf.ptr);
    js_release(handle);
    return buf;
}

/// Read a string property from a JS object handle.
pub fn getStringProp(obj: Handle, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const str_handle = js_get_string_prop(obj, name.ptr, @intCast(name.len));
    if (str_handle == null_handle) return null;
    const str = try readString(str_handle, allocator);
    return str;
}

/// Read an integer property from a JS object handle.
pub fn getIntProp(obj: Handle, name: []const u8) i64 {
    return js_get_int_prop(obj, name.ptr, @intCast(name.len));
}

/// Read a float property from a JS object handle.
pub fn getFloatProp(obj: Handle, name: []const u8) f64 {
    return js_get_float_prop(obj, name.ptr, @intCast(name.len));
}
