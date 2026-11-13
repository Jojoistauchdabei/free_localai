// PrivateLM Linux bridge — a small C-ABI layer between the Flutter app and
// the vendored llama.cpp (see local_plugins/llama_flutter_android/android/
// src/main/cpp/llama.cpp). Exposes exactly what lib/services/
// inference_android.dart needs from the plugin's LlamaController:
//   load (background thread + progress), generateChat (streamed tokens via
//   callback), stop, context usage, free.
//
// Chat templating uses llama.cpp's `common` library, so every model with a
// Jinja chat template works — the same templates the Android/iOS builds use.
//
// Threading: both load and generation run on background threads; Dart polls
// state via plm_load_state()/plm_generate_state() and receives tokens /
// progress through function-pointer callbacks (NativeCallable.listener).
//
// Build (manual, llama.cpp libs in <build>/bin):
//   g++ -std=c++17 -shared -fPIC -O2 plm_bridge.cpp \
//       -I<llama.cpp>/include -I<llama.cpp>/common -I<llama.cpp>/ggml/include \
//       -I<build> -L<build>/bin -lllama -llama-common -lggml \
//       -o libplm_bridge.so

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include "llama.h"
#include "chat.h"
#include "common.h"
#include "ggml-backend.h"
#include "ggml-rpc.h"

#define PLM_BRIDGE_VERSION 2

// ── Global engine state (one model at a time, like the Android plugin) ──────

static llama_model *g_model = nullptr;
static llama_context *g_ctx = nullptr;
static common_chat_templates_ptr g_tmpls;
static std::string g_template_source;

static std::atomic<bool> g_stop{false};
static std::atomic<bool> g_generating{false};
static std::mutex g_engine_mutex; // serializes load / start / free

static std::string g_last_error;
static std::mutex g_cluster_mutex;
static std::vector<std::string> g_cluster_endpoints;
static std::vector<float> g_cluster_weights;
static float g_cluster_local_weight = 1.0f;
static std::atomic<bool> g_worker_running{false};
static std::atomic<bool> g_worker_starting{false};
static std::thread g_worker_thread;
static std::mutex g_gpu_info_mutex;
static std::vector<std::string> g_gpu_names;
static std::vector<size_t> g_gpu_free;
static std::vector<size_t> g_gpu_total;
static std::vector<double> g_gpu_speed;
static std::mutex g_gpu_selection_mutex;
static std::unordered_set<int> g_gpu_selection;

// Background load state, polled from Dart.
static std::atomic<int> g_load_state{0}; // 0 idle, 1 running, 2 done, 3 failed
static std::atomic<float> g_load_progress{0.0f};
static std::mutex g_load_error_mutex;
static std::string g_load_error;

// Generation state, polled from Dart.
static std::atomic<int> g_gen_state{0}; // 0 idle, 1 running, 2 done, 3 failed
static std::atomic<int> g_gen_tokens{0};
static std::mutex g_gen_error_mutex;
static std::string g_gen_error;

// Progress callback from Dart during load (NativeCallable.listener).
static void (*g_progress_cb)(float) = nullptr;

// Token callback from Dart during generation (NativeCallable.listener).
static void (*g_token_cb)(const char *) = nullptr;

// Batch size chosen at load time, reused by the generation loop.
static std::atomic<int> g_n_batch{512};

// When set, llama.cpp logs below warnings are dropped.
static std::atomic<bool> g_quiet{true};

static void bridge_log(ggml_log_level level, const char *text, void * /*user*/) {
    if (g_quiet && level < GGML_LOG_LEVEL_WARN) return;
    fputs(text, stderr);
}

// Streamed tokens from the generation thread, drained by Dart.
static std::mutex g_token_mutex;
static std::deque<std::string> g_token_queue;

static void push_token(const char *piece) {
    std::lock_guard<std::mutex> lock(g_token_mutex);
    g_token_queue.emplace_back(piece);
}

static void set_error(std::string message) {
    g_last_error = std::move(message);
}

static void set_load_error(std::string message) {
    std::lock_guard<std::mutex> lock(g_load_error_mutex);
    g_load_error = std::move(message);
}

static void set_gen_error(std::string message) {
    std::lock_guard<std::mutex> lock(g_gen_error_mutex);
    g_gen_error = std::move(message);
}

static std::vector<ggml_backend_dev_t> gpu_devices(bool respect_selection = false) {
    std::vector<ggml_backend_dev_t> devices;
    std::lock_guard<std::mutex> selection_lock(g_gpu_selection_mutex);
    int gpu_index = 0;
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        auto device = ggml_backend_dev_get(i);
        const auto type = ggml_backend_dev_type(device);
        if (type == GGML_BACKEND_DEVICE_TYPE_GPU ||
            type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
            if (!respect_selection || g_gpu_selection.empty() ||
                g_gpu_selection.count(gpu_index) != 0) {
                devices.push_back(device);
            }
            ++gpu_index;
        }
    }
    return devices;
}

static double benchmark_gpu(ggml_backend_dev_t device) {
    auto backend = ggml_backend_dev_init(device, nullptr);
    auto buft = ggml_backend_dev_buffer_type(device);
    if (!backend || !buft) return 0.0;
    constexpr size_t bytes = 16 * 1024 * 1024;
    auto buffer = ggml_backend_buft_alloc_buffer(buft, bytes);
    if (!buffer) {
        ggml_backend_free(backend);
        return 0.0;
    }
    ggml_init_params init = {
        .mem_size = 1024 * 1024,
        .mem_buffer = nullptr,
        .no_alloc = true,
    };
    auto ctx = ggml_init(init);
    if (!ctx) {
        ggml_backend_buffer_free(buffer);
        ggml_backend_free(backend);
        return 0.0;
    }
    auto tensor = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, bytes / sizeof(float));
    auto base = ggml_backend_buffer_get_base(buffer);
    if (!base ||
        ggml_backend_tensor_alloc(buffer, tensor, base) != GGML_STATUS_SUCCESS) {
        ggml_free(ctx);
        ggml_backend_buffer_free(buffer);
        ggml_backend_free(backend);
        return 0.0;
    }
    std::vector<uint8_t> host(bytes, 0);
    const auto start = std::chrono::steady_clock::now();
    constexpr int rounds = 3;
    for (int i = 0; i < rounds; ++i) {
        ggml_backend_tensor_set(tensor, host.data(), 0, bytes);
        ggml_backend_tensor_get(tensor, host.data(), 0, bytes);
    }
    ggml_backend_synchronize(backend);
    const double seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
            .count();
    ggml_free(ctx);
    ggml_backend_buffer_free(buffer);
    ggml_backend_free(backend);
    return seconds > 0.0 ? (double)(bytes * rounds * 2) / seconds / 1e9 : 0.0;
}

static void refresh_gpu_info() {
    std::lock_guard<std::mutex> lock(g_gpu_info_mutex);
    g_gpu_names.clear();
    g_gpu_free.clear();
    g_gpu_total.clear();
    g_gpu_speed.clear();
    for (auto device : gpu_devices()) {
        size_t free = 0;
        size_t total = 0;
        ggml_backend_dev_memory(device, &free, &total);
        g_gpu_names.emplace_back(ggml_backend_dev_name(device));
        g_gpu_free.push_back(free);
        g_gpu_total.push_back(total);
        g_gpu_speed.push_back(benchmark_gpu(device));
    }
}

static bool load_progress_cb(float progress, void * /*user*/) {
    float normalized = progress;
    if (normalized < 0) normalized = 0;
    if (normalized > 1) normalized /= 100; // some paths report 0..100
    g_load_progress = normalized;
    if (g_progress_cb) g_progress_cb(normalized);
    return !g_stop; // returning true continues the load
}

static void background_load(std::string model_path, int n_ctx, int n_threads,
                            int n_gpu_layers) {
    g_load_state = 1;
    g_load_progress = 0.0f;

    auto params = llama_model_default_params();
    params.n_gpu_layers = n_gpu_layers;
    params.progress_callback = load_progress_cb;
    params.progress_callback_user_data = nullptr;

    std::vector<ggml_backend_dev_t> cluster_devices;
    std::vector<float> tensor_split;
    const auto local_gpus = gpu_devices();
    {
        std::lock_guard<std::mutex> lock(g_cluster_mutex);
        if (!g_cluster_endpoints.empty()) {
            auto rpc = ggml_backend_reg_by_name("RPC");
            auto add_server = rpc
                ? reinterpret_cast<ggml_backend_reg_t (*)(const char *)>(
                      ggml_backend_reg_get_proc_address(
                          rpc, "ggml_backend_rpc_add_server"))
                : nullptr;
            if (!add_server) {
                set_load_error("Phone cluster is unavailable: RPC backend was not built");
                g_load_state = 3;
                return;
            }
            for (const auto &endpoint : g_cluster_endpoints) {
                auto reg = add_server(endpoint.c_str());
                if (!reg) {
                    set_load_error("Phone cluster worker is unreachable: " + endpoint);
                    g_load_state = 3;
                    return;
                }
                ggml_backend_register(reg);
                for (size_t i = 0; i < ggml_backend_reg_dev_count(reg); ++i) {
                    cluster_devices.push_back(ggml_backend_reg_dev_get(reg, i));
                }
            }
            cluster_devices.insert(cluster_devices.begin(), local_gpus.begin(),
                                   local_gpus.end());
            cluster_devices.push_back(nullptr);
            tensor_split.assign(llama_max_devices(), 0.0f);
            size_t splitIndex = 0;
            for (auto device : local_gpus) {
                size_t free = 0;
                size_t total = 0;
                ggml_backend_dev_memory(device, &free, &total);
                tensor_split[splitIndex++] = total > 0 ? (float)total : 1.0f;
            }
            for (size_t i = 0; i < g_cluster_weights.size() &&
                            splitIndex < tensor_split.size(); ++i) {
                tensor_split[splitIndex++] =
                    std::max(g_cluster_weights[i], 0.01f);
            }
            params.devices = cluster_devices.data();
            params.split_mode = LLAMA_SPLIT_MODE_LAYER;
            params.tensor_split = tensor_split.data();
        } else if (!local_gpus.empty()) {
            cluster_devices = local_gpus;
            cluster_devices.push_back(nullptr);
            params.devices = cluster_devices.data();
            params.n_gpu_layers = n_gpu_layers > 0 ? n_gpu_layers : -1;
        }
    }

    llama_model *model = llama_model_load_from_file(model_path.c_str(), params);
    if (!model) {
        set_load_error("Model load failed: could not read GGUF file");
        g_load_state = 3;
        return;
    }

    auto cparams = llama_context_default_params();
    cparams.n_ctx = n_ctx > 0 ? (uint32_t)n_ctx : 4096;
    cparams.n_batch = cparams.n_ctx < 2048 ? cparams.n_ctx : 2048;
    cparams.n_ubatch = 512;
    cparams.n_threads =
        n_threads > 0 ? n_threads : (int)std::thread::hardware_concurrency() / 2;
    cparams.n_threads_batch = cparams.n_threads;
    cparams.no_perf = false;
    g_n_batch = (int)cparams.n_batch;

    llama_context *ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        set_load_error("Context init failed: context too small or out of memory");
        g_load_state = 3;
        return;
    }

    g_tmpls = common_chat_templates_init(model, "");
    g_template_source = common_chat_templates_source(g_tmpls.get());

    g_ctx = ctx;
    g_model = model;
    g_load_progress = 1.0f;
    g_load_state = 2;
}

static void load_launch(std::string model_path, int n_ctx, int n_threads,
                        int n_gpu_layers) {
    background_load(std::move(model_path), n_ctx, n_threads, n_gpu_layers);
}

// ── Generation worker ───────────────────────────────────────────────────────

static int decode_all(const std::vector<llama_token> &tokens) {
    const int n_batch = g_n_batch.load();
    size_t pos = 0;
    while (pos < tokens.size()) {
        if (g_stop) return -1;
        size_t take = std::min((size_t)n_batch, tokens.size() - pos);
        llama_batch batch = llama_batch_get_one(
            (llama_token *)(tokens.data() + pos), (int32_t)take);
        if (llama_decode(g_ctx, batch) != 0) {
            set_gen_error("Decode failed: context full");
            return -1;
        }
        pos += take;
    }
    return 0;
}

static void background_generate(std::vector<std::string> roles,
                                std::vector<std::string> contents,
                                double temperature, double top_p, int top_k,
                                double min_p, double repeat_penalty,
                                int repeat_last_n, int max_tokens) {
    g_gen_state = 1;
    g_gen_tokens = 0;
    g_stop = false;
    g_generating = true;
    struct Running {
        ~Running() { g_generating = false; }
    } running;

    common_chat_templates_inputs inputs;
    inputs.add_generation_prompt = true;
    inputs.use_jinja = true;
    for (size_t i = 0; i < roles.size(); i++) {
        common_chat_msg msg;
        msg.role = roles[i];
        msg.content = contents[i];
        inputs.messages.push_back(msg);
    }

    common_chat_params params;
    try {
        params = common_chat_templates_apply(g_tmpls.get(), inputs);
    } catch (const std::exception &e) {
        set_gen_error(std::string("Chat template failed: ") + e.what());
        g_gen_state = 3;
        return;
    }

    std::vector<llama_token> tokens;
    try {
        tokens = common_tokenize(g_ctx, params.prompt.str(), false, true);
    } catch (const std::exception &e) {
        set_gen_error(std::string("Tokenize failed: ") + e.what());
        g_gen_state = 3;
        return;
    }
    if (tokens.empty()) {
        set_gen_error("Prompt produced no tokens");
        g_gen_state = 3;
        return;
    }

    // Fresh KV state for every generation (stateless per-request, matching
    // how the app treats the GGUF runtime).
    llama_memory_clear(llama_get_memory(g_ctx), true);

    // Prefill. The final token is decoded together with the first sample.
    std::vector<llama_token> prefill(tokens.begin(), tokens.end() - 1);
    if (decode_all(prefill) != 0) {
        g_gen_state = 3;
        return;
    }

    llama_sampler *smpl =
        llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_min_p((float)min_p, 1));
    llama_sampler_chain_add(
        smpl, llama_sampler_init_temp_ext((float)temperature, 0.0, 0.0));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p((float)top_p, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k));

    const llama_vocab *vocab = llama_model_get_vocab(g_model);
    llama_sampler_chain_add(
        smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab),
                                           repeat_last_n, (float)repeat_penalty,
                                           0.0f, 0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    std::vector<llama_token> pending{tokens.back()};
    for (int produced = 0; produced < max_tokens; produced++) {
        if (g_stop) break;

        llama_batch batch =
            llama_batch_get_one(pending.data(), (int32_t)pending.size());
        if (llama_decode(g_ctx, batch) != 0) {
            set_gen_error("Decode failed: context full");
            llama_sampler_free(smpl);
            g_gen_state = 3;
            return;
        }

        llama_token id = llama_sampler_sample(smpl, g_ctx, -1);
        pending.clear();
        pending.push_back(id);

        if (llama_vocab_is_eog(vocab, id)) break;

        std::string piece = common_token_to_piece(g_ctx, id, true);
        if (piece.empty()) continue;

        g_gen_tokens++;
        push_token(piece.c_str());
    }

    llama_sampler_free(smpl);
    g_gen_state = 2;
}

static void generate_launch(std::vector<std::string> roles,
                            std::vector<std::string> contents,
                            double temperature, double top_p, int top_k,
                            double min_p, double repeat_penalty,
                            int repeat_last_n, int max_tokens) {
    background_generate(std::move(roles), std::move(contents), temperature,
                        top_p, top_k, min_p, repeat_penalty, repeat_last_n,
                        max_tokens);
}

// ── C ABI ───────────────────────────────────────────────────────────────────

extern "C" {

int plm_version() { return PLM_BRIDGE_VERSION; }

const char *plm_last_error() { return g_last_error.c_str(); }

// Controls llama.cpp log spam: 1 = only warnings and errors (default).
void plm_set_quiet(int quiet) {
    g_quiet = quiet != 0;
    llama_log_set(bridge_log, nullptr);
}

void plm_set_cluster(const char **endpoints, const float *weights, int count,
                     float local_weight) {
    std::lock_guard<std::mutex> lock(g_cluster_mutex);
    g_cluster_endpoints.clear();
    g_cluster_weights.clear();
    g_cluster_local_weight = local_weight;
    for (int i = 0; i < count; ++i) {
        if (endpoints && endpoints[i] && *endpoints[i]) {
            g_cluster_endpoints.emplace_back(endpoints[i]);
            g_cluster_weights.push_back(weights ? weights[i] : 1.0f);
        }
    }
}

int plm_worker_start(const char *endpoint, int threads) {
    if (g_worker_running || g_worker_starting) return 0;
    g_worker_starting = true;
    g_worker_thread =
        std::thread([endpoint = std::string(endpoint), threads]() {
            auto devices = gpu_devices();
            if (devices.empty()) {
                auto cpu = ggml_backend_dev_by_type(
                    GGML_BACKEND_DEVICE_TYPE_CPU);
                if (cpu) devices.push_back(cpu);
            } else {
                auto cpu = ggml_backend_dev_by_type(
                    GGML_BACKEND_DEVICE_TYPE_CPU);
                if (cpu) devices.push_back(cpu);
            }
            if (devices.empty()) {
                g_worker_starting = false;
                return;
            }
            g_worker_running = true;
            g_worker_starting = false;
            ggml_backend_rpc_start_server(
                endpoint.c_str(), nullptr, threads > 0 ? (size_t)threads : 0,
                devices.size(), devices.data());
            g_worker_running = false;
        });
    g_worker_thread.detach();
    return 0;
}

int plm_worker_running() { return g_worker_running ? 1 : 0; }

int plm_worker_stop() {
    // llama.cpp's RPC server currently has no cancellation API.
    return g_worker_running ? 0 : -1;
}

int plm_gpu_count() {
    refresh_gpu_info();
    std::lock_guard<std::mutex> lock(g_gpu_info_mutex);
    return (int)g_gpu_names.size();
}

void plm_set_gpu_selection(const int *indices, int count) {
    std::lock_guard<std::mutex> lock(g_gpu_selection_mutex);
    g_gpu_selection.clear();
    for (int i = 0; i < count; ++i) {
        if (indices && indices[i] >= 0) g_gpu_selection.insert(indices[i]);
    }
}

const char *plm_gpu_name(int index) {
    refresh_gpu_info();
    std::lock_guard<std::mutex> lock(g_gpu_info_mutex);
    return index >= 0 && (size_t)index < g_gpu_names.size()
               ? g_gpu_names[index].c_str()
               : "";
}

uint64_t plm_gpu_free_memory(int index) {
    refresh_gpu_info();
    std::lock_guard<std::mutex> lock(g_gpu_info_mutex);
    return index >= 0 && (size_t)index < g_gpu_free.size()
               ? g_gpu_free[index]
               : 0;
}

uint64_t plm_gpu_total_memory(int index) {
    refresh_gpu_info();
    std::lock_guard<std::mutex> lock(g_gpu_info_mutex);
    return index >= 0 && (size_t)index < g_gpu_total.size()
               ? g_gpu_total[index]
               : 0;
}

double plm_gpu_memory_speed(int index) {
    refresh_gpu_info();
    std::lock_guard<std::mutex> lock(g_gpu_info_mutex);
    return index >= 0 && (size_t)index < g_gpu_speed.size()
               ? g_gpu_speed[index]
               : 0.0;
}

// Starts an async model load. Returns 0 on success (poll plm_load_state),
// -1 if something is already loading or loaded.
int plm_load_start(const char *model_path, const char * /*mmproj_path*/,
                   int n_ctx, int n_threads, int n_gpu_layers,
                   void (*progress_cb)(float)) {
    std::lock_guard<std::mutex> engine_lock(g_engine_mutex);
    if (g_model) {
        set_error("A model is already loaded");
        return -1;
    }

    if (g_load_state == 1) {
        set_error("A model load is already running");
        return -1;
    }
    if (!model_path || !*model_path) {
        set_error("No model path given");
        return -1;
    }
    g_progress_cb = progress_cb;
    g_stop = false;
    g_load_state = 1; // synchronous, so a poll right after start sees "running"
    g_load_progress = 0.0f;
    {
        std::lock_guard<std::mutex> lock(g_load_error_mutex);
        g_load_error.clear();
    }
    std::thread(load_launch, std::string(model_path), n_ctx, n_threads,
                n_gpu_layers)
        .detach();
    return 0;
}

// 0 = idle, 1 = running, 2 = success, 3 = failed
int plm_load_state() { return g_load_state; }

float plm_load_progress() { return g_load_progress; }

const char *plm_load_error() {
    std::lock_guard<std::mutex> lock(g_load_error_mutex);
    return g_load_error.c_str();
}

int plm_is_loaded() { return g_model ? 1 : 0; }

// Stops a running generation or load.
void plm_stop() { g_stop = true; }

// Starts an async chat generation. roles/contents are parallel arrays of
// n_messages entries; they are copied, so Dart can free them after the call.
// Tokens accumulate in an internal queue; Dart drains them via
// plm_generate_take().
// Returns 0 on success (poll plm_generate_state), -1 on immediate failure.
int plm_generate_chat_start(const char **roles, const char **contents,
                            int n_messages, double temperature, double top_p,
                            int top_k, double min_p, double repeat_penalty,
                            int repeat_last_n, int max_tokens) {
    std::lock_guard<std::mutex> engine_lock(g_engine_mutex);
    if (!g_model || !g_ctx) {
        set_error("No model loaded");
        return -1;
    }
    if (g_gen_state == 1) {
        set_error("A generation is already running");
        return -1;
    }
    if (n_messages <= 0) {
        set_error("Invalid generation arguments");
        return -1;
    }

    std::vector<std::string> role_copy, content_copy;
    role_copy.reserve(n_messages);
    content_copy.reserve(n_messages);
    for (int i = 0; i < n_messages; i++) {
        role_copy.emplace_back(roles[i] ? roles[i] : "user");
        content_copy.emplace_back(contents[i] ? contents[i] : "");
    }

    g_gen_state = 1; // synchronous, so a poll right after start sees "running"
    g_gen_tokens = 0;
    g_stop = false;
    {
        std::lock_guard<std::mutex> lock(g_token_mutex);
        g_token_queue.clear();
    }
    {
        std::lock_guard<std::mutex> lock(g_gen_error_mutex);
        g_gen_error.clear();
    }
    std::thread(generate_launch, std::move(role_copy), std::move(content_copy),
                temperature, top_p, top_k, min_p, repeat_penalty, repeat_last_n,
                max_tokens)
        .detach();
    return 0;
}

// 0 = idle, 1 = running, 2 = success, 3 = failed
int plm_generate_state() { return g_gen_state; }

int plm_generate_tokens() { return g_gen_tokens; }

// Drains one token piece into [out] (capacity [cap] bytes).
// Returns the piece length (>= 0), 0 while the queue is empty but the
// generation still runs, and -1 once the generation finished and the queue
// is drained.
int plm_generate_take(char *out, int cap) {
    std::lock_guard<std::mutex> lock(g_token_mutex);
    if (g_token_queue.empty()) {
        return g_gen_state == 1 ? 0 : -1;
    }
    const std::string &piece = g_token_queue.front();
    size_t n = piece.size() < (size_t)cap ? piece.size() : (size_t)cap;
    memcpy(out, piece.data(), n);
    out[n] = '\0';
    g_token_queue.pop_front();
    return (int)n;
}

const char *plm_generate_error() {
    std::lock_guard<std::mutex> lock(g_gen_error_mutex);
    return g_gen_error.c_str();
}

int plm_tokens_used() {
    if (!g_ctx) return 0;
    return (int)llama_memory_seq_pos_max(llama_get_memory(g_ctx), 0) + 1;
}

int plm_context_size() {
    if (!g_ctx) return 0;
    return (int)llama_n_ctx(g_ctx);
}

const char *plm_chat_template_source() { return g_template_source.c_str(); }

// Frees the loaded model. Waits until any generation finished.
void plm_free() {
    std::lock_guard<std::mutex> engine_lock(g_engine_mutex);
    g_stop = true;
    while (g_generating) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    g_tmpls.reset();
    if (g_ctx) llama_free(g_ctx);
    if (g_model) llama_model_free(g_model);
    g_ctx = nullptr;
    g_model = nullptr;
    g_load_state = 0;
    g_gen_state = 0;
}

} // extern "C"
