#!/usr/bin/env python3
"""
Patch phpredis library.c: NUL-terminate decompressed buffers.

Why: PHP >= 8.6's json scanner detects end-of-input via a NUL byte
(EOI = "\\000" rule in ext/json/json_scanner.re; YYFILL is a no-op),
so php_json_decode() reads past val_len. redis_uncompress() used to
return raw emalloc'd buffers without a sentinel, which made
SERIALIZER_JSON + compression fail or pass depending on heap contents
(the byte after the buffer is either a stale NUL from freed
zend_strings or garbage). NUL-terminating the decompressed buffer
makes json decoding deterministic. Run from the phpredis source
directory.

Idempotency: phpredis 6.3.0RC1 upstreamed equivalent NUL-termination
for all three codecs (lzf: safe_erealloc(..., 1) + data[res] = '\\0';
zstd / lz4: emalloc(len + 1) + terminator), so for each codec this
script first checks whether the upstream tree already terminates the
buffer right after the decompress call and skips that codec if so.
Only when the unfixed shape is found verbatim is the patch applied.
If neither shape is recognized the script fails loudly instead of
silently building a broken package.
"""
import re
import sys


def main():
    try:
        text = open("library.c", encoding="utf-8").read()
    except FileNotFoundError:
        print("::error::library.c not found (run this script from the phpredis source dir)")
        return 1

    # (name, decompress-call regex, NUL-termination regex, unfixed, patched)
    edits = [
        # lzf
        (
            "lzf",
            r"lzf_decompress\(",
            r"data\[res\]\s*=\s*'\\0'",
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
            "zstd",
            r"ZSTD_decompress\(",
            r"data\[\*dstlen\]\s*=\s*'\\0'",
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
            "lz4",
            r"LZ4_decompress_safe\(",
            r"data\[res\]\s*=\s*'\\0'",
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

    applied = []
    skipped = []

    for name, call_re, term_re, old, new in edits:
        m = re.search(call_re, text)
        if m:
            window = text[m.start():m.start() + 600]
            if re.search(term_re, window):
                skipped.append(name)
                continue
        if text.count(old) == 1:
            text = text.replace(old, new)
            applied.append(name)
            continue
        print(
            f"::error::{name} block in library.c matches neither the unfixed shape nor "
            "a NUL-terminated shape (phpredis upstream changed?) -- update "
            ".github/patches/fix_redis_library_nul.py"
        )
        return 1

    if applied:
        open("library.c", "w", encoding="utf-8").write(text)
        if skipped:
            print(
                "patched: "
                + ", ".join(applied)
                + " decompress buffers are NUL-terminated; "
                + ", ".join(skipped)
                + " already fixed upstream (skipped)"
            )
        else:
            print("patched: " + ", ".join(applied) + " decompress buffers are NUL-terminated")
    else:
        print(
            "no patch needed: "
            + ", ".join(skipped)
            + " decompress buffers are already NUL-terminated upstream"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
