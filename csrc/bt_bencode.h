#ifndef BT_BENCODE_H
#define BT_BENCODE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BT_BE_INT = 1,
    BT_BE_STR = 2,
    BT_BE_LIST = 3,
    BT_BE_DICT = 4,
} bt_be_type;

typedef struct bt_be_value bt_be_value;

struct bt_be_value {
    bt_be_type type;
    int64_t as_int;
    struct { const uint8_t *p; size_t len; } as_str;
    struct { bt_be_value *items; size_t count; } as_list;
    struct { bt_be_value *keys; bt_be_value *vals; size_t count; } as_dict;
    /* 该值在原始输入 buffer 中的字节区间（解码时填充，用于算 info hash） */
    const uint8_t *raw;
    size_t raw_len;
};

/* 解码完整 buffer。返回 0 成功；失败返回非 0。out 需用 bt_be_free 释放。 */
int bt_be_decode(const uint8_t *data, size_t len, bt_be_value *out);

/* 解码一个值，并返回其消费的字节数（用于解析「bencode 字典 + 原始数据」拼接的消息，
 * 如 ut_metadata 的 data 消息）。成功返回 0。 */
int bt_be_decode_prefix(const uint8_t *data, size_t len, bt_be_value *out, size_t *consumed);

/* 递归释放解码结果 */
void bt_be_free(bt_be_value *v);

/* 在字典中按 key（字符串，未含结尾 NUL 也可以）查找，返回 val，找不到返回 NULL */
bt_be_value *bt_be_dict_get(const bt_be_value *dict, const char *key, size_t keylen);

/* 便利：把字符串值复制成 NUL 结尾的 C 字符串（调用方 free） */
char *bt_be_strdup(const bt_be_value *v);

/* 深拷贝一个值（字符串数据一并复制；raw 指向置空）。调用方 bt_be_free。 */
bt_be_value bt_be_clone(const bt_be_value *src);

/* 编码：int / str / list / dict。返回新分配的 buffer（malloc），失败返回 NULL。 */
uint8_t *bt_be_encode(const bt_be_value *v, size_t *out_len);

/* 编码用构造帮助函数 */
bt_be_value bt_be_int(int64_t n);
bt_be_value bt_be_str(const char *s);              /* NUL 结尾 */
bt_be_value bt_be_strn(const uint8_t *p, size_t n); /* 任意字节 */

/* 把 key=value 追加进字典（对现有 value 递归释放并覆盖，若同 key 已存在） */
void bt_be_dict_set(bt_be_value *dict, const char *key, bt_be_value *val);

#ifdef __cplusplus
}
#endif

#endif /* BT_BENCODE_H */
