#include "limn_chrome_bar.h"

#include <QHBoxLayout>
#include <QVBoxLayout>

// Forward-declare font helpers from utils.cpp.  We avoid #include "utils.h"
// here because that header transitively pulls in mupdf/fitz.h and other heavy
// dependencies that have no place in a thin Qt widget.
QString get_status_font_face_name();

LimnChromeBar::LimnChromeBar(QWidget* parent) : QWidget(parent) {
    setObjectName("LimnChromeBar");
    setFocusPolicy(Qt::NoFocus);
    // Keep the bar short: two rows × ~18px = 36px. The OpenGL viewport
    // takes everything else.
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);

    // ── modeline labels ──────────────────────────────────────────────
    modeline_left_   = new QLabel(this);
    modeline_middle_ = new QLabel(this);
    modeline_right_  = new QLabel(this);
    for (QLabel* l : {modeline_left_, modeline_middle_, modeline_right_}) {
        l->setObjectName(QStringLiteral("modeline_seg"));
        l->setTextInteractionFlags(Qt::NoTextInteraction);
    }
    modeline_left_->setAlignment(Qt::AlignVCenter | Qt::AlignLeft);
    modeline_middle_->setAlignment(Qt::AlignVCenter | Qt::AlignHCenter);
    modeline_right_->setAlignment(Qt::AlignVCenter | Qt::AlignRight);

    auto* modeline_row = new QHBoxLayout();
    modeline_row->setContentsMargins(6, 0, 6, 0);
    modeline_row->setSpacing(8);
    modeline_row->addWidget(modeline_left_,   1);
    modeline_row->addWidget(modeline_middle_, 1);
    modeline_row->addWidget(modeline_right_,  1);

    // ── echo / minibuffer line ──────────────────────────────────────
    echo_line_ = new QLabel(this);
    echo_line_->setObjectName(QStringLiteral("echo_line"));
    echo_line_->setAlignment(Qt::AlignVCenter | Qt::AlignLeft);

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);
    root->addLayout(modeline_row);
    root->addWidget(echo_line_);

    // ── §3 fuzzy selector: candidate labels (up to 10, created ahead) ──
    for (int i = 0; i < 10; ++i) {
        QLabel* lbl = new QLabel(this);
        lbl->setObjectName(QStringLiteral("candidate_row"));
        lbl->setAlignment(Qt::AlignVCenter | Qt::AlignLeft);
        lbl->hide();
        root->addWidget(lbl);
        candidate_labels_.append(lbl);
    }

    // ── minimal styling so the two rows are visually distinct ───────
    // Route A: use the `status_font` config value (falls back to the embedded
    // JetBrainsMono when unset) rather than a hard-coded OS-specific cascade
    // like "Menlo","Consolas","Courier New".
    rebuild_stylesheet(get_status_font_face_name());

    refresh_echo_line();
}

void LimnChromeBar::set_modeline(const QString& left,
                                 const QString& middle,
                                 const QString& right) {
    fprintf(stderr,
            "[limn-modeline] set_modeline L=%s | M=%s | R=%s\n",
            qPrintable(left), qPrintable(middle), qPrintable(right));
    modeline_left_->setText(left);
    modeline_middle_->setText(middle);
    modeline_right_->setText(right);
}

void LimnChromeBar::set_echo(const QString& text) {
    echo_text_ = text;
    refresh_echo_line();
}

void LimnChromeBar::set_minibuffer(bool open,
                                   const QString& prompt,
                                   const QString& text) {
    minibuffer_open_   = open;
    minibuffer_prompt_ = prompt;
    minibuffer_text_   = text;
    // §3：close 時清除候選
    if (!open) {
        candidates_.clear();
        candidate_idx_   = 0;
        candidate_total_ = 0;
        refresh_candidates();
    }
    refresh_echo_line();
}

// §3 fuzzy selector: draw vertical candidate list
void LimnChromeBar::set_candidates(const QStringList& candidates,
                                    int idx, int total) {
    candidates_       = candidates;
    candidate_idx_    = idx;
    candidate_total_  = total;
    refresh_candidates();
}

void LimnChromeBar::refresh_candidates() {
    const int vis_count = candidates_.size();
    for (int i = 0; i < candidate_labels_.size(); ++i) {
        if (i < vis_count) {
            QString label_text = candidates_.at(i);
            if (i == candidate_idx_) {
                // 高亮選中行：加上「>」前綴與不同背景
                label_text = QString("> %1   [%2/%3]")
                    .arg(label_text)
                    .arg(i + 1)
                    .arg(candidate_total_);
                candidate_labels_[i]->setStyleSheet(
                    QStringLiteral("QLabel#candidate_row {"
                        "background: #3a5a8c; color: #ffffff;"
                        "padding: 1px 8px; font-size: 11px; }"));
            } else {
                label_text = QString("  %1").arg(label_text);
                candidate_labels_[i]->setStyleSheet(
                    QStringLiteral("QLabel#candidate_row {"
                        "background: #2a2a2a; color: #c0c0c0;"
                        "padding: 1px 8px; font-size: 11px; }"));
            }
            candidate_labels_[i]->setText(label_text);
            candidate_labels_[i]->show();
        } else {
            candidate_labels_[i]->hide();
        }
    }
    // trigger layout refresh
    updateGeometry();
    if (parentWidget())
        parentWidget()->update();
}

void LimnChromeBar::refresh_echo_line() {
    if (minibuffer_open_) {
        echo_line_->setText(minibuffer_prompt_ + minibuffer_text_);
    } else {
        echo_line_->setText(echo_text_);
    }
}

// ── Route A/B font helpers ───────────────────────────────────────────────

void LimnChromeBar::rebuild_stylesheet(const QString& font_family) {
    // Build the font-family CSS fragment.  An empty family string means "let
    // Qt pick the platform monospace default" — we emit no font-family rule so
    // the OS cascade applies rather than an empty/broken declaration.
    const QString ff_rule = font_family.isEmpty()
        ? QString()
        : QString("font-family: \"%1\", monospace;").arg(font_family);

    // v0.39.13: bumped modeline_seg's font-size + padding + min-height so
    // the row is unambiguously visible even when all three labels are
    // empty (Qt's QHBoxLayout was collapsing the row to ~0px on first
    // open before any modeline/set call landed — users couldn't tell
    // the row existed at all).
    setStyleSheet(QString(R"(
        QLabel#modeline_seg {
            background: #3a3a3a; color: #f0f0f0;
            padding: 3px 6px;  font-size: 12px;
            min-height: 16px;
        }
        QLabel#echo_line {
            background: #1a1a1a; color: #e8e8e8;
            padding: 2px 8px;  font-size: 12px;
            %1
        }
        QLabel#candidate_row {
            background: #2a2a2a; color: #c0c0c0;
            padding: 1px 8px;  font-size: 11px;
            %1
        }
    )").arg(ff_rule));
}

// Route B entry-point: called by LimnCommand after display/sync-faces
// resolves a :family attribute on the "minibuffer" face.
void LimnChromeBar::apply_face_font(const QString& family) {
    // If the face table specified an explicit family, use it; otherwise fall
    // back to the `status_font` config value (which itself falls back to the
    // embedded JetBrainsMono when unconfigured).
    const QString resolved = family.isEmpty() ? get_status_font_face_name() : family;
    rebuild_stylesheet(resolved);
}
