#include "bt_magnet.h"
#include "bt_common.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* 40 位 hex → 20 字节 */
static int decode_hex(const char *s, uint8_t out[20]) {
    for (int i = 0; i < 20; i++) {
        int hi = hexval(s[i * 2]);
        int lo = hexval(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return 0;
}

/* base32（RFC 3548，无 padding）解码：32 字符 → 20 字节 */
static int decode_base32(const char *s, uint8_t out[20]) {
    uint32_t acc = 0;
    int bits = 0, idx = 0;
    for (int i = 0; i < 32; i++) {
        char c = s[i];
        int v;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a';
        else if (c >= '2' && c <= '7') v = c - '2' + 26;
        else return -1;
        acc = (acc << 5) | (uint32_t)v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out[idx++] = (uint8_t)((acc >> bits) & 0xff);
        }
    }
    return idx == 20 ? 0 : -1;
}

/* URL 解码（%XX），'+' 也当作空格。返回 malloc 的字符串。 */
static char *url_decode(const char *s, size_t len) {
    char *r = (char *)malloc(len + 1);
    if (!r) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '%' && i + 2 < len) {
            int hi = hexval(s[i + 1]);
            int lo = hexval(s[i + 2]);
            if (hi >= 0 && lo >= 0) {
                r[o++] = (char)((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        if (s[i] == '+') r[o++] = ' ';
        else r[o++] = s[i];
    }
    r[o] = '\0';
    return r;
}

static void add_tracker(bt_magnet *m, const char *url) {
    if (!url || !*url) return;
    for (uint32_t i = 0; i < m->tracker_count; i++) {
        if (strcmp(m->trackers[i], url) == 0) return;
    }
    char **nl = (char **)realloc(m->trackers, sizeof(char *) * (m->tracker_count + 1));
    if (!nl) return;
    m->trackers = nl;
    m->trackers[m->tracker_count] = bt_strdup(url);
    if (m->trackers[m->tracker_count]) m->tracker_count++;
}

int bt_magnet_parse(const char *url, bt_magnet *out, char *err, size_t errlen) {
    memset(out, 0, sizeof(*out));
    if (!url || strncmp(url, "magnet:?", 8) != 0) {
        snprintf(err, errlen, "不是合法的 magnet 链接");
        return -1;
    }
    const char *q = url + 8;
    int got_hash = 0;

    while (q && *q) {
        const char *amp = strchr(q, '&');
        size_t seglen = amp ? (size_t)(amp - q) : strlen(q);
        const char *eq = NULL;
        for (size_t i = 0; i < seglen; i++) {
            if (q[i] == '=') { eq = q + i; break; }
        }
        if (eq) {
            size_t klen = (size_t)(eq - q);
            char *key = (char *)malloc(klen + 1);
            if (!key) break;
            memcpy(key, q, klen);
            key[klen] = '\0';
            char *val = url_decode(eq + 1, seglen - klen - 1);

            if (strcmp(key, "xt") == 0 && val) {
                if (strncmp(val, "urn:btih:", 9) == 0) {
                    char *h = val + 9;
                    size_t hl = strlen(h);
                    if (hl == 40 && decode_hex(h, out->info_hash) == 0) {
                        got_hash = 1;
                        bt_to_hex(out->info_hash, 20, out->info_hash_hex);
                    } else if (hl == 32 && decode_base32(h, out->info_hash) == 0) {
                        got_hash = 1;
                        bt_to_hex(out->info_hash, 20, out->info_hash_hex);
                    }
                }
            } else if (strcmp(key, "dn") == 0 && val) {
                if (!out->name) out->name = bt_strdup(val);
            } else if (strcmp(key, "tr") == 0 && val) {
                add_tracker(out, val);
            }
            free(key);
            free(val);
        }
        q = amp ? amp + 1 : NULL;
    }

    if (!got_hash) {
        snprintf(err, errlen, "magnet 缺少有效的 info hash（xt=urn:btih:...）");
        bt_magnet_free(out);
        return -1;
    }
    return 0;
}

void bt_magnet_free(bt_magnet *m) {
    if (!m) return;
    free(m->name); m->name = NULL;
    if (m->trackers) {
        for (uint32_t i = 0; i < m->tracker_count; i++) free(m->trackers[i]);
        free(m->trackers); m->trackers = NULL;
    }
    m->tracker_count = 0;
}
