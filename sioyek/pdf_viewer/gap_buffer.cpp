// gap_buffer.cpp — Emacs-style gap buffer for Limn text-engine buffers (v0.20)
//
// Algorithm: identical to Emacs buffer.c (move_gap / make_gap_larger).
// Differences from Emacs:
//   - Storage: QVector<QChar> instead of char* (UTF-16 units, not bytes)
//   - Offsets:  UTF-16 units throughout; codepoint↔UTF-16 conversion stays
//               in LimnCommand (cp_to_qsidx / qsidx_to_cp), unchanged.
//   - No separate byte-offset tracking (Emacs needs it for multibyte; Qt's
//     UTF-16 is fixed-width at the unit level, so one offset suffices).
//
// Layout of buf_ at any time:
//   [ pre-gap content ][ gap (unused) ][ post-gap content ]
//   0 .. gap_pos_-1     gap_pos_ ..       gap_pos_+gap_size_ .. buf_.size()-1
//
// length() = buf_.size() - gap_size_     (total content, excludes gap)
// to_qstring() = stitch pre + post into a new QString

#include "gap_buffer.h"

#include <algorithm>    // std::copy, std::copy_backward
#include <QtGlobal>     // Q_ASSERT

// ─── Construction ─────────────────────────────────────────────────────────────

GapBuffer::GapBuffer(int initial_gap_size)
    : gap_pos_(0)
    , gap_size_(qMax(initial_gap_size, 1))
    , default_gap_(qMax(initial_gap_size, 1))
{
    buf_.resize(gap_size_);
    // buf_ is entirely gap; no content yet.
}

// ─── clear ────────────────────────────────────────────────────────────────────

void GapBuffer::clear()
{
    // Mark the entire allocation as gap.  O(1), no realloc.
    // gap_pos_ = 0 so the (empty) pre-gap region is logically at the start,
    // ready for the next insert(0, ...) without a gap move.
    gap_pos_  = 0;
    gap_size_ = buf_.size();
}

// ─── insert ───────────────────────────────────────────────────────────────────

void GapBuffer::insert(int offset, const QString& str)
{
    if (str.isEmpty()) return;
    Q_ASSERT(offset >= 0 && offset <= length());

    ensure_gap(str.length());   // grow gap if needed; gap_pos_ still valid
    move_gap_to(offset);        // slide gap so it starts at offset

    // Copy str into the left side of the gap, then advance gap_pos_.
    const QChar* src = str.constData();
    int          n   = str.length();
    std::copy(src, src + n, buf_.begin() + gap_pos_);
    gap_pos_  += n;
    gap_size_ -= n;
}

// ─── remove ───────────────────────────────────────────────────────────────────

void GapBuffer::remove(int offset, int len)
{
    if (len == 0) return;
    Q_ASSERT(offset >= 0 && offset + len <= length());

    move_gap_to(offset);   // gap now starts right before the chars to delete
    // Expand gap rightward to swallow them — no data movement needed.
    gap_size_ += len;
}

// ─── to_qstring ───────────────────────────────────────────────────────────────

QString GapBuffer::to_qstring() const
{
    const int pre  = gap_pos_;
    const int post = static_cast<int>(buf_.size()) - gap_pos_ - gap_size_;

    QString result;
    result.resize(pre + post);
    QChar* dst = result.data();

    if (pre  > 0) std::copy(buf_.constBegin(),
                             buf_.constBegin() + pre,
                             dst);
    if (post > 0) std::copy(buf_.constBegin() + gap_pos_ + gap_size_,
                             buf_.constEnd(),
                             dst + pre);
    return result;
}

// ─── move_gap_to ──────────────────────────────────────────────────────────────
//
// Move the gap so its left edge sits at logical content offset `target`.
//
// Slide LEFT  (target < gap_pos_):
//   content[target .. gap_pos_) shifts right by gap_size_ slots
//   (Emacs: memmove right into the post-gap area)
//
// Slide RIGHT (target > gap_pos_):
//   content[gap_pos_ .. target) (stored at buf_[gap_pos_+gap_size_ .. target+gap_size_))
//   shifts left by gap_size_ slots
//   (Emacs: memmove left into the pre-gap area)

void GapBuffer::move_gap_to(int target)
{
    if (target == gap_pos_) return;

    if (target < gap_pos_) {
        // Slide gap left: move pre-gap chars at [target, gap_pos_) rightward
        // by gap_size_ slots, so they end up at [target+gap_size_, gap_pos_+gap_size_).
        // Overlapping move toward higher addresses → std::copy_backward.
        std::copy_backward(buf_.begin() + target,
                           buf_.begin() + gap_pos_,
                           buf_.begin() + gap_pos_ + gap_size_);
    } else {
        // Slide gap right: move post-gap chars at [gap_pos_+gap_size_, target+gap_size_)
        // leftward by gap_size_ slots, so they fill [gap_pos_, target).
        // Overlapping move toward lower addresses → std::copy (forward).
        const int count = target - gap_pos_;
        std::copy(buf_.begin() + gap_pos_ + gap_size_,
                  buf_.begin() + gap_pos_ + gap_size_ + count,
                  buf_.begin() + gap_pos_);
    }

    gap_pos_ = target;
}

// ─── ensure_gap ───────────────────────────────────────────────────────────────
//
// Grow the gap to at least `needed` free slots.
// Strategy: new gap = needed + default_gap_ (breathing room avoids
// thrashing on sequential single-char inserts after a large one).
// After resize, the post-gap content block is slid right to make room.

void GapBuffer::ensure_gap(int needed)
{
    if (gap_size_ >= needed) return;

    const int new_gap  = needed + default_gap_;
    const int old_size = static_cast<int>(buf_.size());

    // post-gap content lives at [gap_pos_+gap_size_ .. old_size)
    const int post_start = gap_pos_ + gap_size_;
    const int post_len   = old_size - post_start;

    // Grow the buffer (appends default-initialized QChar at end).
    buf_.resize(old_size + (new_gap - gap_size_));

    // Slide post-gap content right to its new position.
    // Source: [post_start .. post_start+post_len)
    // Dest:   [gap_pos_+new_gap .. gap_pos_+new_gap+post_len)
    // Destination is strictly to the right of source → std::copy_backward.
    if (post_len > 0) {
        std::copy_backward(buf_.begin() + post_start,
                           buf_.begin() + post_start + post_len,
                           buf_.begin() + gap_pos_ + new_gap + post_len);
    }

    gap_size_ = new_gap;
}
