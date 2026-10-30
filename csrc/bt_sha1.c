#include "bt_sha1.h"
#include "bt_common.h"
#include <CommonCrypto/CommonDigest.h>

void bt_sha1(const void *data, size_t len, uint8_t out[20]) {
    CC_SHA1(data, (CC_LONG)len, out);
}

void bt_sha1_hex(const void *data, size_t len, char *out) {
    uint8_t d[20];
    bt_sha1(data, len, d);
    bt_to_hex(d, 20, out);
}
