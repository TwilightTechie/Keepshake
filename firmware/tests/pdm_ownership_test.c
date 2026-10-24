/* Host harness for the actual driver's event_handler, extracted by run_host_tests.py.
 * Fake DMA tracks ownership; returning/freeing a live DMA buffer is a failure.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define K_NO_WAIT 0
#define NRFX_SUCCESS 0
#define LOG_DBG(...) ((void)0)
#define LOG_ERR(...) ((void)0)
typedef int nrfx_pdm_t;
typedef int nrfx_err_t;
typedef int nrfx_pdm_config_t;
typedef void (*nrfx_pdm_event_handler_t)(void);
struct onoff_client { int unused; };
struct k_msgq { void *items[16]; unsigned count, capacity; };
struct k_mem_slab { int unused; };
struct device { void *data; const void *config; };
typedef struct { bool buffer_requested; void *buffer_released; } nrfx_pdm_evt_t;
static unsigned char pool[10][32];
static bool allocated[10], dma[10];
static void *hardware[4];
static unsigned hardware_count;
static unsigned releases;
static int slot(void *p) {
    for (int i = 0; i < 10; i++) if (p == pool[i]) return i;
    abort();
}
static int k_mem_slab_alloc(struct k_mem_slab *s, void **out, int timeout) {
    (void)s; assert(timeout == K_NO_WAIT);
    for (int i = 0; i < 10; i++) if (!allocated[i]) {
        allocated[i] = true; *out = pool[i]; return 0;
    }
    return -1;
}
static void k_mem_slab_free(struct k_mem_slab *s, void *p) {
    (void)s;
    int i = slot(p); assert(allocated[i] && !dma[i]); allocated[i] = false;
}
static int k_msgq_put(struct k_msgq *q, void *p, int timeout) {
    assert(timeout == K_NO_WAIT);
    if (q->count == q->capacity) return -1;
    q->items[q->count++] = *(void **)p; return 0;
}
static int k_msgq_get(struct k_msgq *q, void *p, int timeout) {
    assert(timeout == K_NO_WAIT);
    if (!q->count) return -1;
    *(void **)p = q->items[0];
    memmove(q->items, q->items + 1, --q->count * sizeof(void *)); return 0;
}
static int dmm_buffer_in_prepare(void *reg, void *p, uint32_t size, void **out) {
    (void)reg; (void)size; *out = p; return 0;
}
static int dmm_buffer_in_release(void *reg, void *p, uint32_t size, void *done) {
    /* Like the nRF52840 build, this is a no-op. */
    (void)reg; (void)p; (void)size; (void)done; return 0;
}
static int nrfx_pdm_buffer_set(const nrfx_pdm_t *pdm, void *p, uint32_t size) {
    (void)pdm; (void)size;
    assert(hardware_count < 4 && !dma[slot(p)]);
    dma[slot(p)] = true; hardware[hardware_count++] = p; return NRFX_SUCCESS;
}
static void nrfx_pdm_stop(const nrfx_pdm_t *p) { (void)p; }
static int onoff_release(void *p) { (void)p; return 0; }
#include "pdm_under_test.inc"

static struct k_mem_slab slab;
static struct dmic_nrfx_pdm_drv_data state;
static struct dmic_nrfx_pdm_drv_cfg config;
static struct device dev = { &state, &config };
static void request(void) {
    nrfx_pdm_evt_t e = { .buffer_requested = true }; event_handler(&dev, &e);
}
static void *release(bool request_next) {
    assert(hardware_count);
    void *done = hardware[0];
    memmove(hardware, hardware + 1, --hardware_count * sizeof(void *));
    dma[slot(done)] = false;
    nrfx_pdm_evt_t e = { .buffer_requested = request_next, .buffer_released = done };
    event_handler(&dev, &e); releases++; return done;
}
static void reset_fixture(void) {
    memset(&state, 0, sizeof(state)); memset(allocated, 0, sizeof(allocated));
    memset(dma, 0, sizeof(dma)); hardware_count = 0;
    state.mem_slab = &slab; state.block_size = 32; state.active = true;
    state.rx_queue.capacity = 4;
#ifndef ORIGINAL_DRIVER
    state.mem_slab_queue.capacity = 4;
#endif
}
static void stop_and_drain(void) {
    state.stopping = true;
    while (hardware_count) release(false);
    void *p;
    while (!k_msgq_get(&state.rx_queue, &p, K_NO_WAIT)) k_mem_slab_free(&slab, p);
    for (unsigned i = 0; i < 10; ++i) assert(!allocated[i] && !dma[i]);
}
int main(void) {
    for (unsigned session = 0; session < 100; ++session) {
        reset_fixture(); request(); request();
        for (unsigned frame = 0; frame < 100; ++frame) {
            void *expected = release(true), *actual;
            assert(!k_msgq_get(&state.rx_queue, &actual, K_NO_WAIT));
            if (actual != expected || dma[slot(actual)]) {
                puts("REPRODUCED: driver returned an in-flight DMA buffer instead of the completed buffer");
                return 42;
            }
            k_mem_slab_free(&slab, actual);
        }
        stop_and_drain();
    }
    reset_fixture(); request(); request();
    /* Full consumer queue must free exactly the completed buffer and stop. */
    while (!state.stopping) release(true);
    stop_and_drain();
    /* Slab exhaustion on request still releases old DMA buffers correctly. */
    reset_fixture(); request(); request();
    void *held[8];
    for (int i = 0; i < 8; ++i) assert(!k_mem_slab_alloc(&slab, &held[i], 0));
    release(true); assert(state.stopping);
    for (int i = 0; i < 8; ++i) k_mem_slab_free(&slab, held[i]);
    stop_and_drain();
    printf("PASS: DMA ownership, %u completions, 100 stop/restarts, queue/slab exhaustion\n", releases);
}
