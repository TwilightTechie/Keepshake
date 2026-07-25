/* Keepsake P0 bench firmware — XIAO nRF52840 Sense.
 *
 * PDM mic @16 kHz mono -> 8 kHz decimation -> continuous BLE GATT notifications
 * while a client is subscribed. PCM16 on the bench (Opus is P1, FW-2); every
 * notification carries a monotonic sequence number so the gateway/backend
 * inherit the zero-loss contract's framing (FW-3). Flash journal (FW-4) is P1.
 *
 * Segmentation lives in the GATEWAY, not here (bench lesson): on-device VAD
 * gating meant one misjudged threshold produced total silence with no way to
 * see why, and every tuning attempt cost a reflash. The pendant is a dumb
 * reliable pipe; utterance decisions happen where they are observable and
 * tunable. On-device VAD returns in P1 for battery (FW-2a), once the journal
 * (D6) guarantees nothing is lost when it misjudges.
 *
 * Frame: [seq:u32 LE][flags:u8][pcm bytes]   flags reserved (0)
 */

#include <hal/nrf_gpio.h>
#include <hal/nrf_pdm.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(keepsake, LOG_LEVEL_INF);

#define SAMPLE_RATE_HZ   16000
#define BLOCK_MS         100
#define BLOCK_SAMPLES    (SAMPLE_RATE_HZ * BLOCK_MS / 1000)
#define BLOCK_BYTES      (BLOCK_SAMPLES * sizeof(int16_t))
#define BLOCK_COUNT      10

/* Hardware PDM gain, set directly on the peripheral after dmic_configure
 * (Zephyr's dmic driver doesn't expose it). 40 = 0 dB, 64 = +12 dB — the
 * value Omi ships on this same board. Digital shift kept as headroom knob. */
#define PDM_HW_GAIN        64
#define DIGITAL_GAIN_SHIFT 0

/* The XIAO Sense mic's power rail hangs off P1.10 — it must be driven high or
 * the PDM bus reads pure noise floor (Omi does the same on this board). */
#define MIC_PWR_PIN NRF_GPIO_PIN_MAP(1, 10)

/* Energy is logged for calibration only — nothing gates on it here. */
#define ENERGY_LOG_EVERY 30  /* blocks: one log line per 3 s */

/* Ship 8 kHz over BLE (pair-averaged 2:1 decimation): PCM16@16k saturates
 * the link (~40% drops on the bench). Opus in P1 removes this entirely. */
#define DECIMATE         2
#define OUT_SAMPLES      (BLOCK_SAMPLES / DECIMATE)
#define OUT_BYTES        (OUT_SAMPLES * sizeof(int16_t))

#define CHUNK_BYTES      232 /* + 5B header fits a 247-byte MTU notification */

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_BYTES, BLOCK_COUNT, 4);

/* Custom 128-bit service: "keepsake-pendant" byte theme, char = audio stream */
#define KEEPSAKE_SVC_UUID  BT_UUID_128_ENCODE(0x6b656570, 0x7361, 0x6b65, 0x0001, 0x000000000001ULL)
#define KEEPSAKE_AUD_UUID  BT_UUID_128_ENCODE(0x6b656570, 0x7361, 0x6b65, 0x0001, 0x000000000002ULL)

static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(KEEPSAKE_SVC_UUID);
static const struct bt_uuid_128 aud_uuid = BT_UUID_INIT_128(KEEPSAKE_AUD_UUID);

static volatile bool notify_enabled;
static uint32_t seq;

static void ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	notify_enabled = (value == BT_GATT_CCC_NOTIFY);
	LOG_INF("audio notifications %s", notify_enabled ? "on" : "off");
}

BT_GATT_SERVICE_DEFINE(keepsake_svc,
	BT_GATT_PRIMARY_SERVICE((void *)&svc_uuid),
	BT_GATT_CHARACTERISTIC(&aud_uuid.uuid, BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME,
		sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};
static const struct bt_data sd[] = {
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, KEEPSAKE_SVC_UUID),
};

static struct bt_conn *current_conn;

static void send_chunk(const uint8_t *data, size_t len, bool utter_end)
{
	uint8_t buf[5 + CHUNK_BYTES];

	sys_put_le32(seq, buf);
	buf[4] = utter_end ? 1 : 0;
	memcpy(&buf[5], data, len);

	/* Bench policy: if buffers are exhausted, retry briefly then drop.
	 * The P1 journal turns drops into delta-sync instead (FW-4). */
	for (int attempt = 0; attempt < 3; attempt++) {
		int err = bt_gatt_notify(NULL, &keepsake_svc.attrs[1], buf, 5 + len);

		if (err != -ENOMEM) {
			if (err && err != -ENOTCONN) {
				LOG_WRN("notify err %d (seq %u)", err, seq);
			}
			break;
		}
		k_sleep(K_MSEC(5));
	}
	seq++;
}

static void send_block(const int16_t *samples, bool utter_end)
{
	static int16_t out[OUT_SAMPLES];

	for (size_t i = 0; i < OUT_SAMPLES; i++) {
		out[i] = (int16_t)(((int32_t)samples[2 * i] + samples[2 * i + 1]) / 2);
	}

	const uint8_t *bytes = (const uint8_t *)out;
	size_t remaining = OUT_BYTES;
	/* Size to the negotiated MTU, not a hardcoded guess: a notification
	 * larger than (MTU - 3) is rejected outright, and phones negotiate
	 * smaller MTUs than macOS. 3 = ATT notify header, 5 = our own header. */
	size_t payload = CHUNK_BYTES;

	if (current_conn) {
		uint16_t mtu = bt_gatt_get_mtu(current_conn);

		if (mtu > 3 + 5) {
			payload = MIN((size_t)(mtu - 3 - 5), (size_t)CHUNK_BYTES);
		}
	}

	while (remaining > 0) {
		size_t n = MIN(remaining, payload);
		bool last = (remaining <= payload);

		send_chunk(bytes, n, utter_end && last);
		bytes += n;
		remaining -= n;
	}
}

static uint32_t block_energy(const int16_t *samples)
{
	int64_t sum = 0;
	uint64_t acc = 0;

	for (size_t i = 0; i < BLOCK_SAMPLES; i++) {
		sum += samples[i];
	}
	int32_t mean = (int32_t)(sum / BLOCK_SAMPLES);

	for (size_t i = 0; i < BLOCK_SAMPLES; i++) {
		int32_t d = samples[i] - mean;

		acc += (d < 0) ? -d : d;
	}
	return (uint32_t)(acc / BLOCK_SAMPLES);
}

static void apply_gain(int16_t *samples)
{
	for (size_t i = 0; i < BLOCK_SAMPLES; i++) {
		int32_t v = (int32_t)samples[i] << DIGITAL_GAIN_SHIFT;

		samples[i] = (int16_t)CLAMP(v, INT16_MIN, INT16_MAX);
	}
}

/* Capture → sender handoff. 8 blocks of headroom decouples BLE stalls from
 * the PDM driver, which starves (and wedges) if reads fall behind. */
K_MSGQ_DEFINE(audio_q, BLOCK_BYTES, 8, 4);
static uint32_t dropped_blocks;

static void sender_fn(void *a, void *b, void *c)
{
	static int16_t block[BLOCK_SAMPLES];
	uint32_t dbg_count = 0;

	while (true) {
		k_msgq_get(&audio_q, block, K_FOREVER);

		if (++dbg_count % ENERGY_LOG_EVERY == 0) {
			LOG_INF("mic energy %u (notify %d, seq %u, dropped %u)",
				block_energy(block), notify_enabled, seq, dropped_blocks);
		}

		/* Stream unconditionally while a client is subscribed; silence
		 * costs radio but never costs us an utterance. Nothing is sent
		 * when unsubscribed, so idle battery is unaffected. */
		if (notify_enabled) {
			send_block(block, false);
		}
	}
}

K_THREAD_DEFINE(sender_tid, 4096, sender_fn, NULL, NULL, NULL, 7, 0, 0);

static void connected_cb(struct bt_conn *conn, uint8_t err)
{
	LOG_INF("connected (err %u)", err);
	if (err == 0) {
		current_conn = bt_conn_ref(conn);
		/* 15 ms interval, no latency: audio needs the airtime */
		bt_conn_le_param_update(conn, BT_LE_CONN_PARAM(12, 12, 0, 400));
	}
}

static void disconnected_cb(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("disconnected (reason %u)", reason);
	notify_enabled = false;
	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}
}

BT_CONN_CB_DEFINE(conn_cbs) = {
	.connected = connected_cb,
	.disconnected = disconnected_cb,
};

int main(void)
{
	const struct device *dmic_dev = DEVICE_DT_GET(DT_NODELABEL(pdm0));
	int err;

	if (!device_is_ready(dmic_dev)) {
		LOG_ERR("PDM mic not ready");
		return -ENODEV;
	}

	/* Mic power on. This is the future hard-mute point: PR-1's "mic power
	 * rail down" maps to clearing this pin. */
	nrf_gpio_cfg_output(MIC_PWR_PIN);
	nrf_gpio_pin_set(MIC_PWR_PIN);
	k_sleep(K_MSEC(50)); /* mic settle */

	struct pcm_stream_cfg stream = {
		.pcm_rate = SAMPLE_RATE_HZ,
		.pcm_width = 16,
		.block_size = BLOCK_BYTES,
		.mem_slab = &mem_slab,
	};
	struct dmic_cfg cfg = {
		.io = {
			.min_pdm_clk_freq = 1000000,
			.max_pdm_clk_freq = 3500000,
			.min_pdm_clk_dc = 40,
			.max_pdm_clk_dc = 60,
		},
		.streams = &stream,
		.channel = {
			.req_num_streams = 1,
			.req_num_chan = 1,
		},
	};

	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);

	err = dmic_configure(dmic_dev, &cfg);
	if (err) {
		LOG_ERR("dmic_configure: %d", err);
		return err;
	}
	nrf_pdm_gain_set(NRF_PDM0, PDM_HW_GAIN, PDM_HW_GAIN);

	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("bt_enable: %d", err);
		return err;
	}

	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
	if (err) {
		LOG_ERR("adv start: %d", err);
		return err;
	}
	LOG_INF("advertising as %s", CONFIG_BT_DEVICE_NAME);

	err = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
	if (err) {
		LOG_ERR("dmic start: %d", err);
		return err;
	}

	/* Capture loop: service the PDM driver at line rate, never block on BLE.
	 * Blocks are copied into audio_q for the sender thread; if the queue is
	 * full the block is dropped (bench policy — the P1 journal replaces
	 * drops with delta sync, FW-4). */
	int consec_fail = 0;

	while (true) {
		void *buffer;
		uint32_t size;

		err = dmic_read(dmic_dev, 0, &buffer, &size, 1000);
		if (err) {
			LOG_WRN("dmic_read: %d", err);
			if (++consec_fail >= 5) {
				LOG_WRN("restarting PDM after %d failures", consec_fail);
				dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
				k_sleep(K_MSEC(20));
				dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
				consec_fail = 0;
			}
			continue;
		}
		consec_fail = 0;

		apply_gain(buffer);
		if (k_msgq_put(&audio_q, buffer, K_NO_WAIT) != 0) {
			dropped_blocks++;
		}
		k_mem_slab_free(&mem_slab, buffer);
	}
	return 0;
}
