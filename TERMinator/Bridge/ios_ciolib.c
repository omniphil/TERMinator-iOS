/**
 * iOS ciolib implementation
 *
 * Provides stub implementations of ciolib functions for iOS.
 * Instead of rendering directly, this stores terminal state in a buffer
 * that can be read via Swift for rendering in SwiftUI.
 */

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#include "safe_math.h"
#include "ios_ciolib.h"
#include "ciolib.h"
#include "vidmodes.h"

// Maximum terminal dimensions to prevent unreasonable allocations
#define MAX_TERMINAL_WIDTH  1000
#define MAX_TERMINAL_HEIGHT 1000

// Global ciolib variables that must be defined
struct text_info cio_textinfo;
cioapi_t cio_api;
int _wscroll = 1;
int directvideo = 0;
int hold_update = 0;
int puttext_can_move = 0;
int ciolib_reaper = 0;
const char *ciolib_appname = "TERMinator";
double ciolib_initial_scaling = 1.0;
int ciolib_initial_mode = C80;
enum ciolib_scaling ciolib_initial_scaling_type = CIOLIB_SCALING_INTERNAL;
const void *ciolib_initial_icon = NULL;
size_t ciolib_initial_icon_width = 0;
const char *ciolib_initial_program_name = "TERMinator";
const char *ciolib_initial_program_class = "TERMinator";
bool ciolib_swap_mouse_butt45 = false;
uint32_t ciolib_fg = 7;  // Light gray
uint32_t ciolib_bg = 0;  // Black

// Font data from allfonts.c (extern - actual data is in allfonts.c)
extern struct conio_font_data_struct conio_fontdata[257];

// Declared in syncterm_ios.c — saves one line into the scrollback ring buffer.
extern void scrollback_save_line(const struct vmem_cell *line, int width);

// iOS-specific screen state
static struct ios_screen_state {
    struct vmem_cell *screen;
    int width;
    int height;
    int cursor_x;
    int cursor_y;
    int cursor_visible;
    int cursor_type;
    uint8_t current_attr;
    uint32_t fg_color;
    uint32_t bg_color;
    int dirty;
    // Deferred wrap: cursor at last column, wrap on next printable char
    int pending_wrap;
    // Dirty region tracking for partial redraws
    int dirty_min_x;
    int dirty_max_x;
    int dirty_min_y;
    int dirty_max_y;
    pthread_mutex_t mutex;
    uint32_t palette[16];
} ios_state = {
    .screen = NULL,
    .width = 80,
    .height = 25,
    .cursor_x = 1,
    .cursor_y = 1,
    .cursor_visible = 1,
    .cursor_type = _NORMALCURSOR,
    .current_attr = 7,
    .fg_color = 7,
    .bg_color = 0,
    .dirty = 0,
    .pending_wrap = 0,
    .dirty_min_x = 0,
    .dirty_max_x = 0,
    .dirty_min_y = 0,
    .dirty_max_y = 0,
    .palette = {
        0x000000, // Black
        0x0000AA, // Blue
        0x00AA00, // Green
        0x00AAAA, // Cyan
        0xAA0000, // Red
        0xAA00AA, // Magenta
        0xAA5500, // Brown
        0xAAAAAA, // Light Gray
        0x555555, // Dark Gray
        0x5555FF, // Light Blue
        0x55FF55, // Light Green
        0x55FFFF, // Light Cyan
        0xFF5555, // Light Red
        0xFF55FF, // Light Magenta
        0xFFFF55, // Yellow
        0xFFFFFF  // White
    }
};

// Forward declarations
static void ios_clreol(void);
static int ios_puttext(int sx, int sy, int ex, int ey, void *buf);
static int ios_vmem_puttext(int sx, int sy, int ex, int ey, struct vmem_cell *buf);
static int ios_gettext(int sx, int sy, int ex, int ey, void *buf);
static int ios_vmem_gettext(int sx, int sy, int ex, int ey, struct vmem_cell *buf);
static void ios_textattr(int attr);
static int ios_kbhit(void);
static int ios_kbwait(int timeout);
static void ios_delay(long ms);
static int ios_wherex(void);
static int ios_wherey(void);
static int ios_putch(int c);
static void ios_gotoxy(int x, int y);
static void ios_clrscr(void);
static void ios_gettextinfo(struct text_info *info);
static void ios_setcursortype(int type);
static int ios_getch(void);
static int ios_getche(void);
static void ios_beep(void);
static void ios_highvideo(void);
static void ios_lowvideo(void);
static void ios_brightbackground(void);
static void ios_reversevideo(void);
static void ios_normvideo(void);
static void ios_textmode(int mode);
static int ios_ungetch(int ch);
static int ios_movetext(int sx, int sy, int ex, int ey, int dx, int dy);
static void ios_wscroll(void);
static void ios_window(int sx, int sy, int ex, int ey);
static void ios_delline(void);
static void ios_insline(void);
static void ios_textbackground(int color);
static void ios_textcolor(int color);
static void ios_settitle(const char *title);
static void ios_setname(const char *name);
static int ios_setfont(int font, int force, int font_num);
static int ios_getfont(int font_num);
static void ios_setvideoflags(int flags);
static int ios_getvideoflags(void);
static int ios_setpalette(uint32_t entry, uint16_t r, uint16_t g, uint16_t b);
static int ios_attr2palette(uint8_t attr, uint32_t *fg, uint32_t *bg);

// Input buffer for keyboard input from Swift
#define INPUT_BUFFER_SIZE 256
static unsigned char input_buffer[INPUT_BUFFER_SIZE];
static int input_head = 0;
static int input_tail = 0;
static pthread_mutex_t input_mutex = PTHREAD_MUTEX_INITIALIZER;

// ============================================================================
// MARK: - Public Functions for Swift Access
// ============================================================================

int ios_ciolib_get_screen_width(void) {
    return ios_state.width;
}

int ios_ciolib_get_screen_height(void) {
    return ios_state.height;
}

int ios_ciolib_get_cursor_x(void) {
    return ios_state.cursor_x;
}

int ios_ciolib_get_cursor_y(void) {
    return ios_state.cursor_y;
}

bool ios_ciolib_is_cursor_visible(void) {
    return ios_state.cursor_visible && ios_state.cursor_type != _NOCURSOR;
}

bool ios_ciolib_is_dirty(void) {
    return ios_state.dirty != 0;
}

void ios_ciolib_clear_dirty(void) {
    ios_state.dirty = 0;
    // Reset dirty region to invalid state
    ios_state.dirty_min_x = ios_state.width;
    ios_state.dirty_max_x = 0;
    ios_state.dirty_min_y = ios_state.height;
    ios_state.dirty_max_y = 0;
}

// Get dirty region bounds (returns false if no dirty region, true if valid)
bool ios_ciolib_get_dirty_region(int32_t *min_x, int32_t *min_y, int32_t *max_x, int32_t *max_y) {
    if (!ios_state.dirty) {
        return false;
    }
    *min_x = ios_state.dirty_min_x;
    *min_y = ios_state.dirty_min_y;
    *max_x = ios_state.dirty_max_x;
    *max_y = ios_state.dirty_max_y;
    return true;
}

// Mark a cell as dirty and expand dirty region
static inline void mark_cell_dirty(int x, int y) {
    ios_state.dirty = 1;
    if (x < ios_state.dirty_min_x) ios_state.dirty_min_x = x;
    if (x > ios_state.dirty_max_x) ios_state.dirty_max_x = x;
    if (y < ios_state.dirty_min_y) ios_state.dirty_min_y = y;
    if (y > ios_state.dirty_max_y) ios_state.dirty_max_y = y;
}

// Mark a rectangular region as dirty
static inline void mark_region_dirty(int x1, int y1, int x2, int y2) {
    ios_state.dirty = 1;
    if (x1 < ios_state.dirty_min_x) ios_state.dirty_min_x = x1;
    if (x2 > ios_state.dirty_max_x) ios_state.dirty_max_x = x2;
    if (y1 < ios_state.dirty_min_y) ios_state.dirty_min_y = y1;
    if (y2 > ios_state.dirty_max_y) ios_state.dirty_max_y = y2;
}

// Mark entire screen as dirty
static inline void mark_screen_dirty(void) {
    ios_state.dirty = 1;
    ios_state.dirty_min_x = 0;
    ios_state.dirty_max_x = ios_state.width - 1;
    ios_state.dirty_min_y = 0;
    ios_state.dirty_max_y = ios_state.height - 1;
}

struct vmem_cell* ios_ciolib_get_screen_buffer(void) {
    return ios_state.screen;
}

void ios_ciolib_lock(void) {
    pthread_mutex_lock(&ios_state.mutex);
}

void ios_ciolib_unlock(void) {
    pthread_mutex_unlock(&ios_state.mutex);
}

uint32_t* ios_ciolib_get_palette(void) {
    return ios_state.palette;
}

// Push keyboard input from Swift
void ios_ciolib_push_input(unsigned char c) {
    pthread_mutex_lock(&input_mutex);
    int next = (input_head + 1) % INPUT_BUFFER_SIZE;
    if (next != input_tail) {
        input_buffer[input_head] = c;
        input_head = next;
    }
    pthread_mutex_unlock(&input_mutex);
}

void ios_ciolib_push_input_buffer(const unsigned char *buf, int len) {
    // Validate parameters - reject NULL buffer or negative/zero length
    if (buf == NULL || len <= 0) {
        return;
    }

    pthread_mutex_lock(&input_mutex);
    for (int i = 0; i < len; i++) {
        int next = (input_head + 1) % INPUT_BUFFER_SIZE;
        if (next == input_tail) break;
        input_buffer[input_head] = buf[i];
        input_head = next;
    }
    pthread_mutex_unlock(&input_mutex);
}

// ============================================================================
// MARK: - Implementation Functions
// ============================================================================

static void ios_clreol(void) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.pending_wrap = 0;
    int y = ios_state.cursor_y - 1;
    int x = ios_state.cursor_x - 1;
    if (y >= 0 && y < ios_state.height && x >= 0 && ios_state.screen) {
        for (int i = x; i < ios_state.width; i++) {
            int idx;
            if (!validate_index(i, y, ios_state.width, ios_state.height, &idx)) {
                break;
            }
            ios_state.screen[idx].ch = ' ';
            ios_state.screen[idx].legacy_attr = ios_state.current_attr;
            ios_state.screen[idx].fg = ios_state.fg_color;
            ios_state.screen[idx].bg = ios_state.bg_color;
            ios_state.screen[idx].font = 0;
        }
        mark_region_dirty(x, y, ios_state.width - 1, y);
    }
    pthread_mutex_unlock(&ios_state.mutex);
}

static int ios_puttext(int sx, int sy, int ex, int ey, void *buf) {
    if (!buf) return 0;

    int width, height;
    if (!validate_rect_dims(sx, sy, ex, ey, &width, &height)) {
        return 0;
    }

    unsigned char *src = (unsigned char *)buf;

    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int screen_x = sx - 1 + x;
                int screen_y = sy - 1 + y;

                int idx;
                if (!validate_index(screen_x, screen_y, ios_state.width,
                                   ios_state.height, &idx)) {
                    continue;
                }

                int src_idx;
                if (!validate_index(x, y, width, height, &src_idx)) {
                    continue;
                }

                int src_offset;
                if (!safe_mult_int(src_idx, 2, &src_offset)) {
                    continue;
                }

                int area;
                if (!safe_mult_int(width, height, &area)) {
                    continue;
                }
                int buf_size;
                if (!safe_mult_int(area, 2, &buf_size)) {
                    continue;
                }
                if (src_offset < 0 || src_offset + 1 >= buf_size) {
                    continue;
                }

                ios_state.screen[idx].ch = src[src_offset];
                ios_state.screen[idx].legacy_attr = src[src_offset + 1];
            }
        }
        mark_region_dirty(sx - 1, sy - 1, ex - 1, ey - 1);
    }
    pthread_mutex_unlock(&ios_state.mutex);
    return 1;
}

static int ios_vmem_puttext(int sx, int sy, int ex, int ey, struct vmem_cell *buf) {
    if (!buf) return 0;

    int width, height;
    if (!validate_rect_dims(sx, sy, ex, ey, &width, &height)) {
        return 0;
    }

    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int screen_x = sx - 1 + x;
                int screen_y = sy - 1 + y;

                int idx;
                if (!validate_index(screen_x, screen_y, ios_state.width,
                                   ios_state.height, &idx)) {
                    continue;
                }

                int src_idx;
                if (!validate_index(x, y, width, height, &src_idx)) {
                    continue;
                }

                ios_state.screen[idx] = buf[src_idx];
            }
        }
        mark_region_dirty(sx - 1, sy - 1, ex - 1, ey - 1);
    }
    pthread_mutex_unlock(&ios_state.mutex);
    return 1;
}

static int ios_gettext(int sx, int sy, int ex, int ey, void *buf) {
    if (!buf) return 0;

    int width, height;
    if (!validate_rect_dims(sx, sy, ex, ey, &width, &height)) {
        return 0;
    }

    unsigned char *dst = (unsigned char *)buf;

    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int screen_x = sx - 1 + x;
                int screen_y = sy - 1 + y;

                int idx;
                if (!validate_index(screen_x, screen_y, ios_state.width,
                                   ios_state.height, &idx)) {
                    continue;
                }

                int dst_idx;
                if (!validate_index(x, y, width, height, &dst_idx)) {
                    continue;
                }

                int dst_offset;
                if (!safe_mult_int(dst_idx, 2, &dst_offset)) {
                    continue;
                }

                int area;
                if (!safe_mult_int(width, height, &area)) {
                    continue;
                }
                int buf_size;
                if (!safe_mult_int(area, 2, &buf_size)) {
                    continue;
                }
                if (dst_offset < 0 || dst_offset + 1 >= buf_size) {
                    continue;
                }

                dst[dst_offset] = ios_state.screen[idx].ch;
                dst[dst_offset + 1] = ios_state.screen[idx].legacy_attr;
            }
        }
    }
    pthread_mutex_unlock(&ios_state.mutex);
    return 1;
}

static int ios_vmem_gettext(int sx, int sy, int ex, int ey, struct vmem_cell *buf) {
    if (!buf) return 0;

    int width, height;
    if (!validate_rect_dims(sx, sy, ex, ey, &width, &height)) {
        return 0;
    }

    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int screen_x = sx - 1 + x;
                int screen_y = sy - 1 + y;

                int idx;
                if (!validate_index(screen_x, screen_y, ios_state.width,
                                   ios_state.height, &idx)) {
                    continue;
                }

                int dst_idx;
                if (!validate_index(x, y, width, height, &dst_idx)) {
                    continue;
                }

                buf[dst_idx] = ios_state.screen[idx];
            }
        }
    }
    pthread_mutex_unlock(&ios_state.mutex);
    return 1;
}

static void ios_textattr(int attr) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.current_attr = (uint8_t)attr;
    ios_state.fg_color = attr & 0x0F;
    // Allow 4 bits for background (0-15) to support iCE colors/bright backgrounds
    ios_state.bg_color = (attr >> 4) & 0x0F;
    pthread_mutex_unlock(&ios_state.mutex);
}

static int ios_kbhit(void) {
    pthread_mutex_lock(&input_mutex);
    int has_data = (input_head != input_tail);
    pthread_mutex_unlock(&input_mutex);
    return has_data;
}

static int ios_kbwait(int timeout) {
    int elapsed = 0;
    while (elapsed < timeout || timeout == 0) {
        if (ios_kbhit()) return 1;
        usleep(10000); // 10ms
        elapsed += 10;
        if (timeout == 0) break;
    }
    return ios_kbhit();
}

static void ios_delay(long ms) {
    if (ms <= 0) {
        return;
    }
    if (ms > 3600000L) {
        ms = 3600000L;
    }
    usleep((useconds_t)(ms * 1000));
}

static int ios_wherex(void) {
    return ios_state.cursor_x;
}

static int ios_wherey(void) {
    return ios_state.cursor_y;
}

static int ios_putch(int c) {
    // Flag: if deferred wrap needs a scroll, we must save the top line
    // to scrollback AFTER releasing ios_state.mutex (to avoid deadlock).
    int need_scroll = 0;
    struct vmem_cell saved_line[MAX_TERMINAL_WIDTH];
    int saved_width = 0;

    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        // Deferred wrap: if a previous character was written at the last column,
        // perform the wrap now before writing the new character.
        // This prevents double-advancing when ANSI art fills all 80 columns
        // and the BBS also sends a newline.
        if (ios_state.pending_wrap) {
            ios_state.pending_wrap = 0;
            ios_state.cursor_x = 1;
            ios_state.cursor_y++;
            if (ios_state.cursor_y > ios_state.height) {
                // Need to scroll — save top line, shift screen up, blank bottom
                ios_state.cursor_y = ios_state.height;

                int last_line_offset;
                if (safe_mult_int(ios_state.height - 1, ios_state.width, &last_line_offset)) {
                    size_t move_size;
                    if (safe_mult_size((size_t)last_line_offset, sizeof(struct vmem_cell), &move_size)) {
                        // Save top row for scrollback
                        saved_width = ios_state.width;
                        if (saved_width > MAX_TERMINAL_WIDTH) saved_width = MAX_TERMINAL_WIDTH;
                        memcpy(saved_line, ios_state.screen, saved_width * sizeof(struct vmem_cell));
                        need_scroll = 1;

                        memmove(ios_state.screen,
                                ios_state.screen + ios_state.width,
                                move_size);

                        for (int i = 0; i < ios_state.width; i++) {
                            int idx2;
                            if (!safe_add_int(last_line_offset, i, &idx2)) break;
                            ios_state.screen[idx2].ch = ' ';
                            ios_state.screen[idx2].legacy_attr = ios_state.current_attr;
                            ios_state.screen[idx2].fg = ios_state.fg_color;
                            ios_state.screen[idx2].bg = ios_state.bg_color;
                            ios_state.screen[idx2].font = 0;
                        }
                        mark_screen_dirty();
                    }
                }
            }
        }

        int x = ios_state.cursor_x - 1;
        int y = ios_state.cursor_y - 1;

        int idx;
        if (validate_index(x, y, ios_state.width, ios_state.height, &idx)) {
            ios_state.screen[idx].ch = (uint8_t)c;
            ios_state.screen[idx].legacy_attr = ios_state.current_attr;
            ios_state.screen[idx].fg = ios_state.fg_color;
            ios_state.screen[idx].bg = ios_state.bg_color;
            ios_state.screen[idx].font = 0;
            mark_cell_dirty(x, y);

            ios_state.cursor_x++;
            if (ios_state.cursor_x > ios_state.width) {
                // Don't wrap yet - defer until next character is written.
                // This allows LF/CR to handle cursor movement without double-advancing.
                ios_state.cursor_x = ios_state.width;  // Stay at last column
                ios_state.pending_wrap = 1;
            }
        }
    }
    pthread_mutex_unlock(&ios_state.mutex);

    // Save the scrolled-off line to scrollback (g_lock already held by caller)
    if (need_scroll && saved_width > 0) {
        scrollback_save_line(saved_line, saved_width);
    }

    return c;
}

static void ios_gotoxy(int x, int y) {
    pthread_mutex_lock(&ios_state.mutex);
    // Explicit cursor positioning cancels any pending wrap
    ios_state.pending_wrap = 0;
    if (x >= 1 && x <= ios_state.width) {
        ios_state.cursor_x = x;
    }
    if (y >= 1 && y <= ios_state.height) {
        ios_state.cursor_y = y;
    }
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_clrscr(void) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.pending_wrap = 0;
    if (ios_state.screen) {
        int w = ios_state.width;
        int h = ios_state.height;

        // Save current screen content to scrollback before clearing.
        // Find the last row that has any non-space content.
        int last_nonempty_row = -1;
        for (int row = h - 1; row >= 0; row--) {
            for (int col = 0; col < w; col++) {
                unsigned char ch = ios_state.screen[row * w + col].ch;
                if (ch != ' ' && ch != 0) {
                    last_nonempty_row = row;
                    goto found_last;
                }
            }
        }
        found_last:

        // Save rows 0..last_nonempty_row to scrollback ring buffer.
        // scrollback_save_line() is lock-free; caller (native_process_data)
        // already holds g_lock so the scrollback fields are safe to modify.
        for (int row = 0; row <= last_nonempty_row; row++) {
            scrollback_save_line(&ios_state.screen[row * w], w);
        }

        // Now clear the screen
        int screen_size;
        if (validate_dimensions(w, h, &screen_size)) {
            for (int i = 0; i < screen_size; i++) {
                ios_state.screen[i].ch = ' ';
                ios_state.screen[i].legacy_attr = ios_state.current_attr;
                ios_state.screen[i].fg = ios_state.fg_color;
                ios_state.screen[i].bg = ios_state.bg_color;
                ios_state.screen[i].font = 0;
            }
        }
        ios_state.cursor_x = 1;
        ios_state.cursor_y = 1;
        mark_screen_dirty();
    }
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_gettextinfo(struct text_info *info) {
    if (!info) return;
    pthread_mutex_lock(&ios_state.mutex);
    info->winleft = 1;
    info->wintop = 1;
    info->winright = ios_state.width;
    info->winbottom = ios_state.height;
    info->attribute = ios_state.current_attr;
    info->normattr = 7;
    info->currmode = C80;
    info->screenheight = ios_state.height;
    info->screenwidth = ios_state.width;
    info->curx = ios_state.cursor_x;
    info->cury = ios_state.cursor_y;
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_setcursortype(int type) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.cursor_type = type;
    ios_state.cursor_visible = (type != _NOCURSOR);
    pthread_mutex_unlock(&ios_state.mutex);
}

static int ios_getch(void) {
    while (!ios_kbhit()) {
        usleep(10000); // 10ms
    }

    pthread_mutex_lock(&input_mutex);
    int c = -1;
    if (input_head != input_tail) {
        c = input_buffer[input_tail];
        input_tail = (input_tail + 1) % INPUT_BUFFER_SIZE;
    }
    pthread_mutex_unlock(&input_mutex);
    return c;
}

static int ios_getche(void) {
    int c = ios_getch();
    if (c >= 0) {
        ios_putch(c);
    }
    return c;
}

static void ios_beep(void) {
    // Bell handling is done in Swift layer
}

static void ios_highvideo(void) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.current_attr |= 0x08;
    ios_state.fg_color = ios_state.current_attr & 0x0F;
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_lowvideo(void) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.current_attr &= ~0x08;
    ios_state.fg_color = ios_state.current_attr & 0x0F;
    pthread_mutex_unlock(&ios_state.mutex);
}

// Enable bright/intense background (iCE mode - SGR 5 blink as bright BG)
static void ios_brightbackground(void) {
    pthread_mutex_lock(&ios_state.mutex);
    // Add 8 to background if not already bright (set bit 7 for bg intensity)
    if (ios_state.bg_color < 8) {
        ios_state.bg_color += 8;
        // Update attr: bits 4-7 hold background
        ios_state.current_attr = (ios_state.current_attr & 0x0F) | ((ios_state.bg_color & 0x0F) << 4);
    }
    pthread_mutex_unlock(&ios_state.mutex);
}

// Reverse video (SGR 7) - swap foreground and background colors
static void ios_reversevideo(void) {
    pthread_mutex_lock(&ios_state.mutex);
    uint32_t temp_fg = ios_state.fg_color;
    uint32_t temp_bg = ios_state.bg_color;
    ios_state.fg_color = temp_bg;
    ios_state.bg_color = temp_fg;
    // Update attr with swapped colors
    ios_state.current_attr = (uint8_t)((ios_state.fg_color & 0x0F) | ((ios_state.bg_color & 0x0F) << 4));
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_normvideo(void) {
    ios_textattr(7);
}

static void ios_textmode(int mode) {
    int new_width = 80;
    int new_height = 25;

    switch (mode) {
        case C40:
        case BW40:
            new_width = 40;
            new_height = 25;
            break;
        case C80:
        case BW80:
        case MONO:
        default:
            new_width = 80;
            new_height = 25;
            break;
        case C80X28:
            new_width = 80;
            new_height = 28;
            break;
        case C80X30:
            new_width = 80;
            new_height = 30;
            break;
        case C80X43:
            new_width = 80;
            new_height = 43;
            break;
        case C80X50:
            new_width = 80;
            new_height = 50;
            break;
        case C80X60:
            new_width = 80;
            new_height = 60;
            break;
    }

    pthread_mutex_lock(&ios_state.mutex);
    ios_state.pending_wrap = 0;

    if (new_width != ios_state.width || new_height != ios_state.height) {
        size_t alloc_size;
        if (!validate_alloc_size(new_width, new_height, sizeof(struct vmem_cell), &alloc_size)) {
            pthread_mutex_unlock(&ios_state.mutex);
            return;
        }

        struct vmem_cell *new_screen = calloc(1, alloc_size);
        if (new_screen) {
            free(ios_state.screen);
            ios_state.screen = new_screen;
            ios_state.width = new_width;
            ios_state.height = new_height;

            int screen_size;
            if (validate_dimensions(new_width, new_height, &screen_size)) {
                for (int i = 0; i < screen_size; i++) {
                    ios_state.screen[i].ch = ' ';
                    ios_state.screen[i].legacy_attr = 7;
                    ios_state.screen[i].fg = 7;
                    ios_state.screen[i].bg = 0;
                    ios_state.screen[i].font = 0;
                }
            }
        }
    }

    ios_state.cursor_x = 1;
    ios_state.cursor_y = 1;
    mark_screen_dirty();

    pthread_mutex_unlock(&ios_state.mutex);

    cio_textinfo.screenwidth = new_width;
    cio_textinfo.screenheight = new_height;
}

static int ios_ungetch(int ch) {
    pthread_mutex_lock(&input_mutex);
    int next = (input_head + 1) % INPUT_BUFFER_SIZE;
    if (next != input_tail) {
        input_buffer[input_head] = (unsigned char)ch;
        input_head = next;
        pthread_mutex_unlock(&input_mutex);
        return ch;
    }
    pthread_mutex_unlock(&input_mutex);
    return -1;
}

static int ios_movetext(int sx, int sy, int ex, int ey, int dx, int dy) {
    int width, height;
    if (!validate_rect_dims(sx, sy, ex, ey, &width, &height)) {
        return 0;
    }

    size_t alloc_size;
    if (!validate_alloc_size(width, height, sizeof(struct vmem_cell), &alloc_size)) {
        return 0;
    }

    struct vmem_cell *temp = malloc(alloc_size);
    if (!temp) return 0;

    ios_vmem_gettext(sx, sy, ex, ey, temp);
    ios_vmem_puttext(dx, dy, dx + width - 1, dy + height - 1, temp);

    free(temp);
    return 1;
}

static void ios_wscroll(void) {
    // Stack buffer to hold the top row before it's overwritten by memmove.
    // Max width is MAX_TERMINAL_WIDTH (1000); 1000 * sizeof(vmem_cell) ≈ 20 KB.
    struct vmem_cell saved_line[MAX_TERMINAL_WIDTH];
    int saved_width = 0;

    pthread_mutex_lock(&ios_state.mutex);
    ios_state.pending_wrap = 0;
    if (ios_state.screen && ios_state.height > 1) {
        int last_line_offset;
        if (!safe_mult_int(ios_state.height - 1, ios_state.width, &last_line_offset)) {
            pthread_mutex_unlock(&ios_state.mutex);
            return;
        }

        size_t move_size;
        if (!safe_mult_size((size_t)last_line_offset, sizeof(struct vmem_cell), &move_size)) {
            pthread_mutex_unlock(&ios_state.mutex);
            return;
        }

        // Save the top row before it gets overwritten
        saved_width = ios_state.width;
        if (saved_width > MAX_TERMINAL_WIDTH) saved_width = MAX_TERMINAL_WIDTH;
        memcpy(saved_line, ios_state.screen, saved_width * sizeof(struct vmem_cell));

        // Scroll: shift everything up by one row
        memmove(ios_state.screen,
                ios_state.screen + ios_state.width,
                move_size);

        // Blank the new bottom row
        for (int i = 0; i < ios_state.width; i++) {
            int idx;
            if (!safe_add_int(last_line_offset, i, &idx)) {
                break;
            }
            ios_state.screen[idx].ch = ' ';
            ios_state.screen[idx].legacy_attr = ios_state.current_attr;
            ios_state.screen[idx].fg = ios_state.fg_color;
            ios_state.screen[idx].bg = ios_state.bg_color;
            ios_state.screen[idx].font = 0;
        }
        mark_screen_dirty();
    }
    pthread_mutex_unlock(&ios_state.mutex);

    // Save the captured top row into the scrollback ring buffer.
    // scrollback_save_line() is lock-free; caller already holds g_lock.
    if (saved_width > 0) {
        scrollback_save_line(saved_line, saved_width);
    }
}

static void ios_window(int sx, int sy, int ex, int ey) {
    cio_textinfo.winleft = sx;
    cio_textinfo.wintop = sy;
    cio_textinfo.winright = ex;
    cio_textinfo.winbottom = ey;
}

static void ios_delline(void) {
    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        int y = ios_state.cursor_y - 1;
        if (y >= 0 && y < ios_state.height - 1) {
            int src_offset, dst_offset, lines_to_move, cells_to_move;

            int y_plus_1;
            if (!safe_add_int(y, 1, &y_plus_1)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            if (!safe_mult_int(y, ios_state.width, &dst_offset) ||
                !safe_mult_int(y_plus_1, ios_state.width, &src_offset)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            lines_to_move = ios_state.height - y - 1;

            if (!safe_mult_int(lines_to_move, ios_state.width, &cells_to_move)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            size_t move_size;
            if (!safe_mult_size((size_t)cells_to_move, sizeof(struct vmem_cell), &move_size)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            memmove(ios_state.screen + dst_offset,
                    ios_state.screen + src_offset,
                    move_size);
        }

        int last_line;
        if (safe_mult_int(ios_state.height - 1, ios_state.width, &last_line)) {
            for (int i = 0; i < ios_state.width; i++) {
                int idx;
                if (!safe_add_int(last_line, i, &idx)) break;
                ios_state.screen[idx].ch = ' ';
                ios_state.screen[idx].legacy_attr = ios_state.current_attr;
            }
        }
        mark_region_dirty(0, y, ios_state.width - 1, ios_state.height - 1);
    }
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_insline(void) {
    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        int y = ios_state.cursor_y - 1;
        if (y >= 0 && y < ios_state.height - 1) {
            int src_offset, dst_offset, lines_to_move, cells_to_move;

            int y_plus_1;
            if (!safe_add_int(y, 1, &y_plus_1)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            if (!safe_mult_int(y, ios_state.width, &src_offset) ||
                !safe_mult_int(y_plus_1, ios_state.width, &dst_offset)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            lines_to_move = ios_state.height - y - 1;

            if (!safe_mult_int(lines_to_move, ios_state.width, &cells_to_move)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            size_t move_size;
            if (!safe_mult_size((size_t)cells_to_move, sizeof(struct vmem_cell), &move_size)) {
                pthread_mutex_unlock(&ios_state.mutex);
                return;
            }

            memmove(ios_state.screen + dst_offset,
                    ios_state.screen + src_offset,
                    move_size);
        }

        if (y >= 0) {
            int line_offset;
            if (safe_mult_int(y, ios_state.width, &line_offset)) {
                for (int i = 0; i < ios_state.width; i++) {
                    int idx;
                    if (!safe_add_int(line_offset, i, &idx)) break;
                    ios_state.screen[idx].ch = ' ';
                    ios_state.screen[idx].legacy_attr = ios_state.current_attr;
                }
            }
        }
        mark_region_dirty(0, y, ios_state.width - 1, ios_state.height - 1);
    }
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_textbackground(int color) {
    pthread_mutex_lock(&ios_state.mutex);
    // Allow 4 bits for background (0-15) to support iCE colors/bright backgrounds
    ios_state.bg_color = color & 0x0F;
    // Use all 4 bits in attr: bits 4-7 for background
    ios_state.current_attr = (ios_state.current_attr & 0x0F) | ((color & 0x0F) << 4);
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_textcolor(int color) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.fg_color = color & 0x0F;
    ios_state.current_attr = (ios_state.current_attr & 0xF0) | (color & 0x0F);
    pthread_mutex_unlock(&ios_state.mutex);
}

static void ios_settitle(const char *title) {
    // Title handling done in Swift layer
    (void)title;
}

static void ios_setname(const char *name) {
    (void)name;
}

static int ios_setfont(int font, int force, int font_num) {
    (void)font;
    (void)force;
    (void)font_num;
    return 0;
}

static int ios_getfont(int font_num) {
    (void)font_num;
    return 0;
}

static void ios_setvideoflags(int flags) {
    (void)flags;
}

static int ios_getvideoflags(void) {
    return 0;
}

static int ios_setpalette(uint32_t entry, uint16_t r, uint16_t g, uint16_t b) {
    if (entry >= 16) return 0;
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.palette[entry] = ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
    pthread_mutex_unlock(&ios_state.mutex);
    return 1;
}

static int ios_attr2palette(uint8_t attr, uint32_t *fg, uint32_t *bg) {
    if (fg) *fg = attr & 0x0F;
    // Allow 4 bits for background (0-15) to support iCE colors/bright backgrounds
    if (bg) *bg = (attr >> 4) & 0x0F;
    return 1;
}

// ============================================================================
// MARK: - Initialization
// ============================================================================

int ios_ciolib_init(void) {
    pthread_mutex_init(&ios_state.mutex, NULL);

    const int init_width = 80;
    const int init_height = 25;
    size_t alloc_size;
    int screen_size;

    if (!validate_alloc_size(init_width, init_height, sizeof(struct vmem_cell), &alloc_size) ||
        !validate_dimensions(init_width, init_height, &screen_size)) {
        return -1;
    }

    ios_state.width = init_width;
    ios_state.height = init_height;
    ios_state.cursor_x = 1;
    ios_state.cursor_y = 1;
    ios_state.cursor_visible = 1;
    ios_state.cursor_type = _NORMALCURSOR;
    ios_state.current_attr = 7;
    ios_state.fg_color = 7;
    ios_state.bg_color = 0;
    ios_state.dirty = 0;
    ios_state.pending_wrap = 0;
    ios_state.screen = calloc(1, alloc_size);

    if (!ios_state.screen) {
        return -1;
    }

    for (int i = 0; i < screen_size; i++) {
        ios_state.screen[i].ch = ' ';
        ios_state.screen[i].legacy_attr = 7;
        ios_state.screen[i].fg = 7;
        ios_state.screen[i].bg = 0;
        ios_state.screen[i].font = 0;
    }

    cio_textinfo.winleft = 1;
    cio_textinfo.wintop = 1;
    cio_textinfo.winright = 80;
    cio_textinfo.winbottom = 25;
    cio_textinfo.attribute = 7;
    cio_textinfo.normattr = 7;
    cio_textinfo.currmode = C80;
    cio_textinfo.screenheight = 25;
    cio_textinfo.screenwidth = 80;
    cio_textinfo.curx = 1;
    cio_textinfo.cury = 1;

    return 0;
}

int initciolib(int mode) {
    int result = ios_ciolib_init();
    if (result != 0) {
        return result;
    }

    // Set up cio_api function pointers
    memset(&cio_api, 0, sizeof(cio_api));
    cio_api.mode = mode;
    cio_api.mouse = 0;
    cio_api.options = 0;
    cio_api.clreol = ios_clreol;
    cio_api.puttext = ios_puttext;
    cio_api.vmem_puttext = ios_vmem_puttext;
    cio_api.gettext = ios_gettext;
    cio_api.vmem_gettext = ios_vmem_gettext;
    cio_api.textattr = ios_textattr;
    cio_api.kbhit = ios_kbhit;
    cio_api.kbwait = ios_kbwait;
    cio_api.delay = ios_delay;
    cio_api.wherex = ios_wherex;
    cio_api.wherey = ios_wherey;
    cio_api.putch = ios_putch;
    cio_api.gotoxy = ios_gotoxy;
    cio_api.clrscr = ios_clrscr;
    cio_api.gettextinfo = ios_gettextinfo;
    cio_api.setcursortype = ios_setcursortype;
    cio_api.getch = ios_getch;
    cio_api.getche = ios_getche;
    cio_api.beep = ios_beep;
    cio_api.highvideo = ios_highvideo;
    cio_api.lowvideo = ios_lowvideo;
    cio_api.normvideo = ios_normvideo;
    cio_api.textmode = ios_textmode;
    cio_api.ungetch = ios_ungetch;
    cio_api.movetext = ios_movetext;
    cio_api.wscroll = ios_wscroll;
    cio_api.window = ios_window;
    cio_api.delline = ios_delline;
    cio_api.insline = ios_insline;
    cio_api.textbackground = ios_textbackground;
    cio_api.textcolor = ios_textcolor;
    cio_api.settitle = ios_settitle;
    cio_api.setname = ios_setname;
    cio_api.setfont = ios_setfont;
    cio_api.getfont = ios_getfont;
    cio_api.setvideoflags = ios_setvideoflags;
    cio_api.getvideoflags = ios_getvideoflags;
    cio_api.setpalette = ios_setpalette;
    cio_api.attr2palette = ios_attr2palette;

    return 0;
}

void suspendciolib(void) {
    // Nothing to do
}

// Resize terminal for iOS
void ios_ciolib_resize(int width, int height) {
    if (width <= 0 || height <= 0 ||
        width > MAX_TERMINAL_WIDTH || height > MAX_TERMINAL_HEIGHT) {
        return;
    }

    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen != NULL &&
        ios_state.width == width && ios_state.height == height) {
        pthread_mutex_unlock(&ios_state.mutex);
        return;
    }
    pthread_mutex_unlock(&ios_state.mutex);

    size_t alloc_size;
    if (!validate_alloc_size(width, height, sizeof(struct vmem_cell), &alloc_size)) {
        return;
    }

    pthread_mutex_lock(&ios_state.mutex);
    ios_state.pending_wrap = 0;

    struct vmem_cell *new_screen = calloc(1, alloc_size);
    if (!new_screen) {
        pthread_mutex_unlock(&ios_state.mutex);
        return;
    }

    int screen_size;
    if (validate_dimensions(width, height, &screen_size)) {
        for (int i = 0; i < screen_size; i++) {
            new_screen[i].ch = ' ';
            new_screen[i].legacy_attr = ios_state.current_attr;
            new_screen[i].fg = ios_state.fg_color;
            new_screen[i].bg = ios_state.bg_color;
            new_screen[i].font = 0;
        }
    }

    if (ios_state.screen) {
        int copy_width = (width < ios_state.width) ? width : ios_state.width;
        int copy_height = (height < ios_state.height) ? height : ios_state.height;

        for (int y = 0; y < copy_height; y++) {
            for (int x = 0; x < copy_width; x++) {
                int new_idx, old_idx;
                if (validate_index(x, y, width, height, &new_idx) &&
                    validate_index(x, y, ios_state.width, ios_state.height, &old_idx)) {
                    new_screen[new_idx] = ios_state.screen[old_idx];
                }
            }
        }
        free(ios_state.screen);
    }

    ios_state.screen = new_screen;
    ios_state.width = width;
    ios_state.height = height;

    if (ios_state.cursor_x > width) ios_state.cursor_x = width;
    if (ios_state.cursor_y > height) ios_state.cursor_y = height;

    mark_screen_dirty();

    pthread_mutex_unlock(&ios_state.mutex);

    cio_textinfo.screenwidth = width;
    cio_textinfo.screenheight = height;
    cio_textinfo.winright = width;
    cio_textinfo.winbottom = height;
}

// Cleanup
void ios_ciolib_cleanup(void) {
    pthread_mutex_lock(&ios_state.mutex);
    if (ios_state.screen) {
        free(ios_state.screen);
        ios_state.screen = NULL;
    }
    pthread_mutex_unlock(&ios_state.mutex);
    pthread_mutex_destroy(&ios_state.mutex);
}

// ============================================================================
// MARK: - ciolib_* Wrapper Functions
// ============================================================================

// Undefine ciolib macros to avoid conflicts
#undef gotoxy
#undef wherex
#undef wherey
#undef clrscr
#undef gettextinfo
#undef textattr
#undef vmem_puttext
#undef vmem_gettext
#undef movetext
#undef window
#undef putch
#undef setcursortype
#undef clreol
#undef delline
#undef insline
#undef textbackground
#undef textcolor
#undef highvideo
#undef lowvideo
#undef normvideo
#undef setfont
#undef getfont
#undef settitle
#undef setname
#undef beep
#undef kbhit
#undef getch
#undef getche
#undef ungetch
#undef wscroll
#undef delay
#undef puttext
#undef gettext
#undef textmode
#undef setpalette
#undef attr2palette
#undef setvideoflags
#undef getvideoflags

void ciolib_gotoxy(int x, int y) {
    ios_gotoxy(x, y);
}

int ciolib_wherex(void) {
    return ios_wherex();
}

int ciolib_wherey(void) {
    return ios_wherey();
}

void ciolib_clrscr(void) {
    ios_clrscr();
}

void ciolib_gettextinfo(struct text_info *info) {
    ios_gettextinfo(info);
}

void ciolib_textattr(int attr) {
    ios_textattr(attr);
}

int ciolib_vmem_puttext(int sx, int sy, int ex, int ey, struct vmem_cell *buf) {
    return ios_vmem_puttext(sx, sy, ex, ey, buf);
}

int ciolib_vmem_gettext(int sx, int sy, int ex, int ey, struct vmem_cell *buf) {
    return ios_vmem_gettext(sx, sy, ex, ey, buf);
}

int ciolib_movetext(int sx, int sy, int ex, int ey, int dx, int dy) {
    return ios_movetext(sx, sy, ex, ey, dx, dy);
}

void ciolib_window(int sx, int sy, int ex, int ey) {
    ios_window(sx, sy, ex, ey);
}

int ciolib_putch(int ch) {
    return ios_putch(ch);
}

void ciolib_setcursortype(int type) {
    ios_setcursortype(type);
}

void ciolib_clreol(void) {
    ios_clreol();
}

void ciolib_delline(void) {
    ios_delline();
}

void ciolib_insline(void) {
    ios_insline();
}

void ciolib_textbackground(int color) {
    ios_textbackground(color);
}

void ciolib_textcolor(int color) {
    ios_textcolor(color);
}

void ciolib_highvideo(void) {
    ios_highvideo();
}

void ciolib_lowvideo(void) {
    ios_lowvideo();
}

void ciolib_brightbackground(void) {
    ios_brightbackground();
}

void ciolib_reversevideo(void) {
    ios_reversevideo();
}

void ciolib_normvideo(void) {
    ios_normvideo();
}

int ciolib_setfont(int font, int force, int font_num) {
    return ios_setfont(font, force, font_num);
}

int ciolib_getfont(int font_num) {
    return ios_getfont(font_num);
}

void ciolib_settitle(const char *title) {
    ios_settitle(title);
}

void ciolib_setname(const char *name) {
    ios_setname(name);
}

void ciolib_beep(void) {
    ios_beep();
}

int ciolib_kbhit(void) {
    return ios_kbhit();
}

int ciolib_getch(void) {
    return ios_getch();
}

int ciolib_getche(void) {
    return ios_getche();
}

int ciolib_ungetch(int ch) {
    return ios_ungetch(ch);
}

void ciolib_wscroll(void) {
    ios_wscroll();
}

void ciolib_delay(long ms) {
    ios_delay(ms);
}

int ciolib_puttext(int sx, int sy, int ex, int ey, void *buf) {
    return ios_puttext(sx, sy, ex, ey, buf);
}

int ciolib_gettext(int sx, int sy, int ex, int ey, void *buf) {
    return ios_gettext(sx, sy, ex, ey, buf);
}

void ciolib_textmode(int mode) {
    ios_textmode(mode);
}

int ciolib_setpalette(uint32_t entry, uint16_t r, uint16_t g, uint16_t b) {
    return ios_setpalette(entry, r, g, b);
}

int ciolib_attr2palette(uint8_t attr, uint32_t *fg, uint32_t *bg) {
    return ios_attr2palette(attr, fg, bg);
}

void ciolib_setvideoflags(int flags) {
    ios_setvideoflags(flags);
}

int ciolib_getvideoflags(void) {
    return ios_getvideoflags();
}

void ciolib_setcolour(uint32_t fg, uint32_t bg) {
    pthread_mutex_lock(&ios_state.mutex);
    ios_state.fg_color = fg;
    ios_state.bg_color = bg;
    pthread_mutex_unlock(&ios_state.mutex);
}

int ciolib_attrfont(uint8_t attr) {
    (void)attr;
    return 0;
}

int ciolib_get_modepalette(uint32_t *palette) {
    if (palette) {
        pthread_mutex_lock(&ios_state.mutex);
        memcpy(palette, ios_state.palette, 16 * sizeof(uint32_t));
        pthread_mutex_unlock(&ios_state.mutex);
    }
    return 0;
}

int ciolib_set_modepalette(uint32_t *palette) {
    if (palette) {
        pthread_mutex_lock(&ios_state.mutex);
        memcpy(ios_state.palette, palette, 16 * sizeof(uint32_t));
        pthread_mutex_unlock(&ios_state.mutex);
    }
    return 0;
}
