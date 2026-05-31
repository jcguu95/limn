#pragma once
//
// LimnChromeBar — Qt widget that renders the three chrome primitives
// (modeline / echo area / minibuffer) per SPEC §1.2 / §5.4–§5.6.
//
// Layout (single QWidget, fixed-height rows):
//
//   ┌────────────────────────────────────────────────┐
//   │ modeline-left │   modeline-middle │ modeline-r │   ← row 1 (modeline)
//   ├────────────────────────────────────────────────┤
//   │ /hello (when minibuffer open) OR echo text     │   ← row 2 (echo/mb)
//   ├────────────────────────────────────────────────┤
//   │ vertico candidates (at most 10 rows)           │   ← row 3+ (fuzzy only)
//   └────────────────────────────────────────────────┘
//
// Row 2 is shared between echo area and minibuffer (they never both
// occupy the line in Emacs either). LimnCommand drives the state and
// calls refresh_*() to update the visible labels.
//
#include <QWidget>
#include <QLabel>
#include <QStringList>

class LimnChromeBar : public QWidget {
    Q_OBJECT
public:
    explicit LimnChromeBar(QWidget* parent = nullptr);

    // SPEC §5.6 modeline/set
    void set_modeline(const QString& left,
                       const QString& middle,
                       const QString& right);

    // SPEC §5.5 message/echo (and message/clear with empty text)
    void set_echo(const QString& text);

    // SPEC §5.4 minibuffer state. When `open` is true the echo line is
    // commandeered to render `<prompt><text>`; when false the line
    // reverts to whatever set_echo last placed there.
    void set_minibuffer(bool open,
                         const QString& prompt,
                         const QString& text);

    // §3 fuzzy selector: render vertical candidate list below the
    // minibuffer line.  candidates = visible window, idx = highlighted
    // row (0-based relative), total = total filtered count.
    void set_candidates(const QStringList& candidates,
                        int idx, int total);

    // Route B: apply a font-family to the echo/minibuffer line at runtime.
    // Called by LimnCommand::cmd_display_sync_faces when the "minibuffer"
    // face carries a non-empty :family field.  Empty string → falls back to
    // the value of the `status_font` config variable (or the embedded
    // JetBrainsMono when that is also unset).
    void apply_face_font(const QString& family);

private:
    void rebuild_stylesheet(const QString& font_family);
    void refresh_echo_line();
    void refresh_candidates();

    // Modeline labels
    QLabel* modeline_left_;
    QLabel* modeline_middle_;
    QLabel* modeline_right_;

    // Echo / minibuffer shared line
    QLabel* echo_line_;

    // §3 fuzzy selector: vertical candidate labels (up to 10)
    QVector<QLabel*> candidate_labels_;

    // Source-of-truth state (mirrors LimnCommand's; this widget owns the
    // resolved rendered text)
    QString echo_text_;
    bool    minibuffer_open_ = false;
    QString minibuffer_prompt_;
    QString minibuffer_text_;

    // §3 fuzzy selector state
    QStringList candidates_;
    int         candidate_idx_   = 0;
    int         candidate_total_ = 0;
};
