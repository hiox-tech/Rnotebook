#include <stdint.h>
#include <stdlib.h>
typedef struct RNTreeHighlighter RNTreeHighlighter;
typedef struct { uint32_t start, end, pattern; const char *scope; } RNTreeCapture;
RNTreeHighlighter *rn_tree_create(int language, const char *query, uint32_t length);
void rn_tree_destroy(RNTreeHighlighter *value);
RNTreeCapture *rn_tree_highlight(RNTreeHighlighter *value, const char *text, uint32_t length, uint32_t *count);
void rn_tree_free(RNTreeCapture *captures);
