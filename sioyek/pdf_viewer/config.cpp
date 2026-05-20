#include <vector>
#include <string>
#include "config.h"
#include "path.h"
#include <QString>

// Stub globals — extracted from original config.cpp with their default values.
// These will eventually be driven by the socket control layer.

bool TOUCH_MODE = false;

bool ADJUST_ANNOTATION_COLORS_FOR_DARK_MODE = true;
bool ALPHABETIC_LINK_TAGS = false;
bool ALWAYS_COPY_SELECTED_TEXT = false;
std::wstring ANNOTATIONS_DIR_PATH = L"";
float BACKGROUND_COLOR[3] = { 0.97f, 0.97f, 0.97f };
bool BACKGROUND_PIXEL_FIX = false;
std::wstring BACK_RECT_HOLD_COMMAND = L"goto_mark";
std::wstring BACK_RECT_TAP_COMMAND = L"prev_state";
float BLACK_COLOR[3] = { 0.0f, 0.0f, 0.0f };
float BOOKMARK_RECT_SIZE = 8.0f;
unsigned int CACHE_INVALID_MILIES = 1000;
bool CASE_SENSITIVE_SEARCH = false;
bool CREATE_TABLE_OF_CONTENTS_IF_NOT_EXISTS = true;
float CUSTOM_BACKGROUND_COLOR[3] = { 0.18f, 0.204f, 0.251f };
float CUSTOM_COLOR_CONTRAST = 0.5f;
float CUSTOM_COLOR_MODE_EMPTY_BACKGROUND_COLOR[3] = { 0.0f, 0.0f, 0.0f };
float CUSTOM_TEXT_COLOR[3] = { 0.847f, 0.871f, 0.914f };
float DARK_MODE_BACKGROUND_COLOR[3] = { 0.0f, 0.0f, 0.0f };
float DARK_MODE_CONTRAST = 0.8f;
int DATABASE_VERSION = 2;
bool DEBUG_DISPLAY_FREEHAND_POINTS = false;
bool DEBUG_SMOOTH_FREEHAND_DRAWINGS = true;
float DEFAULT_LINK_HIGHLIGHT_COLOR[3] = { 0.0f, 0.0f, 1.0f };
float DEFAULT_SEARCH_HIGHLIGHT_COLOR[3] = { 0.0f, 1.0f, 0.0f };
float DEFAULT_SYNCTEX_HIGHLIGHT_COLOR[3] = { 1.0f, 0.0f, 0.0f };
float DEFAULT_TEXT_HIGHLIGHT_COLOR[3] = { 1.0f, 1.0f, 0.0 };
float DEFAULT_VERTICAL_LINE_COLOR[4] = { 0.0f, 0.0f, 0.0f, 0.1f };
float DISPLAY_RESOLUTION_SCALE = -1;
std::wstring EPUB_CSS = L"";
float EPUB_FONT_SIZE = 14;
float EPUB_HEIGHT = 700;
float EPUB_WIDTH = 400;
bool EXACT_HIGHLIGHT_SELECT = true;
float FASTREAD_OPACITY = 0.5f;
float FIT_TO_PAGE_WIDTH_RATIO = 0.75;
bool FORCE_CUSTOM_LINE_ALGORITHM = false;
std::wstring FORWARD_RECT_HOLD_COMMAND = L"set_mark";
std::wstring FORWARD_RECT_TAP_COMMAND = L"next_state";
float FREETEXT_BOOKMARK_COLOR[3] = { 0.0f, 0.0f, 0.0f };
float FREETEXT_BOOKMARK_FONT_SIZE = 8.0f;
float GAMMA = 1.0f;
std::wstring GOOGLE_SCHOLAR_ADDRESS = L"";
bool HIDE_OVERLAPPING_LINK_LABELS = true;
float HIDE_SYNCTEX_HIGHLIGHT_TIMEOUT = 1.0f;
float HIGHLIGHT_COLORS[26 * 3] = { \
0.94, 0.64, 1.00, \
0.00, 0.46, 0.86, \
0.60, 0.25, 0.00, \
0.30, 0.00, 0.36, \
0.10, 0.10, 0.10, \
0.00, 0.36, 0.19, \
0.17, 0.81, 0.28, \
1.00, 0.80, 0.60, \
0.50, 0.50, 0.50, \
0.58, 1.00, 0.71, \
0.56, 0.49, 0.00, \
0.62, 0.80, 0.00, \
0.76, 0.00, 0.53, \
0.00, 0.20, 0.50, \
1.00, 0.64, 0.02, \
1.00, 0.66, 0.73, \
0.26, 0.40, 0.00, \
1.00, 0.00, 0.06, \
0.37, 0.95, 0.95, \
0.00, 0.60, 0.56, \
0.88, 1.00, 0.40, \
0.45, 0.04, 1.00, \
0.60, 0.00, 0.00, \
1.00, 1.00, 0.50, \
1.00, 1.00, 0.00, \
1.00, 0.31, 0.02
};
float HIGHLIGHT_DELETE_THRESHOLD = 0.1f;
bool HORIZONTAL_SCROLL_PAST_PAGE_ENDS = false;
bool INVERTED_PRESERVED_IMAGE_COLORS = false;
bool INVERT_SELECTED_TEXT = false;
float KEYBOARD_SELECTED_TAG_BACKGROUND_COLRO[] = { 0.0f , 0.0f, 0.0f, 1.0f };
float KEYBOARD_SELECTED_TAG_TEXT_COLOR[] = { 1.0f , 1.0f, 1.0f, 1.0f };
float KEYBOARD_SELECT_BACKGROUND_COLOR[] = { 0.9f , 0.75f, 0.0f, 1.0f };
int KEYBOARD_SELECT_FONT_SIZE = 20;
float KEYBOARD_SELECT_TEXT_COLOR[] = { 0.0f , 0.0f, 0.5f, 1.0f };
std::wstring LIBGEN_ADDRESS = L"";
bool LIGHTEN_COLORS_WHEN_EMBEDDING_ANNOTATIONS = true;
bool LINEAR_TEXTURE_FILTERING = false;
int MAX_CREATED_TABLE_OF_CONTENTS_SIZE = 5000;
int MAX_PENDING_REQUESTS = 31;
std::wstring MIDDLE_LEFT_RECT_HOLD_COMMAND = L"";
std::wstring MIDDLE_LEFT_RECT_TAP_COMMAND = L"";
std::wstring MIDDLE_RIGHT_RECT_HOLD_COMMAND = L"";
std::wstring MIDDLE_RIGHT_RECT_TAP_COMMAND = L"overview_definition";
float MOVE_SCREEN_PERCENTAGE = 0.5f;
bool NUMERIC_TAGS = false;
int NUM_H_SLICES = 1;
int NUM_PRERENDERED_NEXT_SLIDES = 1;
int NUM_PRERENDERED_PREV_SLIDES = 0;
int NUM_V_SLICES = 5;
bool OPEN_LAST_FILE_ON_STARTUP = true;
float OVERVIEW_OFFSET[2] = { 0.0f, 0.0f };
float OVERVIEW_SIZE[2] = { 0.8f, 0.4f };
int PAGE_PADDINGS = 0;
float PAGE_SEPARATOR_COLOR[3] = { 0.9f, 0.9f, 0.9f };
float PAGE_SEPARATOR_WIDTH = 0.0f;
float PAGE_SPACE_X = 10.0f;
float PAGE_SPACE_Y = 10.0f;
bool PAPER_DOWNLOAD_AUTODETECT_PAPER_NAME = true;
int PRERENDERED_PAGE_COUNT = 0;
bool PRERENDER_NEXT_PAGE = true;
bool PRESERVE_IMAGE_COLORS = false;
bool REAL_PAGE_SEPARATION = false;
bool RECTO_VERSO_ADJUSTMENT = false;
bool RENDER_FREETEXT_BORDERS = false;
float RULER_COLOR[3] = { 0.5f, 0.5f, 0.5f };
std::wstring RULER_DISPLAY_MODE = L"underline";
float RULER_MARKER_COLOR[3] = { 1.0f, 0.0f, 0.0f };
bool RULER_MODE = true;
float RULER_PADDING = 1.0f;
int RULER_UNDERLINE_PIXEL_WIDTH = 2;
float RULER_X_PADDING = 5.0f;
bool SAME_WIDTH = false;
bool SCROLL_PAST_DOCUMENT_ENDS = true;
std::wstring SHARED_DATABASE_PATH = L"";
bool SHOULD_DRAW_UNRENDERED_PAGES = false;
bool SHOULD_HIGHLIGHT_LINKS = false;
bool SHOULD_HIGHLIGHT_UNSELECTED_SEARCH = false;
bool SHOULD_RENDER_PDF_ANNOTATIONS = true;
bool SLICED_RENDERING = true;
float SMALL_PIXMAP_SCALE = 0.75f;
bool SMARTCASE_SEARCH = false;
float STATUS_BAR_COLOR[3] = { 0.0f, 0.0f, 0.0f };
int STATUS_BAR_FONT_SIZE = -1;
float STATUS_BAR_TEXT_COLOR[3] = { 1.0f, 1.0f, 1.0f };
std::wstring STATUS_FONT_FACE_NAME = L"";
float STRIKE_LINE_WIDTH = 1.0f;
bool SUPER_FAST_SEARCH = true;
std::wstring TAG_FONT_FACE = L"";
std::wstring TOP_CENTER_HOLD_COMMAND = L"toggle_dark_mode";
std::wstring TOP_CENTER_TAP_COMMAND = L"show_touch_main_menu";
float UI_BACKGROUND_COLOR[3] = { 0.0f, 0.0f, 0.0f };
std::wstring UI_FONT_FACE_NAME = L"";
float UI_SELECTED_BACKGROUND_COLOR[3] = { 1.0f, 1.0f, 1.0f };
float UI_SELECTED_TEXT_COLOR[3] = { 0.0f, 0.0f, 0.0f };
float UI_TEXT_COLOR[3] = { 1.0f, 1.0f, 1.0f };
float UNSELECTED_SEARCH_HIGHLIGHT_COLOR[3] = { 0.0f, 0.5f, 0.5f };
bool VERBOSE = true;
float VERTICAL_MOVE_AMOUNT = 1.0f;
std::wstring VISUAL_MARK_NEXT_HOLD_COMMAND = L"";
std::wstring VISUAL_MARK_NEXT_TAP_COMMAND = L"";
std::wstring VISUAL_MARK_PREV_HOLD_COMMAND = L"";
std::wstring VISUAL_MARK_PREV_TAP_COMMAND = L"";
float ZOOM_INC_FACTOR = 1.2f;
QString global_font_family;
Path last_opened_file_address_path(L"");
Path shader_path(L"");
