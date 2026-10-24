#include <assert.h>
#include <stdio.h>
#include "../app/src/recovery.h"

int main(void)
{
    /* Normal capture and unlimited standby must not trigger TX recovery. */
    assert(ks_recovery_due(100000, 99900, 99990, true) == KS_RECOVERY_NONE);
    assert(ks_recovery_due(100000, 99900, 0, false) == KS_RECOVERY_NONE);
    /* Healthy capture/supervision cannot hide a blocked sender indefinitely. */
    assert(ks_recovery_due(15000, 14900, 0, true) == KS_RECOVERY_NONE);
    assert(ks_recovery_due(15001, 14900, 0, true) == KS_RECOVERY_TX);
    /* A blocked supervisor must recover even in standby. */
    assert(ks_recovery_due(20000, 0, 19999, false) == KS_RECOVERY_NONE);
    assert(ks_recovery_due(20001, 0, 20000, false) == KS_RECOVERY_SUPERVISOR);
    /* Real uptime wrap still observes the deadline. */
    assert(ks_recovery_due(10000, 9999, UINT32_MAX - 6000, true) == KS_RECOVERY_TX);
    assert(ks_recovery_due(10000, UINT32_MAX - 11000, 9999, false) == KS_RECOVERY_SUPERVISOR);
    /* A timestamp updated after the caller sampled now is fresh, not 49 days old. */
    assert(ks_recovery_due(10000, 10001, 10001, true) == KS_RECOVERY_NONE);
    assert(ks_recovery_due(UINT32_MAX, 0, 0, true) == KS_RECOVERY_NONE);
    puts("PASS: recovery deadlines, standby, clock wrap, concurrent timestamp updates");
}
