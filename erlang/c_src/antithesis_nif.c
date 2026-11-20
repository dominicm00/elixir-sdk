// BEAM interface to libvoidstar. Missing libvoidstar does not prevent NIF
// loading: available/0 returns false and hit/3 becomes a no-op.
//
// Coverage modules register on their first hit using the instrumentor's key.
// Subsequent hits with a valid lease require no allocation or libvoidstar call.
// See instrumentation.h, "Coverage leases", for the lease protocol.

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <erl_nif.h>

#define VOIDSTAR_PATH "/usr/lib/libvoidstar.so"

// Lease-word packing, from instrumentation.h ("Coverage leases").
#define LEASE_EPOCH_SHIFT 40
#define LEASE_GRANTED_SHIFT 20
#define LEASE_FIELD_MASK 0xFFFFFull
#define LEASE_EPOCH_MASK 0xFFFFFFull

// ABI 2 adds coverage leases.
#define REQUESTED_ABI_VERSION 2

// Each instrumentor invocation produces one coverage module (symbol table),
// which may contain many BEAM modules. This bounds registrations per VM.
#define MAX_COVERAGE_MODULES 64

typedef uint64_t (*fuzz_get_random_fn)(void);
typedef void (*fuzz_json_data_fn)(const char*, size_t);
typedef void (*fuzz_flush_fn)(void);
typedef size_t (*init_coverage_module_fn)(size_t, const char*);
typedef bool (*notify_coverage_fn)(size_t);
typedef uint64_t (*notify_coverage_v2_fn)(size_t, uint64_t);
typedef const uint64_t* (*coverage_lease_generation_addr_fn)(void);
typedef uint64_t (*request_abi_version_fn)(uint64_t);

static struct {
    void* handle;
    fuzz_get_random_fn get_random;
    fuzz_json_data_fn json_data;
    fuzz_flush_fn flush;
    init_coverage_module_fn init_coverage_module;
    notify_coverage_fn notify_coverage;
    notify_coverage_v2_fn notify_coverage_v2;
    const uint64_t* lease_generation;
} voidstar;

typedef struct {
    ERL_NIF_TERM key;  // Atom terms can be compared without an ErlNifEnv.
    size_t edge_count;
    size_t offset;
    // Indices are 1-based, so allocate edge_count + 1 words. ABI 2 stores
    // leases; ABI 1 uses nonzero to mark retired edges.
    uint64_t* leases;
} coverage_module;

static coverage_module modules[MAX_COVERAGE_MODULES];
// A release store publishes initialized module fields. Readers acquire the
// count and scan the published entries without locking.
static size_t module_count;
static pthread_mutex_t register_lock = PTHREAD_MUTEX_INITIALIZER;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;

static void load_voidstar(void) {
    void* handle = dlopen(VOIDSTAR_PATH, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        return;
    }
    voidstar.get_random = (fuzz_get_random_fn)dlsym(handle, "fuzz_get_random");
    voidstar.json_data = (fuzz_json_data_fn)dlsym(handle, "fuzz_json_data");
    voidstar.flush = (fuzz_flush_fn)dlsym(handle, "fuzz_flush");
    if (voidstar.get_random == NULL || voidstar.json_data == NULL || voidstar.flush == NULL) {
        dlclose(handle);
        memset(&voidstar, 0, sizeof voidstar);
        return;
    }
    voidstar.handle = handle;
    voidstar.init_coverage_module = (init_coverage_module_fn)dlsym(handle, "init_coverage_module");
    voidstar.notify_coverage = (notify_coverage_fn)dlsym(handle, "notify_coverage");

    // Negotiate before coverage calls; libraries without this entry point use ABI 1.
    request_abi_version_fn request =
        (request_abi_version_fn)dlsym(handle, "instrumentation_request_abi_version");
    uint64_t granted = request != NULL ? request(REQUESTED_ABI_VERSION) : 1;
    if (granted >= 2 && granted <= REQUESTED_ABI_VERSION) {
        coverage_lease_generation_addr_fn generation =
            (coverage_lease_generation_addr_fn)dlsym(handle, "coverage_lease_generation_addr");
        voidstar.notify_coverage_v2 = (notify_coverage_v2_fn)dlsym(handle, "notify_coverage_v2");
        if (generation != NULL && voidstar.notify_coverage_v2 != NULL) {
            voidstar.lease_generation = generation();
        } else {
            voidstar.notify_coverage_v2 = NULL;
        }
    }
    // Register modules only if coverage notifications are supported.
    if (voidstar.notify_coverage_v2 == NULL && voidstar.notify_coverage == NULL) {
        voidstar.init_coverage_module = NULL;
    }
}

static int on_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    atom_ok = enif_make_atom(env, "ok");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    load_voidstar();
    return 0;
}

static ERL_NIF_TERM available(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)env;
    (void)argc;
    (void)argv;
    return voidstar.handle != NULL ? atom_true : atom_false;
}

static ERL_NIF_TERM output(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &bin)) {
        return enif_make_badarg(env);
    }
    if (voidstar.handle == NULL) {
        return enif_make_badarg(env);
    }
    voidstar.json_data((const char*)bin.data, bin.size);
    voidstar.flush();
    return atom_ok;
}

static ERL_NIF_TERM get_random(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    if (voidstar.handle == NULL) {
        return enif_make_badarg(env);
    }
    return enif_make_uint64(env, voidstar.get_random());
}

static coverage_module* find_module(ERL_NIF_TERM key, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (modules[i].key == key) {
            return &modules[i];
        }
    }
    return NULL;
}

// Register key on first use. Return NULL if registration is unavailable,
// the table is full, or registration cannot allocate its state.
static coverage_module* module_for(ErlNifEnv* env, ERL_NIF_TERM key, size_t edge_count) {
    size_t count = __atomic_load_n(&module_count, __ATOMIC_ACQUIRE);
    coverage_module* found = find_module(key, count);
    if (found != NULL) {
        return found;
    }
    // Failed lookups need no lock once the table is full.
    if (voidstar.init_coverage_module == NULL || edge_count == 0 || count == MAX_COVERAGE_MODULES) {
        return NULL;
    }

    pthread_mutex_lock(&register_lock);
    count = module_count;
    found = find_module(key, count);
    if (found == NULL && count < MAX_COVERAGE_MODULES) {
        // The filename must match the instrumentor's <key>.sym.tsv output.
        char name[512];
        if (enif_get_atom(env, key, name, sizeof name - strlen(".sym.tsv"), ERL_NIF_UTF8) > 0) {
            strcat(name, ".sym.tsv");
            uint64_t* leases = calloc(edge_count + 1, sizeof(uint64_t));
            if (leases != NULL) {
                found = &modules[count];
                found->key = key;
                found->edge_count = edge_count;
                found->offset = voidstar.init_coverage_module(edge_count, name);
                found->leases = leases;
                __atomic_store_n(&module_count, count + 1, __ATOMIC_RELEASE);
            }
        }
    }
    pthread_mutex_unlock(&register_lock);
    return found;
}

// Consume one hit if the lease has capacity and matches the generation read
// below. On failure, return the last observed lease word in *observed.
// Rechecking capacity on each CAS attempt prevents the decrement from borrowing
// from the granted field.
static bool lease_local_hit(uint64_t* slot, uint64_t* observed) {
    uint64_t word = __atomic_load_n(slot, __ATOMIC_RELAXED);
    while ((word & LEASE_FIELD_MASK) != 0) {
        // Recheck revocation after each failed CAS.
        uint64_t epoch = __atomic_load_n(voidstar.lease_generation, __ATOMIC_ACQUIRE) & LEASE_EPOCH_MASK;
        if (((word >> LEASE_EPOCH_SHIFT) & LEASE_EPOCH_MASK) != epoch) {
            break;
        }
        if (__atomic_compare_exchange_n(slot, &word, word - 1, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            return true;
        }
    }
    *observed = word;
    return false;
}

// hit(ModuleKey, EdgeCount, Edge), called by each instrumented coverage probe.
static ERL_NIF_TERM hit(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    if (voidstar.handle == NULL) {
        return atom_ok;
    }
    unsigned long edge_count;
    unsigned long edge;
    if (!enif_get_ulong(env, argv[1], &edge_count) || !enif_get_ulong(env, argv[2], &edge)) {
        return enif_make_badarg(env);
    }
    coverage_module* module = module_for(env, argv[0], edge_count);
    if (module == NULL || edge == 0 || edge > module->edge_count) {
        return atom_ok;
    }
    uint64_t* slot = &module->leases[edge];

    if (voidstar.notify_coverage_v2 == NULL) {
        // ABI 1 retires an edge when notify_coverage returns false.
        if (__atomic_load_n(slot, __ATOMIC_RELAXED) == 0 &&
            !voidstar.notify_coverage(edge + module->offset)) {
            __atomic_store_n(slot, 1, __ATOMIC_RELAXED);
        }
        return atom_ok;
    }

    uint64_t word;
    if (lease_local_hit(slot, &word)) {
        return atom_ok;
    }
    // Clearing the lease claims its accumulated hits for one reporter,
    // preventing duplicate reports. An empty slot has no accumulated hits.
    while (!__atomic_compare_exchange_n(slot, &word, 0, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
        if (lease_local_hit(slot, &word)) {
            return atom_ok;
        }
    }
    uint64_t granted = (word >> LEASE_GRANTED_SHIFT) & LEASE_FIELD_MASK;
    uint64_t fresh = voidstar.notify_coverage_v2(edge + module->offset, granted - (word & LEASE_FIELD_MASK));
    // Preserve any lease another thread installed: it may have accumulated hits.
    // Discard this unused grant if the slot is occupied.
    uint64_t empty = 0;
    __atomic_compare_exchange_n(slot, &empty, fresh, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
    return atom_ok;
}

static ErlNifFunc nif_funcs[] = {
    {"available", 0, available, 0},
    {"output", 1, output, 0},
    {"get_random", 0, get_random, 0},
    {"hit", 3, hit, 0},
};

ERL_NIF_INIT(antithesis_nif, nif_funcs, on_load, NULL, NULL, NULL)
