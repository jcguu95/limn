#pragma once
//
// TextBuffer — v0.40 narrow-aware text-engine buffer (Phase 3).
//
// Encapsulates a GapBuffer + per-buffer cursor + optional narrow state in
// one class.  The GapBuffer is `private`, so any code that wants to mutate
// or read buffer content must go through this class's public methods.
// This is our "central gate" for narrowing: the narrow invariant lives
// inside these methods, callers do not need to know it exists.
//
// All offsets here are UTF-16 / QString indices (qsidx), matching
// GapBuffer's internal coordinate system.  The codepoint ↔ qsidx
// conversion (cp_to_qsidx / qsidx_to_cp) continues to live in the
// cmd_buffer_* wire handlers, applied at the wire boundary.  TextBuffer
// itself is qsidx-only — this keeps the class simple and pushes coord
// translation out to one well-known place.
//
// Why "central gate" rather than per-caller convention?  C is what
// Emacs is written in, and C has no access control — so Emacs enforces
// narrow by convention: every primitive that touches PT clamps via
// clip_to_bounds.  We're in C++, so we can lift that convention into
// a class invariant: make the GapBuffer reference unreachable from
// outside, and route every mutation through methods that clamp.  See
// the v0.40 plan commit for the longer survey of why this works for
// us and not for Emacs.

#include <QString>
#include <optional>
#include <utility>

#include "gap_buffer.h"

class TextBuffer {
public:
    TextBuffer() = default;

    // ─── Mutation (cursor / narrow track edits automatically) ───────────
    //
    // qs_at, qs_len, qs_from, qs_to are all QString indices.
    // qs_at clamped to [begv_qs(), zv_qs()] for inserts; deletes clip
    // their range to that interval.  Out-of-range inputs silently
    // become no-ops at the edges — they do not error.

    void insert(int qs_at, const QString& s) {
        const int begv = begv_qs();
        const int zv   = zv_qs();
        qs_at = std::clamp(qs_at, begv, zv);
        const int len = s.length();
        if (len <= 0) return;
        content_.insert(qs_at, s);
        // Cursor advances if insertion is AT-or-BEFORE cursor.
        if (cursor_qs_ >= qs_at) cursor_qs_ += len;
        // Narrow fixup, matching limn/marker semantics:
        //   narrow_start  → :before insertion-type  (does not advance
        //                  when insert is AT start — new chars belong
        //                  to the narrow's visible head)
        //   narrow_end    → :after insertion-type   (advances when
        //                  insert is AT end — typing at ZV grows the
        //                  narrow, matching Emacs's `ZV += nchars`)
        if (narrow_qs_) {
            auto& [s_qs, e_qs] = *narrow_qs_;
            if (qs_at < s_qs)  s_qs += len;
            if (qs_at <= e_qs) e_qs += len;
        }
    }

    void remove(int qs_from, int qs_len) {
        const int begv = begv_qs();
        const int zv   = zv_qs();
        int qs_to = qs_from + qs_len;
        // Clip [qs_from, qs_to) into [begv, zv).
        if (qs_from < begv) qs_from = begv;
        if (qs_to   > zv)   qs_to   = zv;
        if (qs_to <= qs_from) return;
        const int eff_len = qs_to - qs_from;
        content_.remove(qs_from, eff_len);
        // Cursor fixup:
        //   cursor <= qs_from               → unchanged
        //   qs_from < cursor < qs_to        → collapse to qs_from
        //   cursor >= qs_to                 → shift left by eff_len
        if (cursor_qs_ > qs_from) {
            if (cursor_qs_ < qs_to) cursor_qs_ = qs_from;
            else                    cursor_qs_ -= eff_len;
        }
        // Narrow fixup follows the same shape.
        if (narrow_qs_) {
            auto& [s_qs, e_qs] = *narrow_qs_;
            if (s_qs > qs_from) {
                if (s_qs < qs_to) s_qs = qs_from;
                else              s_qs -= eff_len;
            }
            if (e_qs > qs_from) {
                if (e_qs < qs_to) e_qs = qs_from;
                else              e_qs -= eff_len;
            }
        }
    }

    // Clear ALL content (ignores narrow — only used by chrome buffers
    // and minibuffer reset).  Also drops narrow state since the positions
    // it referred to are gone.
    void clear() {
        content_.clear();
        cursor_qs_ = 0;
        narrow_qs_.reset();
    }

    // ─── Cursor ─────────────────────────────────────────────────────────

    int cursor_qs() const { return cursor_qs_; }

    void set_cursor_qs(int qs) {
        cursor_qs_ = std::clamp(qs, begv_qs(), zv_qs());
    }

    // ─── Narrow ─────────────────────────────────────────────────────────

    void narrow_to_qs(int qs_start, int qs_end) {
        const int n = content_.length();
        qs_start = std::clamp(qs_start, 0, n);
        qs_end   = std::clamp(qs_end,   qs_start, n);
        narrow_qs_ = std::make_pair(qs_start, qs_end);
        cursor_qs_ = std::clamp(cursor_qs_, qs_start, qs_end);
    }

    void widen() { narrow_qs_.reset(); }

    bool is_narrowed() const { return narrow_qs_.has_value(); }

    int begv_qs() const { return narrow_qs_ ? narrow_qs_->first  : 0; }
    int zv_qs()   const { return narrow_qs_ ? narrow_qs_->second : content_.length(); }

    // ─── Full content (save / buffer/text wire / undo snapshots) ────────

    QString to_qstring() const { return content_.to_qstring(); }
    int     length()    const { return content_.length(); }
    bool    is_empty()  const { return content_.is_empty(); }

    // ─── Widget surface ─────────────────────────────────────────────────
    //
    // What the QPlainTextEdit should display, and where its cursor
    // should sit within that displayed string.  When not narrowed,
    // identical to the full content.  When narrowed, returns only
    // [BEGV, ZV) and the cursor relative to BEGV.

    QString text_for_widget() const {
        if (!narrow_qs_) return content_.to_qstring();
        const int from = narrow_qs_->first;
        const int to   = narrow_qs_->second;
        return content_.to_qstring().mid(from, to - from);
    }

    int cursor_for_widget_qs() const {
        return cursor_qs_ - begv_qs();
    }

private:
    GapBuffer content_;
    int       cursor_qs_ = 0;
    std::optional<std::pair<int,int>> narrow_qs_;
};
