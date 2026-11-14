// Minimal AppleSMC user-client. Reads are unprivileged.

#include "CThermacPrivate.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

typedef struct {
    char major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t      key;
    SMCVersion    vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo    keyInfo;
    uint8_t       result;
    uint8_t       status;
    uint8_t       data8;
    uint32_t      data32;
    uint8_t       bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData must be 80 bytes");

static int smc_call(uint32_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent,
                                                 in, sizeof(SMCKeyData), out, &outSize);
    if (kr != KERN_SUCCESS) return (int)kr;
    return out->result == 0 ? 0 : 0x1000 + out->result;
}

int tm_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return (int)kr;
    *connection = conn;
    return 0;
}

void tm_smc_close(uint32_t connection) {
    IOServiceClose(connection);
}

int tm_smc_read(uint32_t conn, uint32_t key, tm_smc_value *out) {
    SMCKeyData in, res;
    memset(&in, 0, sizeof in);
    memset(&res, 0, sizeof res);

    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    int rc = smc_call(conn, &in, &res);
    if (rc) return rc;

    return tm_smc_read_known(conn, key, res.keyInfo.dataSize, res.keyInfo.dataType, out);
}

int tm_smc_read_known(uint32_t conn, uint32_t key, uint32_t size, uint32_t type, tm_smc_value *out) {
    SMCKeyData in, res;
    if (size > sizeof(out->bytes)) size = sizeof(out->bytes);
    memset(&in, 0, sizeof in);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = kSMCReadKey;
    memset(&res, 0, sizeof res);
    int rc = smc_call(conn, &in, &res);
    if (rc) return rc;

    out->key = key;
    out->dataType = type;
    out->dataSize = size;
    memcpy(out->bytes, res.bytes, sizeof(out->bytes));
    return 0;
}

int tm_smc_key_at_index(uint32_t conn, uint32_t index, uint32_t *key) {
    SMCKeyData in, res;
    memset(&in, 0, sizeof in);
    memset(&res, 0, sizeof res);
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    int rc = smc_call(conn, &in, &res);
    if (rc) return rc;
    *key = res.key;
    return 0;
}
