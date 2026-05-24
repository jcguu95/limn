// gap_buffer_test.cpp — standalone unit tests for GapBuffer (v0.20 TDD).
//
// Compile (from repo root, with Qt in PATH):
//   c++ -std=c++17 $(pkg-config --cflags Qt5Core) \
//       sioyek/pdf_viewer/gap_buffer_test.cpp \
//       sioyek/pdf_viewer/gap_buffer.cpp \
//       $(pkg-config --libs Qt5Core) \
//       -o gap_buffer_test && ./gap_buffer_test
//
// Or with Qt6:
//   c++ -std=c++17 $(pkg-config --cflags Qt6Core) \
//       sioyek/pdf_viewer/gap_buffer_test.cpp \
//       sioyek/pdf_viewer/gap_buffer.cpp \
//       $(pkg-config --libs Qt6Core) \
//       -o gap_buffer_test && ./gap_buffer_test
//
// Exit code: 0 = all pass, 1 = any failure.
//
// Coverage (matches SPEC §v0.20 "~20 unit tests for GapBuffer"):
//   T01  empty buffer state
//   T02  insert into empty at offset 0
//   T03  insert at end (== length)
//   T04  insert in the middle (gap must move)
//   T05  sequential inserts at same position (gap stays)
//   T06  backwards inserts (gap moves every time)
//   T07  remove from front
//   T08  remove from end
//   T09  remove from middle (gap moves then expands)
//   T10  remove entire content
//   T11  insert-then-remove round-trip
//   T12  interleaved insert and remove
//   T13  ASCII boundary: single-char inserts at 0, mid, end
//   T14  BMP CJK: each character is 1 UTF-16 unit, length() == codepoints
//   T15  non-BMP emoji: each emoji is 2 UTF-16 units (surrogate pair)
//   T16  mixed BMP + non-BMP sequence length accounting
//   T17  surrogate integrity: insert at surrogate boundary is valid at even UTF-16 offsets
//   T18  remove length 0 is a no-op (content unchanged, length unchanged)
//   T19  multiple gap regrows (small initial_gap forced by tiny buffer)
//   T20  large sequential build via char-by-char append, verify final content
//

#include "gap_buffer.h"

#include <QCoreApplication>
#include <QString>
#include <cstdio>
#include <cstdlib>
#include <functional>

// ─── Minimal test harness ────────────────────────────────────────────────────

static int g_pass = 0;
static int g_fail = 0;

static void check(bool ok, const char* label, const char* detail = nullptr) {
    if (ok) {
        std::printf("  ✓ %s\n", label);
        ++g_pass;
    } else {
        std::printf("  ✗ %s%s%s\n", label,
                    detail ? " — " : "",
                    detail ? detail : "");
        ++g_fail;
    }
}

#define CHECK(expr)      check((expr), #expr)
#define CHECK_EQ(a, b)   do {                                                   \
    auto _a = (a); auto _b = (b);                                               \
    bool _ok = (_a == _b);                                                      \
    char _buf[256];                                                              \
    if (!_ok) std::snprintf(_buf, sizeof(_buf),                                 \
                            "got [%s] expected [%s]",                           \
                            qPrintable(to_display(_a)),                         \
                            qPrintable(to_display(_b)));                        \
    check(_ok, #a " == " #b, _ok ? nullptr : _buf);                            \
} while (0)

static QString to_display(const QString& s) { return s; }
static QString to_display(int v)            { return QString::number(v); }

#define TEST(name)  do {                                                        \
    std::printf("\n┌─ " #name "\n");                                            \
    int _p0 = g_pass, _f0 = g_fail;                                             \
    [&]()

#define END_TEST()                                                              \
    ();                                                                         \
    std::printf("└─ %d passed, %d failed\n",                                   \
                g_pass - _p0, g_fail - _f0);                                   \
} while (0)

// ─── Tests ───────────────────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    // QCoreApplication required for QString to work reliably on all platforms.
    QCoreApplication app(argc, argv);

    // T01 — empty buffer state
    TEST(T01_empty_buffer_state) {
        GapBuffer gb;
        CHECK_EQ(0,       gb.length());
        CHECK_EQ(true,    gb.is_empty());
        CHECK_EQ(QString(""), gb.to_qstring());
    } END_TEST();

    // T02 — insert into empty buffer at offset 0
    TEST(T02_insert_at_zero_into_empty) {
        GapBuffer gb;
        gb.insert(0, QString("hello"));
        CHECK_EQ(5,                 gb.length());
        CHECK_EQ(QString("hello"),  gb.to_qstring());
        CHECK_EQ(false,             gb.is_empty());
    } END_TEST();

    // T03 — insert at end (offset == length)
    TEST(T03_insert_at_end) {
        GapBuffer gb;
        gb.insert(0, QString("hello"));
        gb.insert(5, QString(" world"));
        CHECK_EQ(11,                      gb.length());
        CHECK_EQ(QString("hello world"),  gb.to_qstring());
    } END_TEST();

    // T04 — insert in the middle (requires gap movement)
    TEST(T04_insert_in_middle_gap_move) {
        GapBuffer gb;
        gb.insert(0, QString("helo"));       // gap ends up after position 4
        gb.insert(3, QString("l"));           // gap must move left to pos 3
        CHECK_EQ(5,                  gb.length());
        CHECK_EQ(QString("hello"),   gb.to_qstring());
    } END_TEST();

    // T05 — sequential inserts at the same position (gap stays in place)
    TEST(T05_sequential_inserts_same_position) {
        GapBuffer gb;
        gb.insert(0, QString("a"));
        gb.insert(1, QString("b"));
        gb.insert(2, QString("c"));
        gb.insert(3, QString("d"));
        CHECK_EQ(4,                 gb.length());
        CHECK_EQ(QString("abcd"),   gb.to_qstring());
    } END_TEST();

    // T06 — backwards inserts (gap must move on every call)
    TEST(T06_backwards_inserts_gap_moves_each_time) {
        GapBuffer gb;
        gb.insert(0, QString("d"));
        gb.insert(0, QString("c"));
        gb.insert(0, QString("b"));
        gb.insert(0, QString("a"));
        CHECK_EQ(4,                 gb.length());
        CHECK_EQ(QString("abcd"),   gb.to_qstring());
    } END_TEST();

    // T07 — remove from front
    TEST(T07_remove_from_front) {
        GapBuffer gb;
        gb.insert(0, QString("hello world"));
        gb.remove(0, 6);                    // remove "hello " → "world"
        CHECK_EQ(5,                 gb.length());
        CHECK_EQ(QString("world"),  gb.to_qstring());
    } END_TEST();

    // T08 — remove from end
    TEST(T08_remove_from_end) {
        GapBuffer gb;
        gb.insert(0, QString("hello world"));
        gb.remove(5, 6);                    // remove " world" → "hello"
        CHECK_EQ(5,                 gb.length());
        CHECK_EQ(QString("hello"),  gb.to_qstring());
    } END_TEST();

    // T09 — remove from middle (gap must move to the removal site)
    TEST(T09_remove_from_middle_gap_move) {
        GapBuffer gb;
        gb.insert(0, QString("hello world"));
        gb.remove(5, 1);                    // remove the space → "helloworld"
        CHECK_EQ(10,                    gb.length());
        CHECK_EQ(QString("helloworld"), gb.to_qstring());
    } END_TEST();

    // T10 — remove entire content
    TEST(T10_remove_all_content) {
        GapBuffer gb;
        gb.insert(0, QString("abc"));
        gb.remove(0, 3);
        CHECK_EQ(0,           gb.length());
        CHECK_EQ(true,        gb.is_empty());
        CHECK_EQ(QString(""), gb.to_qstring());
    } END_TEST();

    // T11 — insert then remove round-trip restores original
    TEST(T11_insert_remove_roundtrip) {
        GapBuffer gb;
        gb.insert(0, QString("original"));
        gb.insert(4, QString("---"));       // "orig---inal"
        gb.remove(4, 3);                    // remove "---" → "original"
        CHECK_EQ(8,                    gb.length());
        CHECK_EQ(QString("original"),  gb.to_qstring());
    } END_TEST();

    // T12 — interleaved inserts and removes
    TEST(T12_interleaved_insert_remove) {
        GapBuffer gb;
        gb.insert(0, QString("the quick brown fox"));   // 19 chars
        gb.remove(4, 6);                                // remove "quick " → "the brown fox"
        gb.insert(4, QString("slow "));                 // → "the slow brown fox"
        CHECK_EQ(18,                          gb.length());
        CHECK_EQ(QString("the slow brown fox"), gb.to_qstring());
    } END_TEST();

    // T13 — ASCII boundary: single-char inserts at position 0, mid, end
    TEST(T13_ascii_single_char_boundaries) {
        GapBuffer gb;
        gb.insert(0, QString("BD"));        // "BD"
        gb.insert(1, QString("C"));         // "BCD"
        gb.insert(0, QString("A"));         // "ABCD"
        gb.insert(4, QString("E"));         // "ABCDE"
        CHECK_EQ(5,                  gb.length());
        CHECK_EQ(QString("ABCDE"),   gb.to_qstring());
    } END_TEST();

    // T14 — BMP CJK: each CJK character is 1 UTF-16 unit
    TEST(T14_bmp_cjk_length) {
        GapBuffer gb;
        // U+4F60 U+597D U+4E16 U+754C — "你好世界" (4 BMP code points)
        QString cjk = QString::fromUtf8("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
        gb.insert(0, cjk);
        CHECK_EQ(4,    gb.length());    // 4 UTF-16 units (all BMP)
        CHECK_EQ(cjk,  gb.to_qstring());
        // Insert another CJK char in the middle
        QString mid = QString::fromUtf8("\xe5\xb0\x8f");  // 小 U+5C0F
        gb.insert(2, mid);
        CHECK_EQ(5,    gb.length());
        // Check content: 你好小世界
        QString expected = QString::fromUtf8(
            "\xe4\xbd\xa0\xe5\xa5\xbd\xe5\xb0\x8f\xe4\xb8\x96\xe7\x95\x8c");
        CHECK_EQ(expected, gb.to_qstring());
    } END_TEST();

    // T15 — non-BMP emoji: each emoji occupies 2 UTF-16 units (surrogate pair)
    TEST(T15_non_bmp_emoji_two_utf16_units) {
        GapBuffer gb;
        // U+1F600 GRINNING FACE — encoded as surrogate pair in UTF-16
        QString emoji1 = QString::fromUtf8("\xf0\x9f\x98\x80");  // 😀
        QString emoji2 = QString::fromUtf8("\xf0\x9f\x8c\x9f");  // 🌟
        gb.insert(0, emoji1);
        CHECK_EQ(2,       gb.length());    // 2 UTF-16 units per emoji
        gb.insert(2, emoji2);
        CHECK_EQ(4,       gb.length());    // total: 4 UTF-16 units for 2 emoji
        CHECK_EQ(emoji1 + emoji2, gb.to_qstring());
    } END_TEST();

    // T16 — mixed BMP + non-BMP length accounting
    TEST(T16_mixed_bmp_non_bmp_length) {
        GapBuffer gb;
        // Build: "a😀b" — lengths: a=1, 😀=2, b=1 → total 4 UTF-16 units
        QString emoji = QString::fromUtf8("\xf0\x9f\x98\x80");  // 😀 (2 units)
        gb.insert(0, QString("a"));
        gb.insert(1, emoji);
        gb.insert(3, QString("b"));
        CHECK_EQ(4,                         gb.length());
        CHECK_EQ(QString("a") + emoji + "b", gb.to_qstring());
    } END_TEST();

    // T17 — surrogate integrity: insert at even UTF-16 offsets avoids splitting
    //        a surrogate pair.  GapBuffer itself doesn't enforce this (that's
    //        LimnCommand's job), but we verify that inserting AT the boundary
    //        between two surrogates (offset 1 inside a 2-unit emoji) gives a
    //        well-defined if invalid-Unicode result — the buffer's length and
    //        content invariant still hold.
    TEST(T17_insert_inside_surrogate_pair_is_well_defined) {
        GapBuffer gb;
        QString emoji = QString::fromUtf8("\xf0\x9f\x98\x80");  // 😀 — 2 UTF-16 units
        gb.insert(0, emoji);
        // Insert "X" between the two surrogate halves (offset 1).
        // This creates invalid Unicode, but GapBuffer must not corrupt memory.
        gb.insert(1, QString("X"));
        CHECK_EQ(3,  gb.length());    // 2 surrogate halves + 1 X = 3 UTF-16 units
        // Content must contain all three UTF-16 units in order.
        QString result = gb.to_qstring();
        CHECK_EQ(emoji[0], result[0]);   // high surrogate
        CHECK_EQ(QChar('X'), result[1]);
        CHECK_EQ(emoji[1], result[2]);   // low surrogate
    } END_TEST();

    // T18 — remove length 0 is a no-op
    TEST(T18_remove_zero_length_noop) {
        GapBuffer gb;
        gb.insert(0, QString("hello"));
        gb.remove(2, 0);                  // remove nothing at position 2
        CHECK_EQ(5,                  gb.length());
        CHECK_EQ(QString("hello"),   gb.to_qstring());
    } END_TEST();

    // T19 — multiple gap regrows (tiny initial gap forces several reallocs)
    TEST(T19_multiple_gap_regrows) {
        // Use a very small initial gap (1 slot) so every insert of >=2 chars
        // forces a regrow.
        GapBuffer gb(/*initial_gap_size=*/1);
        gb.insert(0, QString("ab"));      // forces regrow immediately
        gb.insert(2, QString("cd"));
        gb.insert(4, QString("ef"));
        gb.insert(1, QString("xyz"));     // gap moves + possible regrow
        // "ab" → "abcd" → "abcdef" → insert "xyz" at 1 → "a"+"xyz"+"bcdef" = "axyzbcdef"
        CHECK_EQ(9,                    gb.length());
        CHECK_EQ(QString("axyzbcdef"), gb.to_qstring());
    } END_TEST();

    // T20 — large sequential build via char-by-char append, verify final content
    TEST(T20_large_char_by_char_append) {
        GapBuffer gb;
        // Build a 500-char ASCII string sequentially (always at end → gap stays)
        QString expected;
        for (int i = 0; i < 500; ++i) {
            QChar c(static_cast<char>('a' + (i % 26)));
            gb.insert(gb.length(), QString(c));
            expected.append(c);
        }
        CHECK_EQ(500,      gb.length());
        CHECK_EQ(expected, gb.to_qstring());
    } END_TEST();

    // T21 — single large insert exceeds default gap (ensure_gap realloc path)
    // Default gap size is 64.  Inserting a 200-char string at once must force
    // ensure_gap to realloc to at least 200 slots before writing.
    TEST(T21_single_large_insert_exceeds_default_gap) {
        GapBuffer gb;           // default initial_gap = 64
        QString big(200, QChar('x'));
        gb.insert(0, big);
        CHECK_EQ(200,  gb.length());
        CHECK_EQ(big,  gb.to_qstring());
        // Insert another big chunk in the middle (gap now must move AND regrow)
        QString mid(200, QChar('y'));
        gb.insert(100, mid);    // gap moves from 200 → 100, then needs 200 slots
        CHECK_EQ(400,  gb.length());
        CHECK_EQ(big.left(100) + mid + big.mid(100), gb.to_qstring());
    } END_TEST();

    // T22 — to_qstring() correctness when gap is in the middle (decoupled from
    // insert/remove correctness; tests materialization logic independently).
    TEST(T22_to_qstring_with_gap_in_middle) {
        GapBuffer gb;
        gb.insert(0, QString("abcde"));  // gap sits at 5 (end)
        // Force gap to move to position 2 by inserting there (then undo via remove)
        gb.insert(2, QString("X"));      // gap now at 3: "abXcde"
        gb.remove(2, 1);                 // remove "X", gap sits at 2: "abcde"
        // Gap is now at position 2, NOT at 0 or 5.  to_qstring() must still
        // return the correct string by stitching the two halves.
        CHECK_EQ(5,                  gb.length());
        CHECK_EQ(QString("abcde"),   gb.to_qstring());
        // Call to_qstring() a second time — must be idempotent (no side effects).
        CHECK_EQ(QString("abcde"),   gb.to_qstring());
    } END_TEST();

    // T23 — clear() resets content and length to zero; subsequent insert works
    TEST(T23_clear_and_reuse) {
        GapBuffer gb;
        gb.insert(0, QString("old content here"));
        CHECK_EQ(false, gb.is_empty());
        gb.clear();
        CHECK_EQ(0,           gb.length());
        CHECK_EQ(true,        gb.is_empty());
        CHECK_EQ(QString(""), gb.to_qstring());
        // Buffer must be usable after clear — gap is at 0, ready for new inserts.
        gb.insert(0, QString("fresh"));
        CHECK_EQ(5,                 gb.length());
        CHECK_EQ(QString("fresh"),  gb.to_qstring());
    } END_TEST();

    // T24 — clear() when gap is in the middle (not at 0 or end)
    // If clear() forgets to reset gap_pos_ to 0, or leaves stale buf_ data,
    // a subsequent insert would write into the wrong part of the buffer.
    TEST(T24_clear_with_gap_in_middle) {
        GapBuffer gb;
        gb.insert(0, QString("abcde"));  // gap at 5 (end)
        gb.insert(2, QString("X"));      // gap moves to 3: "abXcde", gap at 3
        gb.remove(2, 1);                 // remove "X": "abcde", gap still at 2 (middle)
        // Now gap is at position 2 — neither start nor end.
        gb.clear();                      // must fully reset
        CHECK_EQ(0,           gb.length());
        CHECK_EQ(true,        gb.is_empty());
        CHECK_EQ(QString(""), gb.to_qstring());
        // Re-use after clear with gap in a non-trivial previous position.
        gb.insert(0, QString("hello"));
        CHECK_EQ(5,                  gb.length());
        CHECK_EQ(QString("hello"),   gb.to_qstring());
    } END_TEST();

    // T25 — copy constructor: two copies are independent (no shared buffer_)
    // QHash::value() returns a copy.  If the copy shares the underlying QVector,
    // mutating one would corrupt the other.
    TEST(T25_copy_constructor_independence) {
        GapBuffer original;
        original.insert(0, QString("shared?"));

        GapBuffer copy = original;          // copy constructor

        // Mutate copy; original must be unaffected.
        copy.insert(7, QString(" NO"));     // copy: "shared? NO"
        CHECK_EQ(QString("shared?"),    original.to_qstring());
        CHECK_EQ(QString("shared? NO"), copy.to_qstring());

        // Mutate original; copy must be unaffected.
        original.insert(0, QString(">>>"));
        CHECK_EQ(QString(">>>shared?"),  original.to_qstring());
        CHECK_EQ(QString("shared? NO"),  copy.to_qstring());
    } END_TEST();

    // ── Summary ──────────────────────────────────────────────────────────────
    std::printf("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    std::printf("  %d passed, %d failed (%d total)\n",
                g_pass, g_fail, g_pass + g_fail);
    std::printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    return (g_fail == 0) ? 0 : 1;
}
