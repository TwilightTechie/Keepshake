/* Runs the production TX pump and queue cleanup with deterministic fake BLE. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../app/src/protocol.h"
#define ARG_UNUSED(x) ((void)(x))
#define K_NO_WAIT 0
#define K_MSEC(x) (x)
#define MIN(a,b) ((a)<(b)?(a):(b))
#define __noinit
typedef int32_t atomic_t;
typedef int32_t atomic_val_t;
static int32_t atomic_get(const atomic_t *p) { return *p; }
static void atomic_set(atomic_t *p, int32_t n) { *p = n; }
static void atomic_inc(atomic_t *p) { ++*p; }
static void atomic_add(atomic_t *p, int32_t n) { *p += n; }
static bool atomic_cas(atomic_t *p, int32_t old, int32_t n) {
    if (*p != old) return false; *p = n; return true;
}
struct k_work { int unused; };
struct k_work_delayable { int unused; };
struct k_mem_slab { unsigned used; };
struct k_msgq { void *items[8]; unsigned count; };
#define K_MEM_SLAB_DEFINE_STATIC(name, size, count, align) static struct k_mem_slab name
#define K_MSGQ_DEFINE(name, size, count, align) static struct k_msgq name
#define K_WORK_DELAYABLE_DEFINE(name, fn) static struct k_work_delayable name
static unsigned k_msgq_num_used_get(struct k_msgq *q) { return q->count; }
static unsigned k_mem_slab_num_used_get(struct k_mem_slab *s) { return s->used; }
static void k_mem_slab_free(struct k_mem_slab *s, void *p) {
    assert(s->used); --s->used; free(p);
}
static int k_msgq_get(struct k_msgq *q, void *out, int wait) {
    assert(wait == K_NO_WAIT);
    if (!q->count) return -ENOMSG;
    *(void **)out = q->items[0];
    memmove(q->items, q->items + 1, --q->count * sizeof(void *)); return 0;
}
static uint32_t now;
static uint32_t k_uptime_get_32(void) { return now; }
static uint32_t k_cycle_get_32(void) { return now * 1000; }
static uint32_t k_cyc_to_us_floor32(uint32_t n) { return n; }
static unsigned scheduled_delay;
static int k_work_schedule(struct k_work_delayable *w, unsigned delay) {
    (void)w; scheduled_delay = delay; return 1;
}
static void k_sleep(unsigned delay) { now += delay; }
struct bt_conn { int unused; };
static struct bt_conn link;
static bool connected = true;
static struct bt_conn *connection_ref(void) { return connected ? &link : NULL; }
static void bt_conn_unref(struct bt_conn *c) { assert(c == &link); }
static struct { int attrs[3]; } keepsake_service;
struct bt_gatt_notify_params {
    void *attr;
    void *data;
    uint16_t len;
    void (*func)(struct bt_conn *, void *);
    void *user_data;
};
static int send_error;
static unsigned calls, sent, bytes, callbacks;
static uint32_t expected_seq;
static struct bt_gatt_notify_params pending[1024];
static int bt_gatt_notify_cb(struct bt_conn *c, struct bt_gatt_notify_params *p) {
    assert(c == &link); calls++;
    if (send_error) return send_error;
    const uint8_t *raw = p->data;
    uint32_t seq = raw[0] | (uint32_t)raw[1]<<8 | (uint32_t)raw[2]<<16 | (uint32_t)raw[3]<<24;
    assert(seq == expected_seq++ && raw[4] == 0);
    for (unsigned i = 5; i < p->len; ++i) assert(raw[i] == (uint8_t)(bytes++));
    assert(callbacks < 1024); pending[callbacks++] = *p; sent++;
    return 0; /* Data is copied synchronously by real Zephyr; callback is deferred. */
}
static void complete_all(void) {
    for (unsigned i = 0; i < callbacks; ++i) pending[i].func(&link, pending[i].user_data);
    callbacks = 0;
}
static atomic_t subscribed = 1, generation = 1, tx_drops, last_tx_ms;
static struct k_mem_slab mic_slab;
#define DMIC_TRIGGER_STOP 0
#define MIC_PWR_PIN 0
static void *mic;
static int dmic_trigger(void *d, int c) { (void)d; (void)c; return 0; }
static int dmic_read(void *d, int ch, void *buf, void *size, int timeout) {
    (void)d; (void)ch; (void)buf; (void)size; assert(!timeout); return -1;
}
static void nrf_gpio_pin_clear(int pin) { (void)pin; }
#include "transport_under_test.inc"
static void enqueue(size_t payload, uint32_t seq) {
    assert(audio_queue.count < 8 && audio_pool.used < 10);
    struct audio_block *b = calloc(1, sizeof(*b)); assert(b);
    audio_pool.used++;
    b->generation = generation; b->first_seq = seq; b->payload = payload; b->captured_ms = now;
    for (unsigned i = 0; i < KS_BLOCK_BYTES; ++i) b->pcm[i] = (uint8_t)i;
    audio_queue.items[audio_queue.count++] = b; record_queue();
}
static void pump(void) {
    unsigned before = calls;
    send_work(NULL);
    assert(calls - before <= 4); // The shared workqueue must always get control back.
}
int main(void) {
    /* Exact byte preservation, packet sequence wrap and both small/full MTU. */
    for (unsigned mtu = 23; mtu <= 247; mtu += 224) {
        bytes = 0; expected_seq = UINT32_MAX - 2; sent = 0;
        enqueue(ks_payload(mtu), expected_seq);
        while (audio_pool.used) { pump(); now++; complete_all(); }
        assert(bytes == KS_BLOCK_BYTES && sent == ks_packet_count(KS_BLOCK_BYTES, ks_payload(mtu)));
    }
    /* Exhaustion returns after ONE attempt; completion cannot be blocked by retry sleep. */
    send_error = -ENOMEM; enqueue(232, 0); unsigned before = calls;
    pump(); assert(calls == before + 1 && scheduled_delay == 2 && audio_pool.used == 1);
    assert(retained_trace.transport[TM_BUSY] == 1);
    now += 250; pump(); assert(!audio_pool.used && tx_drops == 14);
    assert(retained_trace.transport[TM_EXPIRED] == 1);
    /* Fatal send failure releases ownership, with the exact error retained. */
    send_error = -ENOTCONN; enqueue(232, 0); pump();
    assert(!audio_pool.used && retained_trace.transport[TM_LAST_ERROR] == -ENOTCONN);
    /* A disconnect drains queued blocks and the worker releases its partial block. */
    send_error = -EAGAIN; enqueue(232, 0); pump();
    for (int i = 0; i < 8; ++i) enqueue(232, 14 + 14*i);
    generation++; subscribed = 0; mic_stop(); pump();
    assert(!audio_pool.used && !audio_queue.count);
    /* Pending old-generation completions cannot advance the new session watchdog. */
    subscribed = 1; send_error = 0; bytes = 0; expected_seq = 0;
    enqueue(232, 0); pump(); generation++; last_tx_ms = 123;
    now += 20; complete_all(); assert(last_tx_ms == 123); pump();
    assert(!audio_pool.used);
    /* A current-generation completion advances progress. */
    bytes = 0; expected_seq = 0; enqueue(232, 0); pump();
    now += 10; complete_all(); assert((uint32_t)last_tx_ms == now);
    generation++; pump(); assert(!audio_pool.used);
    puts("PASS: bounded TX, retry/expiry, byte preservation, queue cleanup, generation-fenced completion");
}
