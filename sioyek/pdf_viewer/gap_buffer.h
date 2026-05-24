#pragma once
//
// GapBuffer — efficient text storage for Limn's text-engine buffers (v0.20).
//
// A gap buffer keeps the "hot" editing position cheap: the gap (a region of
// unused storage) sits adjacent to the last edit point, so sequential
// keystrokes are O(1) per character instead of O(n) (no tail memcpy).
// Moving the gap to a new position costs O(distance), matching Emacs' original
// C implementation.
//
// All offsets are in **UTF-16 units** (matching Qt's QString internal
// representation).  The wire-level codepoint ↔ UTF-16-index conversion
// (cp_to_qsidx / qsidx_to_cp) continues to live in LimnCommand, unchanged.
//
// Public API is intentionally a drop-in subset of QString:
//   insert(offset, str)   — insert str at UTF-16 offset
//   remove(offset, len)   — remove len UTF-16 units starting at offset
//   to_qstring()          — materialise current content as QString
//   length()              — content length in UTF-16 units
//
// Constraints:
//   offset ∈ [0, length()] for insert
//   offset ∈ [0, length()), offset+len ∈ [0, length()] for remove
//   Violating these → Q_ASSERT failure (debug builds) / undefined (release).
//

#include <QString>
#include <QVector>

class GapBuffer {
public:
    // initial_gap_size: pre-allocated gap slots.  64 is enough for interactive
    // keystrokes; the buffer grows automatically when exhausted.
    explicit GapBuffer(int initial_gap_size = 64);

    // ── Core editing ─────────────────────────────────────────────────────

    // Insert str at UTF-16 offset ∈ [0, length()].
    // Moves gap to offset (O(distance)), then writes in-place (O(str.length())).
    void insert(int offset, const QString& str);

    // Remove len UTF-16 units in [offset, offset+len) ⊆ [0, length()].
    // Moves gap to offset (O(distance)), then expands gap by len (O(1)).
    void remove(int offset, int len);

    // Reset to empty, keeping the pre-allocated storage.  O(1).
    // Equivalent to: *this = GapBuffer(default_gap_) but without realloc.
    // Used by callers that replace the entire content (minibuffer/open,
    // minibuffer/set-text, message/echo, message/clear).
    void clear();

    // ── Queries ───────────────────────────────────────────────────────────

    // Materialise content as a contiguous QString.  O(n).
    QString to_qstring() const;

    // Content length in UTF-16 units (gap slots excluded).
    int length() const { return static_cast<int>(buf_.size()) - gap_size_; }

    bool is_empty() const { return length() == 0; }

private:
    // Move the gap so gap_pos_ == target (in logical content offset).
    // O(|target - logical_gap_pos|).
    void move_gap_to(int target);

    // Grow the gap to at least `needed` free slots.  O(n) realloc.
    void ensure_gap(int needed);

    // Translate a logical content offset (0..length()) into a buf_ index.
    // Offsets before the gap are 1:1; offsets at or after the gap are
    // shifted right by gap_size_.
    int buf_index(int logical) const {
        return (logical < gap_pos_) ? logical : logical + gap_size_;
    }

    QVector<QChar> buf_;           // Raw storage: content bytes + gap region
    int            gap_pos_  = 0;  // Logical offset where the gap starts
    int            gap_size_ = 0;  // Number of unused (gap) slots in buf_
    int            default_gap_;   // Gap size to use when re-gapping
};
