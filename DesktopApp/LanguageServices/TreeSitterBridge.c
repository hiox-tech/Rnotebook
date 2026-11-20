#include "TreeSitterBridge.h"
#include "tree_sitter/api.h"
#include <string.h>
extern const TSLanguage *tree_sitter_r(void);
extern const TSLanguage *tree_sitter_markdown(void);
extern const TSLanguage *tree_sitter_markdown_inline(void);
struct RNTreeHighlighter { TSParser *parser; TSQuery *query; TSTree *tree; char *previous; uint32_t length; };
RNTreeHighlighter *rn_tree_create(int language, const char *query, uint32_t length) {
    const TSLanguage *grammar = language == 0 ? tree_sitter_r() : language == 1 ? tree_sitter_markdown() : tree_sitter_markdown_inline();
    RNTreeHighlighter *h = calloc(1, sizeof(*h));
    h->parser = ts_parser_new();
    uint32_t offset = 0; TSQueryError error;
    h->query = ts_query_new(grammar, query, length, &offset, &error);
    if (!h->query || !ts_parser_set_language(h->parser, grammar)) { rn_tree_destroy(h); return NULL; }
    return h;
}
void rn_tree_destroy(RNTreeHighlighter *h) {
    if (!h) return;
    if (h->tree) ts_tree_delete(h->tree);
    if (h->query) ts_query_delete(h->query);
    if (h->parser) ts_parser_delete(h->parser);
    free(h->previous); free(h);
}
static TSPoint point(const char *s, uint32_t length) {
    TSPoint p = {0, 0};
    for (uint32_t i = 0; i < length; i++) { if (s[i] == '\n') { p.row++; p.column = 0; } else p.column++; }
    return p;
}
static bool matches(const RNTreeHighlighter *h, const TSQueryMatch *m, const char *s) {
    uint32_t n = 0; const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(h->query, m->pattern_index, &n);
    for (uint32_t i = 0; i + 2 < n; i++) {
        if (steps[i].type != TSQueryPredicateStepTypeString) continue;
        uint32_t len = 0; const char *op = ts_query_string_value_for_id(h->query, steps[i].value_id, &len);
        if (len != 3 || memcmp(op, "eq?", 3) != 0) continue;
        uint32_t expected_len = 0;
        const char *expected = ts_query_string_value_for_id(h->query, steps[i+2].value_id, &expected_len);
        for (uint16_t k = 0; k < m->capture_count; k++) if (m->captures[k].index == steps[i+1].value_id) {
            TSNode node = m->captures[k].node;
            uint32_t start = ts_node_start_byte(node), end = ts_node_end_byte(node);
            if (end - start != expected_len || memcmp(s + start, expected, expected_len) != 0) return false;
        }
    }
    return true;
}
RNTreeCapture *rn_tree_highlight(RNTreeHighlighter *h, const char *s, uint32_t length, uint32_t *count) {
    *count = 0;
    if (!h) return NULL;
    if (h->tree && h->previous) {
        uint32_t prefix = 0, suffix = 0;
        while (prefix < length && prefix < h->length && s[prefix] == h->previous[prefix]) prefix++;
        while (prefix && prefix < length && ((unsigned char)s[prefix] & 0xc0) == 0x80) prefix--;
        while (suffix < length-prefix && suffix < h->length-prefix && s[length-1-suffix] == h->previous[h->length-1-suffix]) suffix++;
        while (suffix && (((unsigned char)s[length-suffix] & 0xc0) == 0x80 || ((unsigned char)h->previous[h->length-suffix] & 0xc0) == 0x80)) suffix--;
        TSInputEdit edit = { prefix, h->length-suffix, length-suffix, point(s,prefix), point(h->previous,h->length-suffix), point(s,length-suffix) };
        ts_tree_edit(h->tree, &edit);
    }
    TSTree *tree = ts_parser_parse_string(h->parser, h->tree, s, length);
    if (h->tree) ts_tree_delete(h->tree);
    h->tree = tree;
    free(h->previous); h->previous = malloc(length+1); memcpy(h->previous,s,length); h->previous[length]=0; h->length=length;
    if (!tree) return NULL;
    TSQueryCursor *cursor = ts_query_cursor_new();
    ts_query_cursor_exec(cursor, h->query, ts_tree_root_node(tree));
    uint32_t capacity = 128; RNTreeCapture *out = malloc(capacity * sizeof(*out));
    TSQueryMatch match;
    while (ts_query_cursor_next_match(cursor, &match)) {
        if (!matches(h, &match, s)) continue;
        for (uint16_t i = 0; i < match.capture_count; i++) {
            if (*count == capacity) { capacity *= 2; out = realloc(out, capacity * sizeof(*out)); }
            uint32_t ignored;
            out[*count] = (RNTreeCapture){ ts_node_start_byte(match.captures[i].node), ts_node_end_byte(match.captures[i].node), match.pattern_index,
                ts_query_capture_name_for_id(h->query, match.captures[i].index, &ignored) };
            (*count)++;
        }
    }
    ts_query_cursor_delete(cursor); return out;
}
void rn_tree_free(RNTreeCapture *captures) { free(captures); }
