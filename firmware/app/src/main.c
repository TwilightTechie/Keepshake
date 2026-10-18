/* Keepsake raw gateway firmware, XIAO nRF52840 Sense.
 * Native PCM16/16 kHz; no VAD, gain processing, resampling, or codec.
 * Packet contract: [u32 LE sequence][u8 flags=0][PCM bytes].
 */
#include <hal/nrf_gpio.h>
#include <hal/nrf_pdm.h>
#include <hal/nrf_power.h>
#include <zephyr/audio/dmic.h>
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

LOG_MODULE_REGISTER(keepsake, LOG_LEVEL_INF);
#define MIC_PWR_PIN NRF_GPIO_PIN_MAP(1, 10)
#define IMU_PWR_PIN NRF_GPIO_PIN_MAP(1, 8)
#define UUID(n) BT_UUID_128_ENCODE(0x6b656570, 0x7361, 0x6b65, 0x0001, ((uint64_t)(n)))
static const struct bt_uuid_128 service_uuid = BT_UUID_INIT_128(UUID(1));
static const struct bt_uuid_128 audio_uuid = BT_UUID_INIT_128(UUID(2));
static const struct bt_uuid_128 info_uuid = BT_UUID_INIT_128(UUID(3));
static const struct bt_uuid_128 status_uuid = BT_UUID_INIT_128(UUID(4));
static const struct device *const mic = DEVICE_DT_GET(DT_NODELABEL(pdm0));
static const struct device *const watchdog = DEVICE_DT_GET(DT_ALIAS(watchdog0));
K_MEM_SLAB_DEFINE_STATIC(mic_slab, KS_BLOCK_BYTES, 10, 4);
K_SEM_DEFINE(capture_wake, 0, 1);
static atomic_t subscribed, generation, connected, watchdog_ready;
static atomic_t queue_drops, tx_drops, mic_restarts, last_tx_ms, last_capture_ms;
static uint8_t stream_info[KS_INFO_BYTES];
static uint32_t reset_reason;
static struct bt_conn *connection;
static struct k_spinlock connection_lock;
static int watchdog_channels[3]; /* capture loop, sender loop, system work queue */
static atomic_t disconnected_at;
struct audio_block {
    uint32_t generation;
    uint32_t first_seq;
    uint16_t payload;
    uint8_t pcm[KS_BLOCK_BYTES];
};
K_MSGQ_DEFINE(audio_queue, sizeof(struct audio_block), 8, 4);

static void feed(unsigned channel)
{
    if (atomic_get(&watchdog_ready)) { (void)wdt_feed(watchdog, watchdog_channels[channel]); }
}
static void restart(const char *reason)
{
    LOG_ERR("Recovery reset: %s", reason);
    ARG_UNUSED(reason);
    nrf_gpio_pin_clear(MIC_PWR_PIN);
    sys_reboot(SYS_REBOOT_COLD);
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
BT_GATT_SERVICE_DEFINE(keepsake_service,
    BT_GATT_PRIMARY_SERVICE(&service_uuid),
    BT_GATT_CHARACTERISTIC(&audio_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE,
                           NULL, NULL, NULL),
    BT_GATT_CCC(ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    BT_GATT_CHARACTERISTIC(&info_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_info, NULL, NULL),
    BT_GATT_CHARACTERISTIC(&status_uuid.uuid, BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
                           read_status, NULL, NULL)
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
static void supervise(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(supervision, supervise);
static void supervise(struct k_work *work)
{
    ARG_UNUSED(work);
    feed(2);
    uint32_t now = k_uptime_get_32();
    if (atomic_get(&connected)) {
        atomic_clear(&advertising);
        adv_failed = false;
        if (atomic_get(&subscribed) && (uint32_t)(now - atomic_get(&last_tx_ms)) > 5000U &&
            (uint32_t)(now - atomic_get(&last_capture_ms)) < 1500U) {
            struct bt_conn *conn = connection_ref();
            if (conn) {
                (void)bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
                bt_conn_unref(conn);
            }
        }
    } else {
        bool slow = (uint32_t)(now - atomic_get(&disconnected_at)) >= 30000U;
        if (atomic_get(&advertising) && slow != advertising_slow) {
            int err = bt_le_adv_stop();
            if (!err || err == -EALREADY) { atomic_clear(&advertising); }
        }
        if (!atomic_get(&advertising)) {
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
    k_work_reschedule(&supervision, K_SECONDS(1));
}
static void on_connected(struct bt_conn *conn, uint8_t err)
{
    atomic_clear(&advertising);
    if (err) { return; }
    k_spinlock_key_t key = k_spin_lock(&connection_lock);
    connection = bt_conn_ref(conn);
    k_spin_unlock(&connection_lock, key);
    atomic_set(&connected, 1);
    LOG_INF("Phone connected");
    atomic_clear(&subscribed);
    atomic_inc(&generation);
    (void)bt_conn_le_param_update(conn, BT_LE_CONN_PARAM(12, 12, 0, 400));
}
static void on_disconnected(struct bt_conn *conn, uint8_t reason)
{
    ARG_UNUSED(conn);
    LOG_INF("Phone disconnected: %u", reason);
    ARG_UNUSED(reason);
    atomic_clear(&subscribed);
    atomic_inc(&generation);
    k_spinlock_key_t key = k_spin_lock(&connection_lock);
    struct bt_conn *old = connection;
    connection = NULL;
    k_spin_unlock(&connection_lock, key);
    atomic_set(&disconnected_at, k_uptime_get_32());
    atomic_clear(&connected);
    if (old) { bt_conn_unref(old); }
    k_sem_give(&capture_wake);
}
static void on_recycled(void)
{
    k_work_reschedule(&supervision, K_NO_WAIT);
}
BT_CONN_CB_DEFINE(connection_callbacks) = {
    .connected = on_connected, .disconnected = on_disconnected, .recycled = on_recycled,
};
static void sender(void *a, void *b, void *c)
{
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
    static struct audio_block block;
    uint8_t packet[KS_HEADER_BYTES + KS_MAX_PAYLOAD];
    while (true) {
        feed(1);
        if (k_msgq_get(&audio_queue, &block, K_MSEC(500))) { continue; }
        struct bt_conn *conn = connection_ref();
        if (!conn) { continue; }
        uint32_t seq = block.first_seq;
        uint32_t deadline = k_uptime_get_32() + 150U;
        for (size_t offset = 0; offset < KS_BLOCK_BYTES; offset += block.payload, ++seq) {
            if (!atomic_get(&subscribed) || block.generation != (uint32_t)atomic_get(&generation)) { break; }
            size_t size = MIN(block.payload, KS_BLOCK_BYTES - offset);
            ks_put32(seq, packet); packet[4] = 0;
            memcpy(packet + KS_HEADER_BYTES, block.pcm + offset, size);
            int err;
            do {
                err = bt_gatt_notify(conn, &keepsake_service.attrs[2], packet, KS_HEADER_BYTES + size);
                if (err != -ENOMEM && err != -EAGAIN) { break; }
                k_sleep(K_MSEC(2));
            } while ((int32_t)(deadline - k_uptime_get_32()) > 0 &&
                     atomic_get(&subscribed) && block.generation == (uint32_t)atomic_get(&generation));
            if (!err) { atomic_set(&last_tx_ms, k_uptime_get_32()); }
            else {
                atomic_add(&tx_drops, ks_packet_count(KS_BLOCK_BYTES - offset, block.payload));
                break;
            }
        }
        bt_conn_unref(conn);
    }
}
K_THREAD_DEFINE(sender_thread, 2048, sender, NULL, NULL, NULL, 7, 0, 0);
static void mic_stop(void)
{
    (void)dmic_trigger(mic, DMIC_TRIGGER_STOP);
    /* nrfx STOP is asynchronous; wait for DMA release before draining/restarting. */
    k_sleep(K_MSEC(120));
    void *buffer;
    uint32_t size;
    while (!dmic_read(mic, 0, &buffer, &size, 0)) { k_mem_slab_free(&mic_slab, buffer); }
    nrf_gpio_pin_clear(MIC_PWR_PIN);
    k_msgq_purge(&audio_queue);
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
        .window = { .min = 0, .max = 12000 }, .flags = WDT_FLAG_RESET_SOC,
    };
    for (unsigned i = 0; i < ARRAY_SIZE(watchdog_channels); ++i) {
        watchdog_channels[i] = wdt_install_timeout(watchdog, &cfg);
        if (watchdog_channels[i] < 0) { restart("watchdog channel setup failed"); }
    }
    if (wdt_setup(watchdog, WDT_OPT_PAUSE_HALTED_BY_DBG)) { restart("watchdog setup failed"); }
    atomic_set(&watchdog_ready, 1);
}
int main(void)
{
    nrf_gpio_cfg_output(MIC_PWR_PIN); nrf_gpio_pin_clear(MIC_PWR_PIN);
    nrf_gpio_cfg_output(IMU_PWR_PIN); nrf_gpio_pin_clear(IMU_PWR_PIN);
    reset_reason = nrf_power_resetreas_get(NRF_POWER);
    nrf_power_resetreas_clear(NRF_POWER, reset_reason);
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
    if (bt_enable(NULL)) { restart("Bluetooth initialization failed"); }
    atomic_set(&disconnected_at, k_uptime_get_32());
    k_work_reschedule(&supervision, K_NO_WAIT);
    bool active = false;
    uint32_t active_generation = 0, sequence = 0;
    unsigned failures = 0, restart_attempts = 0, healthy_blocks = 0;
    static struct audio_block block;
    while (true) {
        feed(0);
        uint32_t gen = atomic_get(&generation);
        if (active && (!atomic_get(&subscribed) || gen != active_generation)) {
            mic_stop(); active = false;
        }
        if (!atomic_get(&subscribed)) {
            failures = restart_attempts = healthy_blocks = 0;
            k_sem_take(&capture_wake, K_MSEC(500)); continue;
        }
        if (!active) {
            if (mic_start()) {
                mic_stop(); atomic_inc(&mic_restarts);
                if (++restart_attempts >= 3) { restart("microphone start failed repeatedly"); }
                k_sleep(K_MSEC(200)); continue;
            }
            active = true; active_generation = gen;
        }
        void *buffer;
        uint32_t size;
        if (dmic_read(mic, 0, &buffer, &size, 500)) {
            if (++failures >= 3) {
                mic_stop(); active = false; failures = 0; healthy_blocks = 0;
                atomic_inc(&mic_restarts);
                if (++restart_attempts >= 3) { restart("microphone repeatedly stalled"); }
            }
            continue;
        }
        failures = 0;
        atomic_set(&last_capture_ms, k_uptime_get_32());
        if (++healthy_blocks >= 100) { restart_attempts = 0; healthy_blocks = 100; }
        struct bt_conn *conn = connection_ref();
        size_t payload = conn ? ks_payload(bt_gatt_get_mtu(conn)) : 0;
        if (conn) { bt_conn_unref(conn); }
        if (payload && size == KS_BLOCK_BYTES && atomic_get(&subscribed) &&
            active_generation == (uint32_t)atomic_get(&generation)) {
            block.first_seq = sequence; block.payload = payload; block.generation = active_generation;
            sequence += ks_packet_count(size, payload); /* reserve before enqueue, including drops */
            memcpy(block.pcm, buffer, size);
            if (k_msgq_put(&audio_queue, &block, K_NO_WAIT)) { atomic_inc(&queue_drops); }
        }
        k_mem_slab_free(&mic_slab, buffer);
    }
}
