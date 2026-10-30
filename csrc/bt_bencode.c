#include "bt_bencode.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define MAX_DEPTH 64

static void be_free(bt_be_value *v);

static void zero_value(bt_be_value *v) {
    memset(v, 0, sizeof(*v));
}

/* ---------- 解码 ---------- */

static int parse_value(const uint8_t **pp, const uint8_t *end, bt_be_value *out, int depth) {
    if (depth > MAX_DEPTH) return -1;
    const uint8_t *p = *pp;
    if (p >= end) return -1;
    zero_value(out);
    out->raw = p;

    switch (*p) {
        case 'i': {
            p++;
            if (p >= end) return -1;
            int neg = 0;
            if (*p == '-') { neg = 1; p++; }
            if (p >= end || *p < '0' || *p > '9') return -1;
            int64_t n = 0;
            int overflow = 0;
            while (p < end && *p >= '0' && *p <= '9') {
                if (n > (INT64_MAX - (*p - '0')) / 10) overflow = 1;
                n = n * 10 + (*p - '0');
                p++;
            }
            if (p >= end || *p != 'e') return -1;
            (void)overflow;
            out->type = BT_BE_INT;
            out->as_int = neg ? -n : n;
            p++; /* 跳过 e */
            out->raw_len = (size_t)(p - out->raw);
            *pp = p;
            return 0;
        }
        case 'l': {
            p++;
            out->type = BT_BE_LIST;
            size_t cap = 0;
            while (p < end && *p != 'e') {
                bt_be_value *items = (bt_be_value *)realloc(out->as_list.items,
                                    sizeof(bt_be_value) * (out->as_list.count + 1));
                if (!items) { be_free(out); return -1; }
                out->as_list.items = items;
                bt_be_value tmp;
                if (parse_value(&p, end, &tmp, depth + 1) != 0) { be_free(out); return -1; }
                out->as_list.items[out->as_list.count++] = tmp;
                cap = out->as_list.count;
            }
            (void)cap;
            if (p >= end) { be_free(out); return -1; }
            p++; /* 跳过 e */
            out->raw_len = (size_t)(p - out->raw);
            *pp = p;
            return 0;
        }
        case 'd': {
            p++;
            out->type = BT_BE_DICT;
            while (p < end && *p != 'e') {
                bt_be_value k;
                if (parse_value(&p, end, &k, depth + 1) != 0) { be_free(out); return -1; }
                if (k.type != BT_BE_STR) { be_free(&k); be_free(out); return -1; }
                bt_be_value val;
                if (parse_value(&p, end, &val, depth + 1) != 0) { be_free(&k); be_free(out); return -1; }
                size_t n = out->as_dict.count;
                bt_be_value *nk = (bt_be_value *)realloc(out->as_dict.keys, sizeof(bt_be_value) * (n + 1));
                bt_be_value *nv = (bt_be_value *)realloc(out->as_dict.vals, sizeof(bt_be_value) * (n + 1));
                if (!nk || !nv) { be_free(&k); be_free(&val); be_free(out); return -1; }
                out->as_dict.keys = nk;
                out->as_dict.vals = nv;
                out->as_dict.keys[n] = k;
                out->as_dict.vals[n] = val;
                out->as_dict.count = n + 1;
            }
            if (p >= end) { be_free(out); return -1; }
            p++;
            out->raw_len = (size_t)(p - out->raw);
            *pp = p;
            return 0;
        }
        default: {
            if (*p < '0' || *p > '9') return -1;
            size_t slen = 0;
            while (p < end && *p >= '0' && *p <= '9') {
                if (slen > (SIZE_MAX - (*p - '0')) / 10) return -1;
                slen = slen * 10 + (size_t)(*p - '0');
                p++;
            }
            if (p >= end || *p != ':') return -1;
            p++;
            if ((size_t)(end - p) < slen) return -1;
            out->type = BT_BE_STR;
            out->as_str.p = p;
            out->as_str.len = slen;
            p += slen;
            out->raw_len = (size_t)(p - out->raw);
            *pp = p;
            return 0;
        }
    }
}

int bt_be_decode(const uint8_t *data, size_t len, bt_be_value *out) {
    const uint8_t *p = data;
    const uint8_t *end = data + len;
    if (parse_value(&p, end, out, 0) != 0) return -1;
    return 0;
}

int bt_be_decode_prefix(const uint8_t *data, size_t len, bt_be_value *out, size_t *consumed) {
    const uint8_t *p = data;
    const uint8_t *end = data + len;
    if (parse_value(&p, end, out, 0) != 0) return -1;
    if (consumed) *consumed = (size_t)(p - data);
    return 0;
}

static void be_free(bt_be_value *v) {
    if (!v) return;
    switch (v->type) {
        case BT_BE_LIST:
            for (size_t i = 0; i < v->as_list.count; i++) be_free(&v->as_list.items[i]);
            free(v->as_list.items);
            break;
        case BT_BE_DICT:
            for (size_t i = 0; i < v->as_dict.count; i++) {
                be_free(&v->as_dict.keys[i]);
                be_free(&v->as_dict.vals[i]);
            }
            free(v->as_dict.keys);
            free(v->as_dict.vals);
            break;
        default:
            break;
    }
    zero_value(v);
}

void bt_be_free(bt_be_value *v) { be_free(v); }

static bt_be_value be_clone(const bt_be_value *src) {
    bt_be_value v;
    zero_value(&v);
    if (!src) return v;
    v.type = src->type;
    v.as_int = src->as_int;
    switch (src->type) {
        case BT_BE_INT:
            break;
        case BT_BE_STR: {
            uint8_t *p = (uint8_t *)malloc(src->as_str.len ? src->as_str.len : 1);
            if (!p) break;
            if (src->as_str.len) memcpy(p, src->as_str.p, src->as_str.len);
            v.as_str.p = p;
            v.as_str.len = src->as_str.len;
            break;
        }
        case BT_BE_LIST: {
            size_t n = src->as_list.count ? src->as_list.count : 1;
            v.as_list.items = (bt_be_value *)calloc(n, sizeof(bt_be_value));
            if (!v.as_list.items) { v.as_list.count = 0; break; }
            v.as_list.count = src->as_list.count;
            for (size_t i = 0; i < src->as_list.count; i++)
                v.as_list.items[i] = be_clone(&src->as_list.items[i]);
            break;
        }
        case BT_BE_DICT: {
            size_t n = src->as_dict.count ? src->as_dict.count : 1;
            v.as_dict.keys = (bt_be_value *)calloc(n, sizeof(bt_be_value));
            v.as_dict.vals = (bt_be_value *)calloc(n, sizeof(bt_be_value));
            if (!v.as_dict.keys || !v.as_dict.vals) {
                free(v.as_dict.keys); free(v.as_dict.vals);
                v.as_dict.keys = NULL; v.as_dict.vals = NULL;
                v.as_dict.count = 0;
                break;
            }
            v.as_dict.count = src->as_dict.count;
            for (size_t i = 0; i < src->as_dict.count; i++) {
                v.as_dict.keys[i] = be_clone(&src->as_dict.keys[i]);
                v.as_dict.vals[i] = be_clone(&src->as_dict.vals[i]);
            }
            break;
        }
    }
    return v;
}

bt_be_value bt_be_clone(const bt_be_value *src) {
    return be_clone(src);
}

bt_be_value *bt_be_dict_get(const bt_be_value *dict, const char *key, size_t keylen) {
    if (!dict || dict->type != BT_BE_DICT) return NULL;
    if (keylen == 0) keylen = strlen(key);
    for (size_t i = 0; i < dict->as_dict.count; i++) {
        const bt_be_value *k = &dict->as_dict.keys[i];
        if (k->type == BT_BE_STR && k->as_str.len == keylen &&
            memcmp(k->as_str.p, key, keylen) == 0) {
            return &dict->as_dict.vals[i];
        }
    }
    return NULL;
}

char *bt_be_strdup(const bt_be_value *v) {
    if (!v || v->type != BT_BE_STR) return NULL;
    char *r = (char *)malloc(v->as_str.len + 1);
    if (!r) return NULL;
    memcpy(r, v->as_str.p, v->as_str.len);
    r[v->as_str.len] = '\0';
    return r;
}

/* ---------- 编码 ---------- */

static void enc_buf(uint8_t **out, size_t *len, size_t *cap, const void *d, size_t n) {
    if (*len + n > *cap) {
        size_t nc = *cap ? *cap : 64;
        while (nc < *len + n) nc *= 2;
        *out = (uint8_t *)realloc(*out, nc);
        *cap = nc;
    }
    if (n) memcpy(*out + *len, d, n);
    *len += n;
}

static void enc_int(uint8_t **out, size_t *len, size_t *cap, int64_t n) {
    char tmp[32];
    int l = snprintf(tmp, sizeof(tmp), "i%llde", (long long)n);
    enc_buf(out, len, cap, tmp, (size_t)l);
}

static void enc_str(uint8_t **out, size_t *len, size_t *cap, const uint8_t *p, size_t n) {
    char tmp[32];
    int l = snprintf(tmp, sizeof(tmp), "%zu:", n);
    enc_buf(out, len, cap, tmp, (size_t)l);
    enc_buf(out, len, cap, p, n);
}

static void enc_value(uint8_t **out, size_t *len, size_t *cap, const bt_be_value *v);

static void enc_value(uint8_t **out, size_t *len, size_t *cap, const bt_be_value *v) {
    switch (v->type) {
        case BT_BE_INT: enc_int(out, len, cap, v->as_int); break;
        case BT_BE_STR: enc_str(out, len, cap, v->as_str.p, v->as_str.len); break;
        case BT_BE_LIST: {
            enc_buf(out, len, cap, "l", 1);
            for (size_t i = 0; i < v->as_list.count; i++) enc_value(out, len, cap, &v->as_list.items[i]);
            enc_buf(out, len, cap, "e", 1);
            break;
        }
        case BT_BE_DICT: {
            enc_buf(out, len, cap, "d", 1);
            for (size_t i = 0; i < v->as_dict.count; i++) {
                enc_value(out, len, cap, &v->as_dict.keys[i]);
                enc_value(out, len, cap, &v->as_dict.vals[i]);
            }
            enc_buf(out, len, cap, "e", 1);
            break;
        }
    }
}

uint8_t *bt_be_encode(const bt_be_value *v, size_t *out_len) {
    uint8_t *out = NULL;
    size_t len = 0, cap = 0;
    enc_value(&out, &len, &cap, v);
    if (out_len) *out_len = len;
    return out;
}

bt_be_value bt_be_int(int64_t n) {
    bt_be_value v; zero_value(&v);
    v.type = BT_BE_INT; v.as_int = n;
    return v;
}

bt_be_value bt_be_str(const char *s) {
    bt_be_value v; zero_value(&v);
    v.type = BT_BE_STR;
    v.as_str.p = (const uint8_t *)s;
    v.as_str.len = strlen(s);
    return v;
}

bt_be_value bt_be_strn(const uint8_t *p, size_t n) {
    bt_be_value v; zero_value(&v);
    v.type = BT_BE_STR;
    v.as_str.p = p;
    v.as_str.len = n;
    return v;
}

void bt_be_dict_set(bt_be_value *dict, const char *key, bt_be_value *val) {
    if (!dict || dict->type != BT_BE_DICT) return;
    size_t keylen = strlen(key);
    for (size_t i = 0; i < dict->as_dict.count; i++) {
        bt_be_value *k = &dict->as_dict.keys[i];
        if (k->type == BT_BE_STR && k->as_str.len == keylen &&
            memcmp(k->as_str.p, key, keylen) == 0) {
            be_free(&dict->as_dict.vals[i]);
            dict->as_dict.vals[i] = *val;
            return;
        }
    }
    size_t n = dict->as_dict.count;
    bt_be_value *nk = (bt_be_value *)realloc(dict->as_dict.keys, sizeof(bt_be_value) * (n + 1));
    bt_be_value *nv = (bt_be_value *)realloc(dict->as_dict.vals, sizeof(bt_be_value) * (n + 1));
    if (!nk || !nv) return;
    dict->as_dict.keys = nk;
    dict->as_dict.vals = nv;
    bt_be_value k; zero_value(&k);
    k.type = BT_BE_STR;
    k.as_str.p = (const uint8_t *)key;
    k.as_str.len = keylen;
    dict->as_dict.keys[n] = k;
    dict->as_dict.vals[n] = *val;
    dict->as_dict.count = n + 1;
}
