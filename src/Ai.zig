const std = @import("std");
const js = @import("js.zig");
const Response = @import("Response.zig");

handle: js.Handle,
allocator: std.mem.Allocator,

const Ai = @This();

pub fn init(handle: js.Handle, allocator: std.mem.Allocator) Ai {
    return .{ .handle = handle, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A chat message for text generation models.
pub const Message = struct {
    role: []const u8,
    /// Plain text content. For vision models with image URLs, use
    /// `content_parts` instead.
    content: ?[]const u8 = null,
    /// Structured content array for vision models. Each part is either
    /// text or an image URL reference.
    content_parts: ?[]const ContentPart = null,
    /// Tool call ID (for role="tool" responses).
    name: ?[]const u8 = null,
};

/// A content part within a multi-modal message (vision models).
pub const ContentPart = struct {
    type: []const u8, // "text" or "image_url"
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
};

pub const ImageUrl = struct {
    url: []const u8,
};

/// OpenAI-compatible tool definition for function calling.
pub const ToolDefinition = struct {
    type: []const u8 = "function",
    function: FunctionDefinition,
};

pub const FunctionDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for parameters — passed as a raw JSON string.
    parameters: ?[]const u8 = null,
};

/// A tool call returned by the model.
pub const ToolCall = struct {
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?ToolCallFunction = null,
};

pub const ToolCallFunction = struct {
    name: ?[]const u8 = null,
    /// JSON string of the arguments.
    arguments: ?[]const u8 = null,
};

/// Response format for JSON mode.
pub const ResponseFormat = struct {
    type: []const u8 = "json_object",
    /// Optional JSON Schema — passed as a raw JSON string.
    json_schema: ?[]const u8 = null,
};

/// Token usage statistics.
pub const Usage = struct {
    prompt_tokens: ?u32 = null,
    completion_tokens: ?u32 = null,
    total_tokens: ?u32 = null,
};

/// AI Gateway and request options. Embedded as `__options` in the JSON
/// payload and extracted by the JS shim before calling `env.AI.run()`.
pub const AiOptions = struct {
    gateway: ?GatewayOptions = null,
    tags: ?[]const []const u8 = null,
};

pub const GatewayOptions = struct {
    id: []const u8,
    cache_key: ?[]const u8 = null,
    cache_ttl: ?u32 = null,
    skip_cache: ?bool = null,
};

pub const TextGenerationInput = struct {
    prompt: ?[]const u8 = null,
    messages: ?[]const Message = null,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    seed: ?u32 = null,
    repetition_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    tools: ?[]const ToolDefinition = null,
    response_format: ?ResponseFormat = null,
    lora: ?[]const u8 = null,
};

pub const TextGenerationOutput = struct {
    response: ?[]const u8 = null,
    tool_calls: ?[]const u8 = null, // Raw JSON of tool_calls array
    usage: ?Usage = null,
};

pub const TextEmbeddingsInput = struct {
    text: []const []const u8,
};

pub const TextEmbeddingsOutput = struct {
    shape: []const u32,
    data: []const u8, // Raw JSON of the nested float arrays
};

pub const TranslationInput = struct {
    text: []const u8,
    target_lang: []const u8,
    source_lang: ?[]const u8 = null,
};

pub const TranslationOutput = struct {
    translated_text: ?[]const u8 = null,
};

pub const TextClassificationInput = struct {
    text: []const u8,
};

pub const SummarizationInput = struct {
    input_text: []const u8,
    max_length: ?u32 = null,
};

pub const SummarizationOutput = struct {
    summary: ?[]const u8 = null,
};

pub const ImageToTextInput = struct {
    image: []const u8, // raw image bytes
    prompt: ?[]const u8 = null,
    max_tokens: ?u32 = null,
};

pub const ImageToTextOutput = struct {
    description: ?[]const u8 = null,
};

pub const SpeechToTextOutput = struct {
    text: ?[]const u8 = null,
    vtt: ?[]const u8 = null,
    word_count: ?u32 = null,
};

pub const TextToImageInput = struct {
    prompt: []const u8,
    negative_prompt: ?[]const u8 = null,
    height: ?u32 = null,
    width: ?u32 = null,
    num_steps: ?u32 = null,
    guidance: ?f32 = null,
    seed: ?u32 = null,
    /// Set to true for models requiring multipart form data (e.g. Flux-2).
    /// The JS shim will build FormData from the fields automatically.
    multipart: ?bool = null,
};

pub const TextToSpeechInput = struct {
    prompt: []const u8,
    lang: ?[]const u8 = null,
};

/// Configuration for real-time speech-to-text WebSocket models
/// (e.g. @cf/deepgram/nova-3, @cf/deepgram/flux).
/// The client sends raw audio binary frames; the server sends JSON
/// transcription events.
pub const SpeechToTextWsInput = struct {
    encoding: []const u8 = "linear16",
    sample_rate: []const u8 = "16000",
    interim_results: ?bool = null,
    language: ?[]const u8 = null,
};

/// Iterator over SSE chunks from a streaming AI response.
///
/// ```zig
/// var reader = try ai.textGenerationStream("@cf/meta/llama-3.1-8b-instruct", .{
///     .prompt = "Tell me a story",
/// });
/// while (try reader.next()) |chunk| {
///     stream.write(chunk);
/// }
/// ```
pub const StreamReader = struct {
    handle: js.Handle,
    allocator: std.mem.Allocator,

    /// Read the next SSE chunk. Returns null when the stream is done.
    pub fn next(self: *StreamReader) !?[]const u8 {
        const h = js.ai_stream_next(self.handle);
        if (h == js.null_handle) return null;
        return try js.readString(h, self.allocator);
    }
};

/// Model metadata returned by `models()`.
pub const ModelInfo = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    task: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Generic run
// ---------------------------------------------------------------------------

/// Run any model with a raw JSON input string. Returns the raw JSON response.
pub fn run(self: *const Ai, model: []const u8, input_json: []const u8) ![]const u8 {
    const h = js.ai_run(
        self.handle,
        model.ptr,
        @intCast(model.len),
        input_json.ptr,
        @intCast(input_json.len),
    );
    return try js.readString(h, self.allocator);
}

/// Stream any model with a raw JSON input string. The JS shim forces
/// `stream: true`. Returns a `StreamReader` for iterating over SSE chunks.
pub fn runStream(self: *const Ai, model: []const u8, input_json: []const u8) !StreamReader {
    const h = js.ai_run_stream(
        self.handle,
        model.ptr,
        @intCast(model.len),
        input_json.ptr,
        @intCast(input_json.len),
    );
    if (h == js.null_handle) return error.NullHandle;
    return .{ .handle = h, .allocator = self.allocator };
}

/// Run a model in WebSocket mode (e.g. for real-time audio STT/TTS).
/// Returns a 101 Switching Protocols `Response` that you return directly
/// from your fetch handler — the client's WebSocket is proxied through
/// to the AI inference backend.
///
/// ```zig
/// return try ai.runWebSocket("@cf/deepgram/nova-3",
///     \\{"encoding":"linear16","sample_rate":"16000","interim_results":true}
/// );
/// ```
pub fn runWebSocket(self: *const Ai, model: []const u8, input_json: []const u8) !Response {
    const h = js.ai_run_websocket(
        self.handle,
        model.ptr,
        @intCast(model.len),
        input_json.ptr,
        @intCast(input_json.len),
    );
    if (h == js.null_handle) return error.NullHandle;
    return .{ .handle = h };
}

/// List available models. Returns the raw JSON array string.
pub fn models(self: *const Ai) ![]const u8 {
    const h = js.ai_models(self.handle);
    return try js.readString(h, self.allocator);
}

// ---------------------------------------------------------------------------
// Task helpers
// ---------------------------------------------------------------------------

/// Run a text generation model (e.g. @cf/meta/llama-3.1-8b-instruct).
pub fn textGeneration(self: *const Ai, model: []const u8, input: TextGenerationInput) !TextGenerationOutput {
    return self.textGenerationWithOptions(model, input, null);
}

/// Run a text generation model with AI Gateway / request options.
pub fn textGenerationWithOptions(self: *const Ai, model: []const u8, input: TextGenerationInput, options: ?AiOptions) !TextGenerationOutput {
    const json = try buildTextGenJson(self.allocator, input, options);

    const h = js.ai_run(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    const result_json = try js.readString(h, self.allocator);

    // Parse structured fields. The JS shim normalizes OpenAI choices[]
    // format to { response, usage, tool_calls } before returning.
    const parsed = try std.json.parseFromSlice(struct {
        response: ?[]const u8 = null,
        usage: ?Usage = null,
    }, self.allocator, result_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    // Extract tool_calls as raw JSON (complex nested structure).
    const tool_calls_json = extractJsonField(result_json, "tool_calls");

    return .{
        .response = parsed.value.response,
        .tool_calls = tool_calls_json,
        .usage = parsed.value.usage,
    };
}

/// Stream text generation chunks. Returns a `StreamReader` that yields SSE
/// chunks one at a time. The `stream` flag is forced on by the JS shim.
///
/// ```zig
/// var stream = workers.StreamingResponse.start(.{});
/// stream.setHeader("content-type", "text/event-stream");
///
/// var reader = try ai.textGenerationStream("@cf/meta/llama-3.1-8b-instruct", .{
///     .prompt = "Tell me a story",
/// });
/// while (try reader.next()) |chunk| {
///     stream.write(chunk);
/// }
/// stream.close();
/// return stream.response();
/// ```
pub fn textGenerationStream(self: *const Ai, model: []const u8, input: TextGenerationInput) !StreamReader {
    const json = try buildTextGenJson(self.allocator, input, null);

    const h = js.ai_run_stream(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    if (h == js.null_handle) return error.NullHandle;
    return .{ .handle = h, .allocator = self.allocator };
}

/// Run a text embeddings model (e.g. @cf/baai/bge-base-en-v1.5).
pub fn textEmbeddings(self: *const Ai, model: []const u8, input: TextEmbeddingsInput) !TextEmbeddingsOutput {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeAll("{\"text\":[");
    for (input.text, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, t);
    }
    try w.writeAll("]}");
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    const result_json = try js.readString(h, self.allocator);

    // Parse shape array, keep data as raw JSON substring.
    const parsed = try std.json.parseFromSlice(struct {
        shape: []const u32 = &.{},
    }, self.allocator, result_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    // Extract raw "data" value from JSON without re-stringifying.
    const data_json = extractJsonField(result_json, "data") orelse "[]";

    return .{
        .shape = parsed.value.shape,
        .data = data_json,
    };
}

/// Run a translation model (e.g. @cf/meta/m2m100-1.2b).
pub fn translation(self: *const Ai, model: []const u8, input: TranslationInput) !TranslationOutput {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    try writeKey(w, "text", &need_comma);
    try writeJsonString(w, input.text);
    try writeKey(w, "target_lang", &need_comma);
    try writeJsonString(w, input.target_lang);
    if (input.source_lang) |v| {
        try writeKey(w, "source_lang", &need_comma);
        try writeJsonString(w, v);
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    const result_json = try js.readString(h, self.allocator);

    const parsed = try std.json.parseFromSlice(TranslationOutput, self.allocator, result_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed.value;
}

/// Run a text classification model. Returns raw JSON array string of [{label, score}, ...].
pub fn textClassification(self: *const Ai, model: []const u8, input: TextClassificationInput) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeAll("{\"text\":");
    try writeJsonString(w, input.text);
    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    return try js.readString(h, self.allocator);
}

/// Run a summarization model (e.g. @cf/facebook/bart-large-cnn).
pub fn summarization(self: *const Ai, model: []const u8, input: SummarizationInput) !SummarizationOutput {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    try writeKey(w, "input_text", &need_comma);
    try writeJsonString(w, input.input_text);
    if (input.max_length) |v| {
        try writeKey(w, "max_length", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    const result_json = try js.readString(h, self.allocator);

    const parsed = try std.json.parseFromSlice(SummarizationOutput, self.allocator, result_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed.value;
}

/// Run an image classification model. Returns raw JSON array string of [{label, score}, ...].
pub fn imageClassification(self: *const Ai, model: []const u8, image: []const u8) ![]const u8 {
    const field = "image";
    const input_json = "{}";
    const h = js.ai_run_with_binary(
        self.handle,
        model.ptr,
        @intCast(model.len),
        input_json.ptr,
        @intCast(input_json.len),
        image.ptr,
        @intCast(image.len),
        field.ptr,
        @intCast(field.len),
    );
    return try js.readString(h, self.allocator);
}

/// Run an object detection model. Returns raw JSON array string.
pub fn objectDetection(self: *const Ai, model: []const u8, image: []const u8) ![]const u8 {
    const field = "image";
    const input_json = "{}";
    const h = js.ai_run_with_binary(
        self.handle,
        model.ptr,
        @intCast(model.len),
        input_json.ptr,
        @intCast(input_json.len),
        image.ptr,
        @intCast(image.len),
        field.ptr,
        @intCast(field.len),
    );
    return try js.readString(h, self.allocator);
}

/// Run a speech-to-text model (e.g. @cf/openai/whisper).
pub fn speechToText(self: *const Ai, model: []const u8, audio: []const u8) !SpeechToTextOutput {
    const field = "audio";
    const input_json = "{}";
    const h = js.ai_run_with_binary(
        self.handle,
        model.ptr,
        @intCast(model.len),
        input_json.ptr,
        @intCast(input_json.len),
        audio.ptr,
        @intCast(audio.len),
        field.ptr,
        @intCast(field.len),
    );
    const result_json = try js.readString(h, self.allocator);

    const parsed = try std.json.parseFromSlice(SpeechToTextOutput, self.allocator, result_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed.value;
}

/// Run an image-to-text model (e.g. @cf/llava-hf/llava-1.5-7b-hf).
pub fn imageToText(self: *const Ai, model: []const u8, input: ImageToTextInput) !ImageToTextOutput {
    const field = "image";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    if (input.prompt) |prompt| {
        try writeKey(w, "prompt", &need_comma);
        try writeJsonString(w, prompt);
    }
    if (input.max_tokens) |v| {
        try writeKey(w, "max_tokens", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run_with_binary(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
        input.image.ptr,
        @intCast(input.image.len),
        field.ptr,
        @intCast(field.len),
    );
    const result_json = try js.readString(h, self.allocator);

    const parsed = try std.json.parseFromSlice(ImageToTextOutput, self.allocator, result_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed.value;
}

/// Run a text-to-image model. Returns raw image bytes.
///
/// For standard models (SDXL, etc.), just pass the input fields.
/// For Flux-2 models that require multipart form data, set `.multipart = true`:
///
/// ```zig
/// // SDXL (JSON input)
/// const img = try ai.textToImage("@cf/stabilityai/stable-diffusion-xl-base-1.0", .{
///     .prompt = "a cat",
/// });
///
/// // Flux-2 (multipart input)
/// const img = try ai.textToImage("@cf/black-forest-labs/flux-2-dev", .{
///     .prompt = "a cat",
///     .num_steps = 20,
///     .multipart = true,
/// });
/// ```
pub fn textToImage(self: *const Ai, model: []const u8, input: TextToImageInput) ![]const u8 {
    const is_multipart = input.multipart orelse false;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    if (is_multipart) {
        try writeKey(w, "__multipart", &need_comma);
        try w.writeAll("true");
    }
    try writeKey(w, "prompt", &need_comma);
    try writeJsonString(w, input.prompt);
    if (input.negative_prompt) |v| {
        try writeKey(w, "negative_prompt", &need_comma);
        try writeJsonString(w, v);
    }
    if (input.height) |v| {
        try writeKey(w, "height", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.width) |v| {
        try writeKey(w, "width", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.num_steps) |v| {
        // Flux models use "steps" instead of "num_steps"
        const key = if (is_multipart) "steps" else "num_steps";
        try writeKey(w, key, &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.guidance) |v| {
        try writeKey(w, "guidance", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.seed) |v| {
        try writeKey(w, "seed", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run_binary_output(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    return try js.readBytes(h, self.allocator);
}

/// Run a text-to-speech model. Returns raw audio bytes.
pub fn textToSpeech(self: *const Ai, model: []const u8, input: TextToSpeechInput) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    try writeKey(w, "prompt", &need_comma);
    try writeJsonString(w, input.prompt);
    if (input.lang) |v| {
        try writeKey(w, "lang", &need_comma);
        try writeJsonString(w, v);
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    const h = js.ai_run_binary_output(
        self.handle,
        model.ptr,
        @intCast(model.len),
        json.ptr,
        @intCast(json.len),
    );
    return try js.readBytes(h, self.allocator);
}

/// Open a real-time speech-to-text WebSocket (e.g. @cf/deepgram/nova-3).
/// Returns a 101 Response to return from your fetch handler. The client
/// sends binary audio frames and receives JSON transcription events.
///
/// ```zig
/// return try ai.speechToTextWebSocket("@cf/deepgram/nova-3", .{
///     .encoding = "linear16",
///     .sample_rate = "16000",
///     .interim_results = true,
/// });
/// ```
pub fn speechToTextWebSocket(self: *const Ai, model: []const u8, input: SpeechToTextWsInput) !Response {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(self.allocator);

    try w.writeByte('{');
    var need_comma = false;

    try writeKey(w, "encoding", &need_comma);
    try writeJsonString(w, input.encoding);
    try writeKey(w, "sample_rate", &need_comma);
    try writeJsonString(w, input.sample_rate);
    if (input.interim_results) |v| {
        try writeKey(w, "interim_results", &need_comma);
        try w.writeAll(if (v) "true" else "false");
    }
    if (input.language) |v| {
        try writeKey(w, "language", &need_comma);
        try writeJsonString(w, v);
    }

    try w.writeByte('}');
    const json = try buf.toOwnedSlice(self.allocator);

    return self.runWebSocket(model, json);
}

/// Open a text-to-speech WebSocket (e.g. @cf/deepgram/aura-1).
/// Returns a 101 Response to return from your fetch handler. The client
/// sends JSON control messages (`Speak`, `Flush`, `Close`) and receives
/// binary PCM audio frames (mono, 16-bit, 24kHz).
///
/// ```zig
/// return try ai.textToSpeechWebSocket("@cf/deepgram/aura-1");
/// ```
pub fn textToSpeechWebSocket(self: *const Ai, model: []const u8) !Response {
    return self.runWebSocket(model, "{}");
}

// ---------------------------------------------------------------------------
// Internal JSON builders
// ---------------------------------------------------------------------------

fn buildTextGenJson(allocator: std.mem.Allocator, input: TextGenerationInput, options: ?AiOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var need_comma = false;

    if (input.prompt) |prompt| {
        try writeKey(w, "prompt", &need_comma);
        try writeJsonString(w, prompt);
    }
    if (input.messages) |messages| {
        try writeKey(w, "messages", &need_comma);
        try writeMessagesJson(w, messages);
    }
    if (input.max_tokens) |v| {
        try writeKey(w, "max_tokens", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.temperature) |v| {
        try writeKey(w, "temperature", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.top_p) |v| {
        try writeKey(w, "top_p", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.top_k) |v| {
        try writeKey(w, "top_k", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.seed) |v| {
        try writeKey(w, "seed", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.repetition_penalty) |v| {
        try writeKey(w, "repetition_penalty", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.frequency_penalty) |v| {
        try writeKey(w, "frequency_penalty", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.presence_penalty) |v| {
        try writeKey(w, "presence_penalty", &need_comma);
        try std.fmt.format(w, "{d}", .{v});
    }
    if (input.lora) |v| {
        try writeKey(w, "lora", &need_comma);
        try writeJsonString(w, v);
    }
    if (input.tools) |tools| {
        try writeKey(w, "tools", &need_comma);
        try writeToolsJson(w, tools);
    }
    if (input.response_format) |rf| {
        try writeKey(w, "response_format", &need_comma);
        try w.writeAll("{\"type\":");
        try writeJsonString(w, rf.type);
        if (rf.json_schema) |schema| {
            try w.writeAll(",\"json_schema\":");
            try w.writeAll(schema); // raw JSON pass-through
        }
        try w.writeByte('}');
    }
    if (options) |opts| {
        try writeKey(w, "__options", &need_comma);
        try writeOptionsJson(w, opts);
    }

    try w.writeByte('}');
    return try buf.toOwnedSlice(allocator);
}

fn writeMessagesJson(w: anytype, messages: []const Message) !void {
    try w.writeByte('[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":");
        try writeJsonString(w, msg.role);

        if (msg.content_parts) |parts| {
            // Vision model: content is an array of parts.
            try w.writeAll(",\"content\":[");
            for (parts, 0..) |part, j| {
                if (j > 0) try w.writeByte(',');
                try w.writeAll("{\"type\":");
                try writeJsonString(w, part.type);
                if (part.text) |text| {
                    try w.writeAll(",\"text\":");
                    try writeJsonString(w, text);
                }
                if (part.image_url) |img| {
                    try w.writeAll(",\"image_url\":{\"url\":");
                    try writeJsonString(w, img.url);
                    try w.writeByte('}');
                }
                try w.writeByte('}');
            }
            try w.writeByte(']');
        } else if (msg.content) |content| {
            try w.writeAll(",\"content\":");
            try writeJsonString(w, content);
        }

        if (msg.name) |name| {
            try w.writeAll(",\"name\":");
            try writeJsonString(w, name);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn writeToolsJson(w: anytype, tools: []const ToolDefinition) !void {
    try w.writeByte('[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":");
        try writeJsonString(w, tool.type);
        try w.writeAll(",\"function\":{\"name\":");
        try writeJsonString(w, tool.function.name);
        try w.writeAll(",\"description\":");
        try writeJsonString(w, tool.function.description);
        if (tool.function.parameters) |params| {
            try w.writeAll(",\"parameters\":");
            try w.writeAll(params); // raw JSON pass-through
        }
        try w.writeAll("}}");
    }
    try w.writeByte(']');
}

fn writeOptionsJson(w: anytype, opts: AiOptions) !void {
    try w.writeByte('{');
    var need_comma = false;
    if (opts.gateway) |gw| {
        try writeKey(w, "gateway", &need_comma);
        try w.writeAll("{\"id\":");
        try writeJsonString(w, gw.id);
        if (gw.cache_key) |v| {
            try w.writeAll(",\"cacheKey\":");
            try writeJsonString(w, v);
        }
        if (gw.cache_ttl) |v| {
            try w.writeAll(",\"cacheTtl\":");
            try std.fmt.format(w, "{d}", .{v});
        }
        if (gw.skip_cache) |v| {
            try w.writeAll(",\"skipCache\":");
            try w.writeAll(if (v) "true" else "false");
        }
        try w.writeByte('}');
    }
    if (opts.tags) |tags| {
        try writeKey(w, "tags", &need_comma);
        try w.writeByte('[');
        for (tags, 0..) |tag, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, tag);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

// ---------------------------------------------------------------------------
// Internal JSON helpers
// ---------------------------------------------------------------------------

/// Extract the raw JSON value for a given top-level key from a JSON object string.
/// Returns the substring spanning the value (including nested arrays/objects).
fn extractJsonField(json: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < json.len) {
        if (json[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < json.len and json[i] != '"') : (i += 1) {
                if (json[i] == '\\') i += 1;
            }
            if (i >= json.len) return null;
            const found_key = json[start..i];
            i += 1;
            while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
            if (std.mem.eql(u8, found_key, key)) {
                return extractJsonValue(json, i);
            }
            const skipped = extractJsonValue(json, i);
            if (skipped) |v| {
                i = @intFromPtr(v.ptr) - @intFromPtr(json.ptr) + v.len;
            } else {
                return null;
            }
        } else {
            i += 1;
        }
    }
    return null;
}

fn extractJsonValue(json: []const u8, pos: usize) ?[]const u8 {
    if (pos >= json.len) return null;
    var i = pos;
    switch (json[i]) {
        '[', '{' => {
            const open = json[i];
            const close: u8 = if (open == '[') ']' else '}';
            var depth: u32 = 1;
            i += 1;
            while (i < json.len and depth > 0) : (i += 1) {
                if (json[i] == open) depth += 1 else if (json[i] == close) depth -= 1 else if (json[i] == '"') {
                    i += 1;
                    while (i < json.len and json[i] != '"') : (i += 1) {
                        if (json[i] == '\\') i += 1;
                    }
                }
            }
            return json[pos..i];
        },
        '"' => {
            i += 1;
            while (i < json.len and json[i] != '"') : (i += 1) {
                if (json[i] == '\\') i += 1;
            }
            if (i < json.len) i += 1;
            return json[pos..i];
        },
        else => {
            while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ']' and json[i] != ' ' and json[i] != '\n') : (i += 1) {}
            return json[pos..i];
        },
    }
}

fn writeKey(w: anytype, key: []const u8, need_comma: *bool) !void {
    if (need_comma.*) try w.writeByte(',');
    need_comma.* = true;
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(w, "\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ===========================================================================
// Unit tests — run with `zig test src/Ai.zig`
// ===========================================================================
const testing = std.testing;

test "extractJsonField — simple string" {
    const json = "{\"response\":\"hello\",\"usage\":{}}";
    const val = extractJsonField(json, "response");
    try testing.expectEqualStrings("\"hello\"", val.?);
}

test "extractJsonField — nested object" {
    const json = "{\"response\":\"hi\",\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":10}}";
    const val = extractJsonField(json, "usage");
    try testing.expectEqualStrings("{\"prompt_tokens\":5,\"completion_tokens\":10}", val.?);
}

test "extractJsonField — array value" {
    const json = "{\"tool_calls\":[{\"name\":\"foo\"}],\"response\":null}";
    const val = extractJsonField(json, "tool_calls");
    try testing.expectEqualStrings("[{\"name\":\"foo\"}]", val.?);
}

test "extractJsonField — missing key returns null" {
    const json = "{\"response\":\"hi\"}";
    try testing.expect(extractJsonField(json, "missing") == null);
}

test "extractJsonField — null value" {
    const json = "{\"response\":null}";
    const val = extractJsonField(json, "response");
    try testing.expectEqualStrings("null", val.?);
}

test "extractJsonField — numeric value" {
    const json = "{\"count\":42,\"name\":\"test\"}";
    const val = extractJsonField(json, "count");
    try testing.expectEqualStrings("42", val.?);
}

test "extractJsonField — escaped quotes in string" {
    const json = "{\"msg\":\"he said \\\"hi\\\"\",\"other\":1}";
    const val = extractJsonField(json, "msg");
    try testing.expectEqualStrings("\"he said \\\"hi\\\"\"", val.?);
}

test "writeJsonString — plain text" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonString(fbs.writer(), "hello");
    try testing.expectEqualStrings("\"hello\"", fbs.getWritten());
}

test "writeJsonString — escapes special characters" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonString(fbs.writer(), "a\"b\\c\nd\te");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", fbs.getWritten());
}

test "writeJsonString — escapes control characters" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonString(fbs.writer(), &[_]u8{ 0x01, 0x1F });
    try testing.expectEqualStrings("\"\\u0001\\u001f\"", fbs.getWritten());
}

test "buildTextGenJson — prompt only" {
    const json = try buildTextGenJson(testing.allocator, .{ .prompt = "hi" }, null);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"prompt\":\"hi\"}", json);
}

test "buildTextGenJson — messages with role and content" {
    const msgs = [_]Message{
        .{ .role = "user", .content = "hello" },
    };
    const json = try buildTextGenJson(testing.allocator, .{ .messages = &msgs }, null);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}", json);
}

test "buildTextGenJson — with temperature and max_tokens" {
    const json = try buildTextGenJson(testing.allocator, .{
        .prompt = "test",
        .max_tokens = 100,
        .temperature = 0.7,
    }, null);
    defer testing.allocator.free(json);
    // Verify key fields are present
    try testing.expect(std.mem.indexOf(u8, json, "\"prompt\":\"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"max_tokens\":100") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"temperature\":") != null);
}

test "buildTextGenJson — tools serialization" {
    const tools = [_]ToolDefinition{
        .{
            .function = .{
                .name = "get_weather",
                .description = "Get weather",
                .parameters = "{\"type\":\"object\"}",
            },
        },
    };
    const json = try buildTextGenJson(testing.allocator, .{
        .prompt = "weather?",
        .tools = &tools,
    }, null);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"tools\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"get_weather\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"parameters\":{\"type\":\"object\"}") != null);
}

test "buildTextGenJson — response_format json_schema" {
    const json = try buildTextGenJson(testing.allocator, .{
        .prompt = "json test",
        .response_format = .{
            .type = "json_schema",
            .json_schema = "{\"name\":\"test\",\"schema\":{\"type\":\"object\"}}",
        },
    }, null);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"response_format\":{\"type\":\"json_schema\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"json_schema\":{\"name\":\"test\"") != null);
}

test "buildTextGenJson — vision content_parts" {
    const parts = [_]ContentPart{
        .{ .type = "text", .text = "describe this" },
        .{ .type = "image_url", .image_url = .{ .url = "https://example.com/img.png" } },
    };
    const msgs = [_]Message{
        .{ .role = "user", .content_parts = &parts },
    };
    const json = try buildTextGenJson(testing.allocator, .{ .messages = &msgs }, null);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":[{\"type\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"image_url\":{\"url\":\"https://example.com/img.png\"}") != null);
}

test "buildTextGenJson — with AI gateway options" {
    const json = try buildTextGenJson(testing.allocator, .{ .prompt = "hi" }, .{
        .gateway = .{ .id = "my-gw", .cache_ttl = 300 },
    });
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"__options\":{") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"my-gw\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"cacheTtl\":300") != null);
}

test "buildTextGenJson — message with name (tool role)" {
    const msgs = [_]Message{
        .{ .role = "tool", .content = "{\"temp\":72}", .name = "get_weather" },
    };
    const json = try buildTextGenJson(testing.allocator, .{ .messages = &msgs }, null);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"get_weather\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"tool\"") != null);
}
