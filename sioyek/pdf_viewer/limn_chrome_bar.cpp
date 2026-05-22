#include "limn_chrome_bar.h"

#include <QHBoxLayout>
#include <QVBoxLayout>

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

    // ── minimal styling so the two rows are visually distinct ───────
    // Modeline: muted background; echo: lighter. Stylesheets keep us
    // independent of Qt's platform theme.
    setStyleSheet(R"(
        QLabel#modeline_seg {
            background: #2c2c2c; color: #d0d0d0;
            padding: 1px 4px;  font-size: 11px;
        }
        QLabel#echo_line {
            background: #1a1a1a; color: #e8e8e8;
            padding: 2px 8px;  font-size: 12px;
            font-family: "Menlo","Consolas","Courier New",monospace;
        }
    )");

    refresh_echo_line();
}

void LimnChromeBar::set_modeline(const QString& left,
                                 const QString& middle,
                                 const QString& right) {
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
    refresh_echo_line();
}

void LimnChromeBar::refresh_echo_line() {
    if (minibuffer_open_) {
        echo_line_->setText(minibuffer_prompt_ + minibuffer_text_);
    } else {
        echo_line_->setText(echo_text_);
    }
}
