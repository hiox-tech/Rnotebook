#include <stdio.h>
#include <stdlib.h>

static int allocation_calls, fail_at, live_allocations;
static void *test_malloc(size_t size) {
    if (++allocation_calls == fail_at) return NULL;
    void *result = malloc(size);
    if (result) live_allocations++;
    return result;
}
static void test_free(void *pointer) {
    if (pointer) live_allocations--;
    free(pointer);
}
#define ts_malloc test_malloc
#define ts_free test_free
#include "scanner.c"

int main(void) {
    for (fail_at = 1; fail_at <= 3; fail_at++) {
        allocation_calls = 0;
        void *scanner = tree_sitter_r_external_scanner_create();
        if ((fail_at <= 2) != (scanner == NULL)) return 2;
        tree_sitter_r_external_scanner_destroy(scanner);
        if (live_allocations != 0) {
            fprintf(stderr, "allocation failure %d leaked %d allocations\n", fail_at, live_allocations);
            return 1;
        }
    }
    puts("R_SCANNER_ALLOCATION_OK");
    return 0;
}
