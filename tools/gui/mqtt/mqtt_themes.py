# -*- coding: utf-8 -*-
"""MQTT 客户端界面主题。id 写入 ui.json。"""
from __future__ import annotations

THEMES: dict[str, dict[str, str]] = {
    "light": {
        "id": "light",
        "name": "浅色",
        "bg": "#f4f6f8",
        "panel": "#ffffff",
        "alt": "#eef2f6",
        "border": "#d5dde5",
        "text": "#1f2933",
        "muted": "#6b7785",
        "accent": "#2563eb",
        "accent_fg": "#ffffff",
        "accent_dim": "#e8f0fe",
        "ok": "#15803d",
        "err": "#c01c28",
        "warn": "#b45309",
        "btn": "#ffffff",
        "btn_hover": "#e8eef5",
        "log_bg": "#1e1e1e",
        "log_fg": "#d4d4d4",
        "log_in": "#89d185",
        "log_out": "#79b8ff",
        "log_err": "#f85149",
        "scroll": "#c5ced6",
    },
    "dark": {
        "id": "dark",
        "name": "深色",
        "bg": "#1b1d21",
        "panel": "#252830",
        "alt": "#2e333c",
        "border": "#3d4450",
        "text": "#e6eaf0",
        "muted": "#9aa3b2",
        "accent": "#5b9fd6",
        "accent_fg": "#0b1220",
        "accent_dim": "#243044",
        "ok": "#3dd68c",
        "err": "#f07178",
        "warn": "#e6a23c",
        "btn": "#2e333c",
        "btn_hover": "#3a404c",
        "log_bg": "#12141a",
        "log_fg": "#d4d4d4",
        "log_in": "#89d185",
        "log_out": "#79b8ff",
        "log_err": "#f85149",
        "scroll": "#4a5160",
    },
    "mist": {
        "id": "mist",
        "name": "海雾",
        "bg": "#15202b",
        "panel": "#1c2b3a",
        "alt": "#243647",
        "border": "#35506a",
        "text": "#e8f1f8",
        "muted": "#8eabc2",
        "accent": "#3ecfbf",
        "accent_fg": "#06201c",
        "accent_dim": "#1a3d3a",
        "ok": "#3ecfbf",
        "err": "#ff7b72",
        "warn": "#f0c674",
        "btn": "#243647",
        "btn_hover": "#2d4256",
        "log_bg": "#0f1820",
        "log_fg": "#d4e4ef",
        "log_in": "#7ee0d2",
        "log_out": "#7ec8e8",
        "log_err": "#ff8b82",
        "scroll": "#3d5a73",
    },
    "warm": {
        "id": "warm",
        "name": "暖光",
        "bg": "#f6f0e6",
        "panel": "#fffaf2",
        "alt": "#f0e4d0",
        "border": "#e0d0b6",
        "text": "#3b2f23",
        "muted": "#8a7460",
        "accent": "#b45309",
        "accent_fg": "#fffaf2",
        "accent_dim": "#f5e6d3",
        "ok": "#3f6f3a",
        "err": "#a33b32",
        "warn": "#b45309",
        "btn": "#fffaf2",
        "btn_hover": "#f0e4d0",
        "log_bg": "#2a241c",
        "log_fg": "#f0e6d6",
        "log_in": "#a3d39c",
        "log_out": "#e0c08a",
        "log_err": "#e09088",
        "scroll": "#cbb99a",
    },
}

DEFAULT_THEME = "light"
UI_FONT = "Microsoft YaHei"
UI_SIZE = "10.5pt"
MONO_FONT = "Consolas"
MONO_SIZE = "10.5pt"


def theme_ids() -> list[str]:
    return list(THEMES.keys())


def theme_labels() -> list[str]:
    return [THEMES[k]["name"] for k in THEMES]


def palette(theme_id: str) -> dict[str, str]:
    return dict(THEMES.get(theme_id) or THEMES[DEFAULT_THEME])


def id_from_label(label: str) -> str:
    for k, p in THEMES.items():
        if p["name"] == label:
            return k
    return DEFAULT_THEME


def ui_qfont():
    from PySide6.QtGui import QFont

    f = QFont(UI_FONT)
    f.setPointSizeF(10.5)
    f.setHintingPreference(QFont.HintingPreference.PreferFullHinting)
    f.setStyleStrategy(QFont.StyleStrategy.PreferAntialias)
    return f


def mono_qfont():
    from PySide6.QtGui import QFont

    f = QFont(MONO_FONT)
    f.setPointSizeF(10.5)
    f.setStyleHint(QFont.StyleHint.Monospace)
    f.setFixedPitch(True)
    return f


def stylesheet(theme_id: str) -> str:
    p = palette(theme_id)
    p["ui_font"] = UI_FONT
    p["ui_size"] = UI_SIZE
    p["mono_font"] = MONO_FONT
    p["mono_size"] = MONO_SIZE
    return """
QMainWindow, QDialog {{
    background: {bg};
    color: {text};
    font-family: '{ui_font}';
    font-size: {ui_size};
}}
QWidget {{
    color: {text};
    font-family: '{ui_font}';
    font-size: {ui_size};
}}
QTabWidget::pane {{
    border: 1px solid {border};
    background: {panel};
    top: -1px;
}}
QTabBar::tab {{
    background: {alt};
    color: {muted};
    font-family: '{ui_font}';
    font-size: {ui_size};
    padding: 9px 18px;
    margin-right: 2px;
    border: 1px solid {border};
    border-bottom: none;
    border-top-left-radius: 6px;
    border-top-right-radius: 6px;
}}
QTabBar::tab:selected {{
    background: {panel};
    color: {accent};
    font-weight: bold;
}}
QTabBar::tab:hover:!selected {{
    color: {text};
}}
QPushButton {{
    background: {btn};
    color: {text};
    font-family: '{ui_font}';
    font-size: {ui_size};
    border: 1px solid {border};
    border-radius: 4px;
    padding: 6px 14px;
    min-height: 26px;
}}
QPushButton:hover {{ background: {btn_hover}; }}
QPushButton:disabled {{ color: {muted}; }}
QPushButton#primary {{
    background: {accent};
    color: {accent_fg};
    border: 1px solid {accent};
    font-weight: bold;
}}
QPushButton#primary:hover {{ background: {accent}; }}
QPushButton#primary:disabled {{
    background: {alt};
    color: {muted};
    border-color: {border};
}}
QPushButton#dangerBtn {{
    background: {err};
    color: #ffffff;
    border: 1px solid {err};
    font-weight: bold;
}}
QLineEdit, QComboBox, QSpinBox {{
    background: {panel};
    color: {text};
    font-family: '{ui_font}';
    font-size: {ui_size};
    border: 1px solid {border};
    border-radius: 4px;
    padding: 5px 8px;
    min-height: 26px;
}}
QComboBox QAbstractItemView {{
    background: {panel};
    color: {text};
    selection-background-color: {accent};
    selection-color: {accent_fg};
}}
QPlainTextEdit, QTextEdit {{
    background: {panel};
    color: {text};
    font-family: '{mono_font}';
    font-size: {mono_size};
    border: 1px solid {border};
    border-radius: 4px;
    selection-background-color: {accent};
    selection-color: {accent_fg};
}}
QTreeWidget, QListWidget {{
    background: {panel};
    color: {text};
    font-family: '{ui_font}';
    font-size: {ui_size};
    border: 1px solid {border};
    border-radius: 4px;
    alternate-background-color: {alt};
}}
QScrollArea {{
    background: {panel};
    border: 1px solid {border};
    border-radius: 4px;
}}
QScrollArea > QWidget > QWidget {{ background: {panel}; }}
QHeaderView::section {{
    background: {alt};
    color: {muted};
    font-family: '{ui_font}';
    font-size: {ui_size};
    border: none;
    border-right: 1px solid {border};
    border-bottom: 1px solid {border};
    padding: 6px 8px;
}}
QCheckBox, QRadioButton {{ color: {text}; spacing: 6px; }}
QSplitter::handle {{ background: {border}; }}
QProgressBar {{
    background: {alt};
    border: 1px solid {border};
    border-radius: 4px;
    text-align: center;
    color: {text};
}}
QProgressBar::chunk {{ background: {accent}; border-radius: 3px; }}
QScrollBar:vertical {{
    background: {alt};
    width: 10px;
    margin: 0;
}}
QScrollBar::handle:vertical {{
    background: {scroll};
    min-height: 24px;
    border-radius: 4px;
}}
QFrame#headerCard {{
    background: {panel};
    border: 1px solid {border};
    border-radius: 8px;
}}
QFrame#infoCard {{
    background: {accent_dim};
    border: 1px solid {accent};
    border-radius: 8px;
}}
QFrame#chip {{
    background: {alt};
    border: 1px solid {border};
    border-radius: 6px;
}}
QLabel#chipKey {{ color: {muted}; font-size: 9pt; border: none; }}
QLabel#chipVal {{
    color: {text};
    font-weight: bold;
    font-size: 13pt;
    font-family: '{mono_font}';
    border: none;
}}
QLabel#accentLabel {{ color: {accent}; font-weight: bold; }}
QLabel#mutedLabel {{ color: {muted}; }}
QLabel#hintLabel {{ color: {warn}; }}
QLabel#warnLabel {{ color: {err}; }}
QLabel#versionLabel {{
    color: {accent};
    font-family: '{mono_font}';
    font-size: 16pt;
    font-weight: bold;
    border: none;
}}
QLabel#statusPlain, QLabel#statusOk, QLabel#statusErr, QLabel#statusWait {{
    background: {alt};
    padding: 8px;
    border-radius: 4px;
    border: 1px solid {border};
}}
QLabel#statusPlain {{ color: {text}; }}
QLabel#statusOk {{ color: {ok}; }}
QLabel#statusErr {{ color: {err}; }}
QLabel#statusWait {{ color: {warn}; }}
QTextEdit#logPane {{
    background: {log_bg};
    color: {log_fg};
    font-family: '{mono_font}';
    font-size: {mono_size};
    border: 1px solid {border};
}}
QFrame#vsep {{
    background: {border};
    max-width: 1px;
    min-width: 1px;
}}
QMenu {{
    background: {panel};
    color: {text};
    border: 1px solid {border};
}}
QMenu::item:selected {{ background: {accent}; color: {accent_fg}; }}
""".format(**p)
