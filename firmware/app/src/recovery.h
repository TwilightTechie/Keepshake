#ifndef KEEPSAKE_RECOVERY_H
#define KEEPSAKE_RECOVERY_H
#include <stdbool.h>
#include <stdint.h>

enum ks_recovery_action { KS_RECOVERY_NONE, KS_RECOVERY_TX, KS_RECOVERY_SUPERVISOR };

/* Called frequently; these deadlines are well below half the 32-bit clock
 * range. A concurrent timestamp newer than 'now' is fresh, not overdue.
 */
static inline enum ks_recovery_action ks_recovery_due(uint32_t now,
    uint32_t last_supervision, uint32_t last_tx, bool streaming)
{
    if ((int32_t)(now - last_supervision) > 20000) { return KS_RECOVERY_SUPERVISOR; }
    if (streaming && (int32_t)(now - last_tx) > 15000) { return KS_RECOVERY_TX; }
    return KS_RECOVERY_NONE;
}
#endif
