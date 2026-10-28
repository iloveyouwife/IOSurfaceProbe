#include "RemoteAfcProbe.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

// Narrow declarations for the pinned idevice-ffi symbols already included
// in AirliftFFI.a. These types are opaque; no private iOS API is invoked.
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct AdapterHandle AdapterHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;
typedef struct HouseArrestClientHandle HouseArrestClientHandle;
typedef struct AfcClientHandle AfcClientHandle;
typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

extern IdeviceFfiError *rp_pairing_file_read(const char *, RpPairingFileHandle **);
extern void rp_pairing_file_free(RpPairingFileHandle *);
extern IdeviceFfiError *tunnel_create_rppairing(const struct sockaddr *, socklen_t,
                                                const char *, RpPairingFileHandle *,
                                                const char *(*)(void *), void *,
                                                AdapterHandle **, RsdHandshakeHandle **);
extern IdeviceFfiError *tunnel_create_remotexpc(const struct sockaddr *, socklen_t,
                                                const char *, RpPairingFileHandle *,
                                                const char *(*)(void *), void *,
                                                AdapterHandle **, RsdHandshakeHandle **);
extern IdeviceFfiError *house_arrest_client_connect_rsd(AdapterHandle *,
                                                          RsdHandshakeHandle *,
                                                          HouseArrestClientHandle **);
// This consumes the HouseArrestClientHandle on both success and failure.
extern IdeviceFfiError *house_arrest_vend_container(HouseArrestClientHandle *,
                                                    const char *, AfcClientHandle **);
extern IdeviceFfiError *afc_list_directory(AfcClientHandle *, const char *,
                                           char ***, size_t *);
extern void afc_client_free(AfcClientHandle *);
extern void adapter_free(AdapterHandle *);
extern void rsd_handshake_free(RsdHandshakeHandle *);
extern void idevice_error_free(IdeviceFfiError *);

static void cg_error(char *out, size_t cap, const char *stage, IdeviceFfiError *error) {
    snprintf(out, cap, "%s：%s (code=%d, sub=%d)", stage,
             error && error->message ? error->message : "未知设备错误",
             error ? error->code : -1, error ? error->sub_code : -1);
    if (error) idevice_error_free(error);
}

static bool cg_valid_bundle_id(const char *value) {
    if (!value) return false;
    size_t len = strlen(value);
    if (len < 5 || len > 180 || !strchr(value, '.')) return false;
    for (size_t i = 0; i < len; i++) {
        char c = value[i];
        bool okay = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '.' || c == '-';
        if (!okay) return false;
    }
    return true;
}

int32_t cg_probe_house_arrest(const char *target_ipv4,
                              const char *pairing_path,
                              const char *bundle_id,
                              char *message, size_t message_size) {
    if (!message || message_size < 80) return 1;
    message[0] = 0;
    if (!target_ipv4 || !pairing_path || !cg_valid_bundle_id(bundle_id)) {
        snprintf(message, message_size, "目标 IP、配对文件或 Bundle ID 不合法");
        return 1;
    }
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(49152);
    if (inet_pton(AF_INET, target_ipv4, &address.sin_addr) != 1) {
        snprintf(message, message_size, "需要 LocalDevVPN 的 IPv4 地址");
        return 1;
    }

    RpPairingFileHandle *pairing = NULL;
    IdeviceFfiError *error = rp_pairing_file_read(pairing_path, &pairing);
    if (error) {
        cg_error(message, message_size, "读取 RPPairing 凭据失败", error);
        return 1;
    }

    AdapterHandle *adapter = NULL;
    RsdHandshakeHandle *handshake = NULL;
    error = tunnel_create_rppairing((const struct sockaddr *)&address,
                                    (socklen_t)sizeof(address), "CacheGuard",
                                    pairing, NULL, NULL, &adapter, &handshake);
    if (error) {
        idevice_error_free(error);
        error = tunnel_create_remotexpc((const struct sockaddr *)&address,
                                        (socklen_t)sizeof(address), "CacheGuard",
                                        pairing, NULL, NULL, &adapter, &handshake);
    }
    rp_pairing_file_free(pairing);
    if (error) {
        cg_error(message, message_size, "RSD 远程隧道连接失败", error);
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        return 1;
    }

    HouseArrestClientHandle *service = NULL;
    error = house_arrest_client_connect_rsd(adapter, handshake, &service);
    if (error) {
        cg_error(message, message_size, "HouseArrest 服务连接失败", error);
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        return 1;
    }

    AfcClientHandle *afc = NULL;
    error = house_arrest_vend_container(service, bundle_id, &afc);
    if (error) {
        cg_error(message, message_size, "VendContainer 授权失败", error);
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        return 1;
    }

    const char *roots[] = {"Library/Caches", "tmp"};
    size_t counts[2] = {0, 0};
    int32_t codes[2] = {0, 0};
    int permitted = 0;
    for (size_t i = 0; i < 2; ++i) {
        char **entries = NULL;
        size_t count = 0;
        error = afc_list_directory(afc, roots[i], &entries, &count);
        if (error) {
            codes[i] = error->code;
            idevice_error_free(error);
        } else {
            permitted++;
            counts[i] = count;
            // idevice-ffi allocates these with the system allocator; this call
            // receives names solely to free them. Names never leave this module.
            if (entries) {
                for (size_t j = 0; j < count; j++) free(entries[j]);
                free(entries);
            }
        }
    }
    afc_client_free(afc);
    if (handshake) rsd_handshake_free(handshake);
    if (adapter) adapter_free(adapter);
    snprintf(message, message_size,
             "HouseArrest 远程 AFC：可列举 %d/2，Caches=%zu 项（错误 %d），tmp=%zu 项（错误 %d）。仅统计目录，不读内容、不删除。",
             permitted, counts[0], codes[0], counts[1], codes[1]);
    return permitted > 0 ? 0 : 2;
}
