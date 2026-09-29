// 用 CloakKit Rust 内核验证产出的 IPA：探测元信息 + 校验 Mach-O/CodeDirectory
#include <stdio.h>
#include <stdlib.h>
#include "cloakkit_core.h"

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "用法: %s <ipa>\n", argv[0]); return 2; }
    const char* path = argv[1];
    printf("=== ck_version: %s ===\n", ck_version());

    char* probe = NULL;
    int rp = ck_probe_ipa(path, &probe);
    if (rp != 0) { fprintf(stderr, "probe 失败(%d): %s\n", rp, ck_last_error()); return 1; }
    printf("[probe] %s\n", probe);
    free(probe);

    char* verify = NULL;
    int rv = ck_verify_binary(path, &verify);
    if (rv != 0) { fprintf(stderr, "verify 失败(%d): %s\n", rv, ck_last_error()); return 1; }
    printf("[verify] %s\n", verify);
    free(verify);
    return 0;
}
