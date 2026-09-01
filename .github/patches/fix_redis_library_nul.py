#!/usr/bin/env python3
"""
Patch phpredis library.c: NUL-terminate decompressed buffers.

Why: PHP >= 8.6's json scanner detects end-of-input via a NUL byte
(EOI = "\\000" rule in ext/json/json_scanner.re; YYFILL is a no-op),
so php_json_decode() reads past val_len. redis_uncompress() returns
raw emalloc'd buffers without a sentinel, which makes SERIALIZER_JSON
+ compression fail or pass depending on heap contents (the byte after
the buffer is either a stale NUL from freed zend_strings or garbage).
NUL-terminating the decompressed buffer makes json decoding
deterministic. Run from the phpredis source directory.
"""
import sys


def main():
    try:
        text = open("library.c", encoding="utf-8").read()
    except FileNotFoundError:
        print("::error::library.c not found (run this script from the phpredis source dir)")
        return 1

    edits = [
        # lzf
        (
            """                    if ((res = lzf_decompress(src, len, data, len * i)) > 0) {
                        *dst = data;
                        *dstlen = res;
                        return 1;
                    }""",
            """                    if ((res = lzf_decompress(src, len, data, len * i)) > 0) {
                        /* NUL-terminate: PHP >= 8.6 json scanner detects EOI
                         * by a NUL byte and reads past val_len */
                        data = erealloc(data, res + 1);
                        data[res] = '\\0';
                        *dst = data;
                        *dstlen = res;
                        return 1;
                    }""",
        ),
        # zstd
        (
            """                data = emalloc(zlen);
                *dstlen = ZSTD_decompress(data, zlen, src, len);
                if (ZSTD_isError(*dstlen) || *dstlen != zlen) {
                    efree(data);
                    break;
                }

                *dst = data;
                return 1;""",
            """                data = emalloc(zlen + 1);
                *dstlen = ZSTD_decompress(data, zlen, src, len);
                if (ZSTD_isError(*dstlen) || *dstlen != zlen) {
                    efree(data);
                    break;
                }

                /* NUL-terminate: PHP >= 8.6 json scanner detects EOI
                 * by a NUL byte and reads past val_len */
                data[*dstlen] = '\\0';
                *dst = data;
                return 1;""",
        ),
        # lz4
        (
            """                data = emalloc(datalen);
                res = LZ4_decompress_safe(copy, data, copylen, datalen);
                if (res == datalen) {
                    *dst = data;
                    *dstlen = res;
                    return 1;
                }""",
            """                data = emalloc(datalen + 1);
                res = LZ4_decompress_safe(copy, data, copylen, datalen);
                if (res == datalen) {
                    /* NUL-terminate: PHP >= 8.6 json scanner detects EOI
                     * by a NUL byte and reads past val_len */
                    data[res] = '\\0';
                    *dst = data;
                    *dstlen = res;
                    return 1;
                }""",
        ),
    ]

    for old, new in edits:
        if text.count(old) != 1:
            print("::error::library.c patch does not match exactly once (phpredis upstream changed?)")
            return 1
        text = text.replace(old, new)

    open("library.c", "w", encoding="utf-8").write(text)
    print("patched: lzf, zstd, lz4 decompress buffers are NUL-terminated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
