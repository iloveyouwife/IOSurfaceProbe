#ifndef CACHEGUARD_REMOTE_AFC_PROBE_H
#define CACHEGUARD_REMOTE_AFC_PROBE_H

#include <stddef.h>
#include <stdint.h>

// Read-only diagnostic via device RSD -> HouseArrest -> AFC. No file bytes,
// file names, file writes or delete calls are exposed to Swift.
// Return 0 when at least one target cache scope is listable.
// Return 1 on transport/vend errors and 2 when both cache scopes are denied.
int32_t cg_probe_house_arrest(const char *target_ipv4,
                              const char *pairing_path,
                              const char *bundle_id,
                              char *message,
                              size_t message_size);

#endif
