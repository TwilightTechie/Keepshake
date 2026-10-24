/* Keepsake raw gateway firmware, XIAO nRF52840 Sense.
 * Native PCM16/16 kHz; no VAD, gain processing, resampling, or codec.
 * Packet contract: [u32 LE sequence][u8 flags=0][PCM bytes].
 */
#include <hal/nrf_gpio.h>
#include <hal/nrf_pdm.h>
#include <hal/nrf_power.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/random/random.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/reboot.h>
#include "protocol.h"
#include "recovery.h"

LOG_MODULE_REGISTER(keepsake, LOG_LEVEL_INF);
#define MIC_PWR_PIN NRF_GPIO_PIN_MAP(1, 10)
#define IMU_PWR_PIN NRF_GPIO_PIN_MAP(1, 8)
#define BATTERY_SENSE_ENABLE_PIN NRF_GPIO_PIN_MAP(0, 14)
#define CHARGE_STATUS_PIN NRF_GPIO_PIN_MAP(0, 17)
#define UUID(n) BT_UUID_128_ENCODE(0x6b656570, 0x7361, 0x6b65, 0x0001, ((uint64_t)(n)))
static const struct bt_uuid_128 service_uuid = BT_UUID_INIT_128(UUID(1));
static const struct bt_uuid_128 audio_uuid = BT_UUID_INIT_128(UUID(2));
static const struct bt_uuid_128 info_uuid = BT_UUID_INIT_128(UUID(3));
static const struct bt_uuid_128 status_uuid = BT_UUID_INIT_128(UUID(4));
static const struct bt_uuid_128 battery_uuid = BT_UUID_INIT_128(UUID(5));
static const struct bt_uuid_128 link_events_uuid = BT_UUID_INIT_128(UUID(6));
static const struct bt_uuid_128 reset_trace_uuid = BT_UUID_INIT_128(UUID(7));
static const struct bt_uuid_128 transport_uuid = BT_UUID_INIT_128(UUID(8));
static const struct bt_uuid_128 previous_transport_uuid = BT_UUID_INIT_128(UUID(9));
static const struct device *const mic = DEVICE_DT_GET(DT_NODELABEL(pdm0));
static const struct device *const watchdog = DEVICE_DT_GET(DT_ALIAS(watchdog0));
static const struct adc_dt_spec battery_adc = ADC_DT_SPEC_GET(DT_PATH(zephyr_user));
K_MEM_SLAB_DEFINE_STATIC(mic_slab, KS_BLOCK_BYTES, 10, 4);
K_SEM_DEFINE(capture_wake, 0, 1);
static atomic_t subscribed, generation, connected, watchdog_ready;
static atomic_t queue_drops, tx_drops, mic_restarts, last_tx_ms, last_capture_ms;
static uint8_t stream_info[KS_INFO_BYTES];
static uint32_t reset_reason;
static struct bt_conn *connection;
static struct k_spinlock connection_lock;
#define WATCHDOG_TIMEOUT_MS 30000U
static int watchdog_channel = -1;
/* RAM in .noinit survives a watchdog reset on this SoC. Keep each live field
 * naturally aligned and write the validity marker only after initialization.
 * The trace is diagnostic only: it never controls capture or recovery.
 */
#define TRACE_MAGIC 0x4b545233U
enum transport_metric {
    TM_CAPTURED, TM_SUBMITTED, TM_COMPLETED, TM_BUSY, TM_LAST_ERROR,
    TM_MAX_NOTIFY_US, TM_QUEUE_DROPS, TM_TX_DROPS, TM_EXPIRED, TM_MIC_ERRORS,
    TM_QUEUE_HIGH, TM_QUEUE_DEPTH, TM_POOL_USED, TM_LAST_COMPLETE_MS, TM_COUNT
};
enum main_phase {
    PHASE_BOOT = 1, PHASE_FEED, PHASE_CHECK, PHASE_MIC_STOP, PHASE_IDLE,
    PHASE_MIC_START, PHASE_READ, PHASE_LINK, PHASE_QUEUE, PHASE_FREE,
    PHASE_TX_RECOVERY_RESET, PHASE_SUPERVISION_RESET,
};
enum work_phase { WORK_IDLE, WORK_BATTERY, WORK_DISCONNECT, WORK_ADVERTISE };
enum sender_phase { SENDER_IDLE, SENDER_DEQUEUE, SENDER_NOTIFY };
struct reset_trace {
    volatile uint32_t magic;
    volatile uint32_t magic_inverse;
    volatile uint32_t last_feed_ms;
    volatile uint32_t phase_enter_ms;
    volatile int32_t last_feed_error;
    volatile uint8_t main_phase;
    volatile uint8_t work_phase;
    volatile uint8_t sender_phase;
    volatile uint8_t reserved;
    atomic_t transport[TM_COUNT];
};
static struct reset_trace retained_trace __noinit;
static struct reset_trace previous_trace;
static bool previous_trace_valid;
static void trace_main(uint8_t phase)
{
    retained_trace.main_phase = phase;
    retained_trace.phase_enter_ms = k_uptime_get_32();
}
static void trace_boot(void)
{
    previous_trace_valid = (reset_reason & 0x06U) &&
        retained_trace.magic == TRACE_MAGIC &&
        retained_trace.magic_inverse == ~TRACE_MAGIC;
    if (previous_trace_valid) { previous_trace = retained_trace; }
    memset((void *)&retained_trace, 0, sizeof(retained_trace));
    retained_trace.main_phase = PHASE_BOOT;
    retained_trace.phase_enter_ms = k_uptime_get_32();
    retained_trace.magic_inverse = ~TRACE_MAGIC;
    retained_trace.magic = TRACE_MAGIC;
}
static atomic_t disconnected_at;
static atomic_t disconnect_count, last_disconnect_reason, last_disconnect_cause;
static atomic_t last_connection_ms, connected_at, last_disconnect_battery_mv;
static atomic_t disconnect_request_cause;
static atomic_t battery_mv;
static atomic_t last_supervision_ms;
static bool battery_adc_ready;
static uint32_t battery_last_sample_ms;
struct audio_block {
    uint32_t generation;
    uint32_t first_seq;
    uint32_t captured_ms;
    uint16_t payload;
    uint8_t pcm[KS_BLOCK_BYTES];
};
/* Copy PCM outside kernel locks. Queue only pointers; pool ownership transfers
 * capture -> queue -> TX worker -> pool, including overflow/disconnect paths.
 */
K_MEM_SLAB_DEFINE_STATIC(audio_pool, sizeof(struct audio_block), 10, 4);
K_MSGQ_DEFINE(audio_queue, sizeof(struct audio_block *), 8, 4);
static void send_work(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(audio_tx, send_work);
static void metric_inc(enum transport_metric metric)
{
    atomic_inc(&retained_trace.transport[metric]);
}
static void record_queue(void)
{
    uint32_t depth = k_msgq_num_used_get(&audio_queue);
    atomic_set(&retained_trace.transport[TM_QUEUE_DEPTH], depth);
    atomic_set(&retained_trace.transport[TM_POOL_USED], k_mem_slab_num_used_get(&audio_pool));
    atomic_val_t high = atomic_get(&retained_trace.transport[TM_QUEUE_HIGH]);
    while (depth > (uint32_t)high && !atomic_cas(&retained_trace.transport[TM_QUEUE_HIGH], high, depth)) {
        high = atomic_get(&retained_trace.transport[TM_QUEUE_HIGH]);
    }
}
static void release_audio(struct audio_block *block)
{
    k_mem_slab_free(&audio_pool, block);
    record_queue();
}
static void discard_audio(struct audio_block *block, size_t offset)
{
    unsigned dropped = ks_packet_count(KS_BLOCK_BYTES - offset, block->payload);
    atomic_add(&tx_drops, dropped);
    atomic_add(&retained_trace.transport[TM_TX_DROPS], dropped);
    release_audio(block);
}

static void feed_watchdog(void)
{
    trace_main(PHASE_FEED);
    if (atomic_get(&watchdog_ready) && watchdog_channel >= 0) {
        int err = wdt_feed(watchdog, watchdog_channel);
        retained_trace.last_feed_error = err;
        if (!err) { retained_trace.last_feed_ms = k_uptime_get_32(); }
    }
}
static void restart(const char *reason)
{
    LOG_ERR("Recovery reset: %s", reason);
    ARG_UNUSED(reason);
    nrf_gpio_pin_clear(MIC_PWR_PIN);
    sys_reboot(SYS_REBOOT_COLD);
}
/* Check from capture/idle, independently of the sender and supervision worker.
 * A live microphone must not keep a broken Bluetooth path alive indefinitely.
 */
static void check_recovery_progress(void)
{
    uint32_t now = k_uptime_get_32();
    enum ks_recovery_action action = ks_recovery_due(now,
        (uint32_t)atomic_get(&last_supervision_ms), (uint32_t)atomic_get(&last_tx_ms),
        atomic_get(&subscribed) && atomic_get(&connected));
    if (action == KS_RECOVERY_SUPERVISOR) {
        trace_main(PHASE_SUPERVISION_RESET);
        restart("supervisor made no progress for 20 seconds");
    }
    if (action == KS_RECOVERY_TX) {
        trace_main(PHASE_TX_RECOVERY_RESET);
        restart("subscribed Bluetooth TX made no progress for 15 seconds");
    }
}
/* Shared pointer ownership is protected; callers hold their own reference. */
static struct bt_conn *connection_ref(void)
{
    k_spinlock_key_t key = k_spin_lock(&connection_lock);
    struct bt_conn *ref = connection ? bt_conn_ref(connection) : NULL;
    k_spin_unlock(&connection_lock, key);
    return ref;
}
static void ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ARG_UNUSED(attr);
    atomic_clear(&subscribed);
    atomic_inc(&generation); /* Queued audio must not cross subscription sessions. */
    atomic_set(&last_tx_ms, k_uptime_get_32());
    atomic_set(&subscribed, value == BT_GATT_CCC_NOTIFY);
    k_sem_give(&capture_wake);
    LOG_INF("Audio subscription %u", value);
}
static ssize_t read_info(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                         void *buf, uint16_t len, uint16_t offset)
{
    return bt_gatt_attr_read(conn, attr, buf, len, offset, stream_info, sizeof(stream_info));
}
static ssize_t read_status(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                           void *buf, uint16_t len, uint16_t offset)
{
    uint8_t status[20];
    memcpy(status, "KST1", 4);
    ks_put32(atomic_get(&queue_drops), status + 4);
    ks_put32(atomic_get(&tx_drops), status + 8);
    ks_put32(atomic_get(&mic_restarts), status + 12);
    ks_put32(reset_reason, status + 16);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, status, sizeof(status));
}
/* KSE1 describes the previous connection and fits a default ATT read. */
static ssize_t read_link_events(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                void *buf, uint16_t len, uint16_t offset)
{
    uint8_t value[20] = {0};
    memcpy(value, "KSE1", 4);
    ks_put32(atomic_get(&disconnect_count), value + 4);
    ks_put32(atomic_get(&last_connection_ms), value + 8);
    uint16_t mv = (uint16_t)atomic_get(&last_disconnect_battery_mv);
    value[12] = (uint8_t)mv; value[13] = (uint8_t)(mv >> 8);
    value[14] = (uint8_t)atomic_get(&last_disconnect_reason);
    value[15] = (uint8_t)atomic_get(&last_disconnect_cause);
    uint16_t mtu = bt_gatt_get_mtu(conn);
    value[16] = (uint8_t)mtu; value[17] = (uint8_t)(mtu >> 8);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}
/* KTR3 reports the previous boot after watchdog or software recovery reset. */
static ssize_t read_reset_trace(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                void *buf, uint16_t len, uint16_t offset)
{
    uint8_t value[20] = {0};
    memcpy(value, "KTR3", 4);
    value[4] = previous_trace_valid ? 1 : 0;
    if (previous_trace_valid) {
        value[5] = previous_trace.main_phase;
        value[6] = previous_trace.work_phase;
        value[7] = previous_trace.sender_phase;
        ks_put32(previous_trace.last_feed_ms, value + 8);
        ks_put32(previous_trace.phase_enter_ms, value + 12);
        ks_put32((uint32_t)previous_trace.last_feed_error, value + 16);
    }
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}
/* Stable snapshot across ATT Read Blob at the default MTU. */
static ssize_t read_transport(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                               void *buf, uint16_t len, uint16_t offset)
{
    static uint8_t snapshots[2][64];
    bool previous = attr->user_data != NULL;
    uint8_t *value = snapshots[previous ? 1 : 0];
    if (offset == 0) {
        memset(value, 0, 64);
        memcpy(value, "KTP1", 4);
        ks_put32(previous ? (previous_trace_valid ? 2 : 0) : 1, value + 4);
        for (unsigned i = 0; i < TM_COUNT; ++i) {
            uint32_t metric = previous ? (previous_trace_valid ? previous_trace.transport[i] : 0) :
                atomic_get(&retained_trace.transport[i]);
            ks_put32(metric, value + 8 + 4 * i);
        }
    }
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, 64);
}
static void sample_battery(void)
{
    if (!battery_adc_ready) { return; }
    /* Do not run SAADC conversions while PDM microphone is actively streaming audio
     * to prevent nRF52840 EasyDMA bus contention / lockups.
     */
    if (atomic_get(&subscribed)) { return; }
    uint16_t raw = 0;
    struct adc_sequence sequence = { .buffer = &raw, .buffer_size = sizeof(raw) };
    int32_t sense_mv;
    if (adc_sequence_init_dt(&battery_adc, &sequence) || adc_read_dt(&battery_adc, &sequence)) {
        return;
    }
    sense_mv = raw;
    if (adc_raw_to_millivolts_dt(&battery_adc, &sense_mv)) { return; }
    /* Current XIAO Sense divider: 1 MΩ above 510 kΩ. */
    int32_t mv = sense_mv * 1510 / 510;
    atomic_set(&battery_mv, mv >= 2500 && mv <= 4500 ? mv : 0);
}
static ssize_t read_battery(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                            void *buf, uint16_t len, uint16_t offset)
{
    uint16_t mv = (uint16_t)atomic_get(&battery_mv);
    /* CHG is active low; keep voltage as the first two bytes for older apps. */
    uint8_t value[3] = { (uint8_t)mv, (uint8_t)(mv >> 8),
                         nrf_gpio_pin_read(CHARGE_STATUS_PIN) == 0 ? 1 : 0 };
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}
BT_GATT_SERVICE_DEFINE(keepsake_service,
    BT_GATT_PRIMARY_SERVICE(&service_uuid),
    BT_GATT_CHARACTERISTIC(&audio_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE,
                           NULL, NULL, NULL),
    BT_GATT_CCC(ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    BT_GATT_CHARACTERISTIC(&info_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_info, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&status_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_status, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&battery_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_battery, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&link_events_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_link_events, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&reset_trace_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_reset_trace, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&transport_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_transport, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&previous_transport_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_transport, NULL, (void *)1)
);
/* Service UUID in primary advertising helps background service-filtered scans. */
static const struct bt_data advertising_data[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR),
    BT_DATA_BYTES(BT_DATA_UUID128_ALL, UUID(1)),
};
static const struct bt_data scan_data[] = {
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};
static atomic_t advertising;
static bool advertising_slow;
static uint32_t adv_failure_since;
static bool adv_failed;
/* ADC and synchronous HCI operations may wait. Never hold up the shared
 * system workqueue, which Bluetooth also needs to complete TX/disconnection.
 */
K_THREAD_STACK_DEFINE(supervision_stack, 2048);
static struct k_work_q supervision_queue;
static void supervise(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(supervision, supervise);
static void supervise(struct k_work *work)
{
    ARG_UNUSED(work);
    uint32_t now = k_uptime_get_32();
    uint32_t battery_interval = atomic_get(&connected) ? 15000U : 30000U;
    if (!battery_last_sample_ms || (uint32_t)(now - battery_last_sample_ms) >= battery_interval) {
        battery_last_sample_ms = now;
        retained_trace.work_phase = WORK_BATTERY;
        sample_battery();
    }
    if (atomic_get(&connected)) {
        atomic_clear(&advertising);
        adv_failed = false;
        if (atomic_get(&subscribed) && (int32_t)(now - atomic_get(&last_tx_ms)) > 5000 &&
            (int32_t)(now - atomic_get(&last_capture_ms)) < 1500) {
            struct bt_conn *conn = connection_ref();
            if (conn) {
                retained_trace.work_phase = WORK_DISCONNECT;
                atomic_set(&disconnect_request_cause, 1); /* TX stalled; request recovery. */
                if (bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN)) {
                    atomic_clear(&disconnect_request_cause);
                }
                bt_conn_unref(conn);
            }
        }
    } else {
        retained_trace.work_phase = WORK_ADVERTISE;
        bool slow = (uint32_t)(now - atomic_get(&disconnected_at)) >= 30000U;
        if (atomic_get(&advertising) && slow != advertising_slow) {
            int err = bt_le_adv_stop();
            if (!err || err == -EALREADY) { atomic_clear(&advertising); }
        }
        if (!atomic_get(&advertising)) {
            retained_trace.work_phase = WORK_ADVERTISE;
            const struct bt_le_adv_param *param = slow ?
                BT_LE_ADV_PARAM(BT_LE_ADV_OPT_CONN, 1600, 1920, NULL) : BT_LE_ADV_CONN_FAST_2;
            int err = bt_le_adv_start(param, advertising_data, ARRAY_SIZE(advertising_data),
                                      scan_data, ARRAY_SIZE(scan_data));
            if (!err || err == -EALREADY) {
                atomic_set(&advertising, 1); advertising_slow = slow; adv_failed = false;
            } else if (!adv_failed) {
                adv_failure_since = now; adv_failed = true;
            } else if ((uint32_t)(now - adv_failure_since) >= 30000U) {
                restart("advertising failed for 30 seconds");
            }
        }
    }
    retained_trace.work_phase = WORK_IDLE;
    atomic_set(&last_supervision_ms, k_uptime_get_32());
    k_work_reschedule_for_queue(&supervision_queue, &supervision, K_SECONDS(1));
}
static void on_connected(struct bt_conn *conn, uint8_t err)
{
    atomic_clear(&advertising);
    if (err) { return; }
    k_spinlock_key_t key = k_spin_lock(&connection_lock);
    connection = bt_conn_ref(conn);
    k_spin_unlock(&connection_lock, key);
    atomic_set(&connected, 1);
    atomic_set(&connected_at, k_uptime_get_32());
    atomic_clear(&disconnect_request_cause);
    LOG_INF("Phone connected");
    atomic_clear(&subscribed);
    atomic_inc(&generation);
    (void)bt_conn_le_param_update(conn, BT_LE_CONN_PARAM(12, 12, 0, 400));
}
static void on_disconnected(struct bt_conn *conn, uint8_t reason)
{
    ARG_UNUSED(conn);
    uint32_t now = k_uptime_get_32();
    atomic_inc(&disconnect_count);
    atomic_set(&last_disconnect_reason, reason);
    atomic_set(&last_disconnect_cause, atomic_get(&disconnect_request_cause));
    atomic_clear(&disconnect_request_cause);
    atomic_set(&last_connection_ms, now - (uint32_t)atomic_get(&connected_at));
    atomic_set(&last_disconnect_battery_mv, atomic_get(&battery_mv));
    LOG_INF("Phone disconnected: HCI 0x%02x, local cause %d, duration %u ms, battery %d mV",
            reason, (int)atomic_get(&last_disconnect_cause),
            (uint32_t)atomic_get(&last_connection_ms), (int)atomic_get(&last_disconnect_battery_mv));
    atomic_clear(&subscribed);
    atomic_inc(&generation);
    k_spinlock_key_t key = k_spin_lock(&connection_lock);
    struct bt_conn *old = connection;
    connection = NULL;
    k_spin_unlock(&connection_lock, key);
    atomic_set(&disconnected_at, now);
    atomic_clear(&connected);
    if (old) { bt_conn_unref(old); }
    k_sem_give(&capture_wake);
}
static void on_recycled(void)
{
    k_work_reschedule_for_queue(&supervision_queue, &supervision, K_NO_WAIT);
}
static void on_param_updated(struct bt_conn *conn, uint16_t interval,
                             uint16_t latency, uint16_t timeout)
{
    ARG_UNUSED(conn);
    LOG_INF("Link parameters: interval %u (1.25 ms units), latency %u, timeout %u (10 ms units)",
            interval, latency, timeout);
}
static void on_phy_updated(struct bt_conn *conn, struct bt_conn_le_phy_info *info)
{
    ARG_UNUSED(conn);
    LOG_INF("Link PHY: TX %u, RX %u", info->tx_phy, info->rx_phy);
}
static void on_data_len_updated(struct bt_conn *conn, struct bt_conn_le_data_len_info *info)
{
    ARG_UNUSED(conn);
    LOG_INF("Link data length: TX %u, RX %u", info->tx_max_len, info->rx_max_len);
}
BT_CONN_CB_DEFINE(connection_callbacks) = {
    .connected = on_connected, .disconnected = on_disconnected, .recycled = on_recycled,
    .le_param_updated = on_param_updated, .le_phy_updated = on_phy_updated,
    .le_data_len_updated = on_data_len_updated,
};
/* Host-stack TX completion is not an application-level ACK. Old subscription
 * callbacks must not keep a newer subscription healthy.
 */
static void notify_complete(struct bt_conn *conn, void *user_data)
{
    ARG_UNUSED(conn);
    metric_inc(TM_COMPLETED);
    uint32_t now = k_uptime_get_32();
    atomic_set(&retained_trace.transport[TM_LAST_COMPLETE_MS], now);
    if ((uint32_t)(uintptr_t)user_data == (uint32_t)atomic_get(&generation) &&
        atomic_get(&subscribed)) {
        atomic_set(&last_tx_ms, now);
    }
}
/* Zephyr v4.1 ATT allocation uses K_NO_WAIT from the system workqueue, but
 * K_FOREVER from a normal sender thread. At most four packets per invocation;
 * no sleeps or HCI commands. ADC/disconnect/advertising stay on the private queue.
 */
static void send_work(struct k_work *work)
{
    ARG_UNUSED(work);
    static struct audio_block *block;
    static size_t offset;
    uint8_t packet[KS_HEADER_BYTES + KS_MAX_PAYLOAD];
    bool backpressure = false;
    for (unsigned budget = 0; budget < 4; ++budget) {
        retained_trace.sender_phase = SENDER_DEQUEUE;
        if (!block) {
            if (k_msgq_get(&audio_queue, &block, K_NO_WAIT)) { break; }
            offset = 0;
            record_queue();
        }
        bool stale = !atomic_get(&subscribed) ||
            block->generation != (uint32_t)atomic_get(&generation);
        bool expired = (uint32_t)(k_uptime_get_32() - block->captured_ms) >= 250U;
        if (stale || expired) {
            if (expired && !stale) { metric_inc(TM_EXPIRED); }
            discard_audio(block, offset); block = NULL;
            continue;
        }
        struct bt_conn *conn = connection_ref();
        if (!conn) {
            discard_audio(block, offset); block = NULL;
            continue;
        }
        size_t size = MIN(block->payload, KS_BLOCK_BYTES - offset);
        ks_put32(block->first_seq + offset / block->payload, packet);
        packet[4] = 0;
        memcpy(packet + KS_HEADER_BYTES, block->pcm + offset, size);
        struct bt_gatt_notify_params params = {
            .attr = &keepsake_service.attrs[2], .data = packet,
            .len = KS_HEADER_BYTES + size, .func = notify_complete,
            .user_data = (void *)(uintptr_t)block->generation,
        };
        retained_trace.sender_phase = SENDER_NOTIFY;
        uint32_t started = k_cycle_get_32();
        int err = bt_gatt_notify_cb(conn, &params);
        uint32_t elapsed = k_cyc_to_us_floor32(k_cycle_get_32() - started);
        if (elapsed > (uint32_t)atomic_get(&retained_trace.transport[TM_MAX_NOTIFY_US])) {
            atomic_set(&retained_trace.transport[TM_MAX_NOTIFY_US], elapsed);
        }
        bt_conn_unref(conn);
        if (err) {
            atomic_set(&retained_trace.transport[TM_LAST_ERROR], err);
            if (err == -ENOMEM || err == -EAGAIN || err == -ENOBUFS) {
                metric_inc(TM_BUSY);
                backpressure = true;
                break;
            }
            discard_audio(block, offset); block = NULL;
            continue;
        }
        metric_inc(TM_SUBMITTED);
        offset += size;
        if (offset == KS_BLOCK_BYTES) { release_audio(block); block = NULL; }
    }
    retained_trace.sender_phase = SENDER_IDLE;
    if (block || k_msgq_num_used_get(&audio_queue)) {
        k_work_schedule(&audio_tx, K_MSEC(backpressure ? 2 : 1));
    }
}
static void mic_stop(void)
{
    (void)dmic_trigger(mic, DMIC_TRIGGER_STOP);
    /* nrfx STOP is asynchronous; wait for DMA release before draining/restarting. */
    k_sleep(K_MSEC(120));
    void *buffer;
    uint32_t size;
    while (!dmic_read(mic, 0, &buffer, &size, 0)) { k_mem_slab_free(&mic_slab, buffer); }
    nrf_gpio_pin_clear(MIC_PWR_PIN);
    struct audio_block *queued;
    while (!k_msgq_get(&audio_queue, &queued, K_NO_WAIT)) { discard_audio(queued, 0); }
    /* The worker owns its current block and releases it on generation mismatch. */
    k_work_schedule(&audio_tx, K_NO_WAIT);
}
static int mic_start(void)
{
    nrf_gpio_pin_set(MIC_PWR_PIN);
    k_sleep(K_MSEC(50));
    return dmic_trigger(mic, DMIC_TRIGGER_START);
}
static void watchdog_init(void)
{
    if (!device_is_ready(watchdog)) { restart("watchdog unavailable"); }
    struct wdt_timeout_cfg cfg = {
        .window = { .min = 0, .max = WATCHDOG_TIMEOUT_MS },
        .flags = WDT_FLAG_RESET_SOC,
        .callback = NULL,
    };
    watchdog_channel = wdt_install_timeout(watchdog, &cfg);
    if (watchdog_channel < 0) { restart("watchdog channel setup failed"); }
    if (wdt_setup(watchdog, WDT_OPT_PAUSE_HALTED_BY_DBG)) { restart("watchdog setup failed"); }
    atomic_set(&watchdog_ready, 1);
}
int main(void)
{
    reset_reason = nrf_power_resetreas_get(NRF_POWER);
    nrf_power_resetreas_clear(NRF_POWER, reset_reason);
    trace_boot();
    nrf_gpio_cfg_output(MIC_PWR_PIN); nrf_gpio_pin_clear(MIC_PWR_PIN);
    nrf_gpio_cfg_output(IMU_PWR_PIN); nrf_gpio_pin_clear(IMU_PWR_PIN);
    /* Seeed warns against driving P0.14 high while charging. */
    nrf_gpio_cfg_output(BATTERY_SENSE_ENABLE_PIN);
    nrf_gpio_pin_clear(BATTERY_SENSE_ENABLE_PIN);
    nrf_gpio_cfg_input(CHARGE_STATUS_PIN, NRF_GPIO_PIN_NOPULL);
    battery_adc_ready = adc_is_ready_dt(&battery_adc) && !adc_channel_setup_dt(&battery_adc);
    watchdog_init();
    if (!device_is_ready(mic)) { restart("microphone unavailable"); }
    struct pcm_stream_cfg stream = {
        .pcm_rate = KS_RATE, .pcm_width = 16, .block_size = KS_BLOCK_BYTES, .mem_slab = &mic_slab,
    };
    struct dmic_cfg cfg = {
        .io = { .min_pdm_clk_freq = 1000000, .max_pdm_clk_freq = 3500000,
                .min_pdm_clk_dc = 40, .max_pdm_clk_dc = 60 },
        .streams = &stream, .channel = { .req_num_streams = 1, .req_num_chan = 1 },
    };
    cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
    if (dmic_configure(mic, &cfg)) { restart("microphone configuration failed"); }
    nrf_pdm_gain_set(NRF_PDM0, 40, 40); /* 0 dB hardware gain. */
    ks_stream_info(stream_info, sys_rand32_get());
    k_work_queue_start(&supervision_queue, supervision_stack,
                       K_THREAD_STACK_SIZEOF(supervision_stack), K_PRIO_PREEMPT(8), NULL);
    if (bt_enable(NULL)) { restart("Bluetooth initialization failed"); }
    atomic_set(&disconnected_at, k_uptime_get_32());
    atomic_set(&last_supervision_ms, k_uptime_get_32());
    k_work_reschedule_for_queue(&supervision_queue, &supervision, K_NO_WAIT);
    bool active = false;
    uint32_t active_generation = 0, sequence = 0;
    unsigned failures = 0, restart_attempts = 0, healthy_blocks = 0;
    while (true) {
        check_recovery_progress();
        feed_watchdog();
        trace_main(PHASE_CHECK);
        uint32_t gen = atomic_get(&generation);
        if (active && (!atomic_get(&subscribed) || gen != active_generation)) {
            trace_main(PHASE_MIC_STOP);
            mic_stop(); active = false;
        }
        if (!atomic_get(&subscribed)) {
            failures = restart_attempts = healthy_blocks = 0;
            trace_main(PHASE_IDLE);
            k_sem_take(&capture_wake, K_MSEC(500)); continue;
        }
        if (!active) {
            trace_main(PHASE_MIC_START);
            if (mic_start()) {
                trace_main(PHASE_MIC_STOP);
                mic_stop(); atomic_inc(&mic_restarts);
                if (++restart_attempts >= 3) { restart("microphone start failed repeatedly"); }
                k_sleep(K_MSEC(200)); continue;
            }
            active = true; active_generation = gen;
        }
        void *buffer;
        uint32_t size;
        trace_main(PHASE_READ);
        if (dmic_read(mic, 0, &buffer, &size, 500)) {
            metric_inc(TM_MIC_ERRORS);
            if (++failures >= 3) {
                trace_main(PHASE_MIC_STOP);
                mic_stop(); active = false; failures = 0; healthy_blocks = 0;
                atomic_inc(&mic_restarts);
                if (++restart_attempts >= 3) { restart("microphone repeatedly stalled"); }
            }
            continue;
        }
        failures = 0;
        metric_inc(TM_CAPTURED);
        atomic_set(&last_capture_ms, k_uptime_get_32());
        if (++healthy_blocks >= 100) { restart_attempts = 0; healthy_blocks = 100; }
        trace_main(PHASE_LINK);
        struct bt_conn *conn = connection_ref();
        size_t payload = conn ? ks_payload(bt_gatt_get_mtu(conn)) : 0;
        if (conn) { bt_conn_unref(conn); }
        if (payload && size == KS_BLOCK_BYTES && atomic_get(&subscribed) &&
            active_generation == (uint32_t)atomic_get(&generation)) {
            trace_main(PHASE_QUEUE);
            uint32_t first_seq = sequence;
            sequence += ks_packet_count(size, payload); /* reserve even for dropped blocks */
            struct audio_block *block;
            if (k_mem_slab_alloc(&audio_pool, (void **)&block, K_NO_WAIT)) {
                atomic_inc(&queue_drops); metric_inc(TM_QUEUE_DROPS);
            } else {
                block->first_seq = first_seq;
                block->payload = payload;
                block->generation = active_generation;
                block->captured_ms = k_uptime_get_32();
                memcpy(block->pcm, buffer, size);
                if (k_msgq_put(&audio_queue, &block, K_NO_WAIT)) {
                    atomic_inc(&queue_drops); metric_inc(TM_QUEUE_DROPS);
                    release_audio(block);
                } else {
                    record_queue();
                    k_work_schedule(&audio_tx, K_NO_WAIT);
                }
            }
        }
        trace_main(PHASE_FREE);
        k_mem_slab_free(&mic_slab, buffer);
    }
}
