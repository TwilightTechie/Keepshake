/* Keepsake P0 bench firmware — XIAO nRF52840 Sense.
 *
 * PDM mic @16 kHz mono -> energy VAD with pre-roll -> BLE GATT notifications.
 * PCM16 on the bench (Opus is P1, FW-2); every notification carries a
 * monotonic sequence number so the gateway/backend inherit the zero-loss
 * contract's framing (FW-3). Flash journal (FW-4) is P1.
 *
 * Frame: [seq:u32 LE][flags:u8][pcm bytes]   flags bit0 = utterance end
 */

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

/* VAD: mean |amplitude| threshold (post-gain), ~1.5 s hangover, 500 ms
 * pre-roll (FW-2a). Calibrate against the periodic "mic energy" log line. */
#define VAD_THRESHOLD    150
#define VAD_HANGOVER     15  /* blocks */
#define PREROLL_BLOCKS   5   /* 500 ms */
#define ENERGY_LOG_EVERY 30  /* blocks: one calibration log line per 3 s */

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
	const uint8_t *bytes = (const uint8_t *)samples;
	size_t remaining = BLOCK_BYTES;

	while (remaining > 0) {
		size_t n = MIN(remaining, (size_t)CHUNK_BYTES);
		bool last = (remaining <= CHUNK_BYTES);

		send_chunk(bytes, n, utter_end && last);
		bytes += n;
		remaining -= n;
	}
}

static uint32_t block_energy(const int16_t *samples)
{
	uint64_t acc = 0;

	for (size_t i = 0; i < BLOCK_SAMPLES; i++) {
		acc += (samples[i] < 0) ? -samples[i] : samples[i];
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

/* 500 ms pre-roll ring so utterance starts are never clipped (FW-2a) */
static int16_t preroll[PREROLL_BLOCKS][BLOCK_SAMPLES];
static int preroll_head, preroll_fill;

static void preroll_push(const int16_t *samples)
{
	memcpy(preroll[preroll_head], samples, BLOCK_BYTES);
	preroll_head = (preroll_head + 1) % PREROLL_BLOCKS;
	if (preroll_fill < PREROLL_BLOCKS) {
		preroll_fill++;
	}
}

static void preroll_flush(void)
{
	int idx = (preroll_head - preroll_fill + PREROLL_BLOCKS) % PREROLL_BLOCKS;

	for (int i = 0; i < preroll_fill; i++) {
		send_block(preroll[idx], false);
		idx = (idx + 1) % PREROLL_BLOCKS;
	}
	preroll_fill = 0;
}

static void connected_cb(struct bt_conn *conn, uint8_t err)
{
	LOG_INF("connected (err %u)", err);
}

static void disconnected_cb(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("disconnected (reason %u)", reason);
	notify_enabled = false;
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

	int hangover = 0;
	bool in_utterance = false;

	while (true) {
		void *buffer;
		uint32_t size;

		err = dmic_read(dmic_dev, 0, &buffer, &size, 1000);
		if (err) {
			LOG_WRN("dmic_read: %d", err);
			continue;
		}

		int16_t *samples = buffer;
		static uint32_t dbg_count;

		apply_gain(samples);

		uint32_t energy = block_energy(samples);
		bool voiced = energy > VAD_THRESHOLD;

		if (++dbg_count % ENERGY_LOG_EVERY == 0) {
			LOG_INF("mic energy %u (vad threshold %d, notify %d)",
				energy, VAD_THRESHOLD, notify_enabled);
		}

		if (!notify_enabled) {
			preroll_push(samples);
			in_utterance = false;
			hangover = 0;
		} else if (voiced) {
			if (!in_utterance) {
				preroll_flush();
				in_utterance = true;
				LOG_INF("utterance start (seq %u)", seq);
			}
			hangover = VAD_HANGOVER;
			send_block(samples, false);
		} else if (in_utterance) {
			hangover--;
			if (hangover > 0) {
				send_block(samples, false);
			} else {
				send_block(samples, true); /* utterance end */
				in_utterance = false;
				LOG_INF("utterance end (seq %u)", seq);
			}
		} else {
			preroll_push(samples);
		}

		k_mem_slab_free(&mem_slab, buffer);
	}
	return 0;
}
