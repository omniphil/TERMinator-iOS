/**
 * SyncTERM iOS Native Bridge
 *
 * Provides C functions to connect Swift with the native
 * SyncTERM terminal emulator and Telnet/SSH connection code.
 *
 * This is the iOS equivalent of Android's syncterm_jni.c
 */

#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/time.h>

// iOS logging - disabled for now
#define IOS_LOG(fmt, ...) ((void)0)

// Include SyncTERM headers
#include "cterm.h"
#include "ciolib.h"
#include "conn.h"
#include "conn_telnet.h"
#include "bbslist.h"
#include "genwrap.h"
#include "sockwrap.h"

#ifndef WITHOUT_CRYPTLIB
#include "ssh.h"
#endif

// iOS-specific ciolib implementation
#include "ios_ciolib.h"

// Native bridge header (function declarations)
#include "native_bridge.h"

// ZMODEM implementation
#include "zmodem_ios.h"

// Maximum scrollback buffer size (100 MB)
#define MAX_SCROLLBACK_BYTES (100 * 1024 * 1024)

// Log buffer size for session logging
#define LOG_BUFFER_SIZE (64 * 1024)

// Global state
static struct cterminal *g_cterm = NULL;
static struct vmem_cell *g_scrollback = NULL;
static int g_scrollback_lines = 1000;
static int g_connected = 0;
static int g_initialized = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// Terminal dimensions
static int g_term_width = 80;
static int g_term_height = 25;

// Current font ID
static int g_current_font_id = 0;

// Connection settings
static int g_hide_status_line = 1;
static int g_screen_mode = 0;  // SCREEN_MODE_80X25
static char g_font_name[256] = "Codepage 437 English";

// Connection config
static struct bbslist g_bbs_config;

// ZMODEM state
static volatile int g_zmodem_detected = 0;
static volatile int g_zmodem_upload_ready = 0;
static unsigned char g_zmodem_buffer[4096];
static int g_zmodem_buffer_len = 0;
static pthread_mutex_t g_zmodem_lock = PTHREAD_MUTEX_INITIALIZER;

// Cross-buffer ZMODEM detection: save last byte from previous read
static unsigned char g_prev_last_byte = 0;
static int g_has_prev_byte = 0;

// Upload queue
static char g_upload_queued_file[512] = {0};
static volatile int g_upload_file_queued = 0;

// Bell detection
static volatile int g_bell_detected = 0;

// Connection statistics
static volatile uint64_t g_bytes_sent = 0;
static volatile uint64_t g_bytes_received = 0;
static volatile int64_t g_connect_time_ms = 0;

// Session logging
static unsigned char g_log_buffer[LOG_BUFFER_SIZE];
static volatile int g_log_buffer_len = 0;
static volatile int g_logging_enabled = 0;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

// Files directory for SSH keys
static char g_files_dir[512] = {0};

// Transfer state
static int g_transfer_state = 0;  // idle
static int64_t g_transfer_bytes = 0;
static int64_t g_transfer_total = 0;
static char g_transfer_filename[256] = {0};
static char g_transfer_error[256] = {0};
static char g_download_dir[512] = {0};

// Helper: Get current time in milliseconds
static int64_t get_current_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

// ZMODEM frame types
#define ZMODEM_FRAME_ZRQINIT  0x00
#define ZMODEM_FRAME_ZRINIT   0x01

// Check if a byte is a valid ZMODEM header type indicator
// Standard: 'A' (ZBIN/CRC16), 'B' (ZHEX), 'C' (ZBIN32/CRC32)
// Variable-length: 'a' (ZVBIN), 'b' (ZVHEX), 'c' (ZVBIN32), 'd' (ZVBINR32)
static int is_zmodem_header_type(unsigned char c) {
    return c == 'A' || c == 'B' || c == 'C' ||
           c == 'a' || c == 'b' || c == 'c' || c == 'd';
}

// Check if a header type byte indicates hex encoding
static int is_hex_header(unsigned char c) {
    return c == 'B' || c == 'b';
}

// Detect ZMODEM header in buffer
typedef struct {
    int position;
    int frame_type;
} zmodem_detect_result_t;

static zmodem_detect_result_t detect_zmodem_ex(const unsigned char *buf, int len) {
    zmodem_detect_result_t result = { -1, -1 };

    if (len < 1) return result;

    for (int i = 0; i < len - 1; i++) {
        // Look for ZDLE (0x18) followed by header type
        if (buf[i] == 0x18 && is_zmodem_header_type(buf[i+1])) {
            int start = i;
            // Back up to include ZPAD bytes
            while (start > 0 && buf[start - 1] == 0x2a) {
                start--;
            }

            int frame_type = -1;
            if (is_hex_header(buf[i+1]) && i + 3 < len) {
                char hex[3] = { buf[i+2], buf[i+3], 0 };
                frame_type = (int)strtol(hex, NULL, 16);
            } else if (!is_hex_header(buf[i+1]) && i + 2 < len) {
                frame_type = buf[i+2];
            }

            result.position = start;
            result.frame_type = frame_type;
            return result;
        }
    }

    // Check if the LAST byte is ZDLE (could be split across reads)
    // Save it for cross-buffer detection on the next call
    if (len >= 1 && buf[len - 1] == 0x18) {
        g_has_prev_byte = 1;
        g_prev_last_byte = 0x18;
    } else {
        g_has_prev_byte = 0;
    }

    return result;
}

// ============================================================================
// MARK: - Initialization Functions
// ============================================================================

void native_set_files_dir(const char *path) {
    if (path) {
        strncpy(g_files_dir, path, sizeof(g_files_dir) - 1);
        g_files_dir[sizeof(g_files_dir) - 1] = '\0';
    }
}

bool native_init(void) {
    pthread_mutex_lock(&g_lock);

    if (g_initialized) {
        pthread_mutex_unlock(&g_lock);
        return true;
    }

#ifndef WITHOUT_CRYPTLIB
    // Initialize cryptlib for SSH
    init_crypt();
#endif

    // Initialize ciolib (iOS-specific implementation)
    if (initciolib(CIOLIB_MODE_AUTO) != 0) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    // Allocate scrollback buffer
    int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
    size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);

    if (scrollback_size > MAX_SCROLLBACK_BYTES) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    g_scrollback = calloc(1, scrollback_size);
    if (!g_scrollback) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    // Initialize terminal emulator
    g_cterm = cterm_init(g_term_height, g_term_width, 1, 1,
                         g_scrollback_lines, scrollback_cols,
                         g_scrollback, CTERM_EMULATION_ANSI_BBS);
    if (!g_cterm) {
        free(g_scrollback);
        g_scrollback = NULL;
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    cterm_start(g_cterm);
    g_initialized = 1;

    pthread_mutex_unlock(&g_lock);
    return true;
}

void native_destroy(void) {
    pthread_mutex_lock(&g_lock);

    if (g_connected) {
        conn_close();
        g_connected = 0;
    }

    if (g_cterm) {
        cterm_end(g_cterm, 0);
        g_cterm = NULL;
    }

    if (g_scrollback) {
        free(g_scrollback);
        g_scrollback = NULL;
    }

    ios_ciolib_cleanup();
    g_initialized = 0;

    pthread_mutex_unlock(&g_lock);
}

// ============================================================================
// MARK: - Connection Functions
// ============================================================================

bool native_connect(const char *host, int32_t port, int32_t protocol,
                    const char *username, const char *password) {
    if (!g_initialized || g_connected) {
        return false;
    }

    pthread_mutex_lock(&g_lock);

    // Set up connection config
    memset(&g_bbs_config, 0, sizeof(g_bbs_config));
    strncpy(g_bbs_config.name, "iOS Connection", LIST_NAME_MAX);
    g_bbs_config.name[LIST_NAME_MAX] = '\0';
    strncpy(g_bbs_config.addr, host, LIST_ADDR_MAX);
    g_bbs_config.addr[LIST_ADDR_MAX] = '\0';
    g_bbs_config.port = (uint16_t)port;

    if (protocol == 5) {  // SSH
#ifndef WITHOUT_CRYPTLIB
        g_bbs_config.type = CONN_TYPE_SSH;
        g_bbs_config.conn_type = CONN_TYPE_SSH;

        if (username && username[0]) {
            strncpy(g_bbs_config.user, username, MAX_USER_LEN);
            g_bbs_config.user[MAX_USER_LEN] = '\0';
        }
        if (password && password[0]) {
            strncpy(g_bbs_config.password, password, MAX_PASSWD_LEN);
            g_bbs_config.password[MAX_PASSWD_LEN] = '\0';
        }
#else
        g_bbs_config.type = CONN_TYPE_TELNET;
        g_bbs_config.conn_type = CONN_TYPE_TELNET;
#endif
    } else {
        g_bbs_config.type = CONN_TYPE_TELNET;
        g_bbs_config.conn_type = CONN_TYPE_TELNET;
    }

    g_bbs_config.screen_mode = g_screen_mode;
    g_bbs_config.hidepopups = 1;
    g_bbs_config.nostatus = g_hide_status_line;
    strncpy(g_bbs_config.font, g_font_name, sizeof(g_bbs_config.font) - 1);

    // Initialize palette
    g_bbs_config.palette[0]  = 0x000000;
    g_bbs_config.palette[1]  = 0x0000AA;
    g_bbs_config.palette[2]  = 0x00AA00;
    g_bbs_config.palette[3]  = 0x00AAAA;
    g_bbs_config.palette[4]  = 0xAA0000;
    g_bbs_config.palette[5]  = 0xAA00AA;
    g_bbs_config.palette[6]  = 0xAA5500;
    g_bbs_config.palette[7]  = 0xAAAAAA;
    g_bbs_config.palette[8]  = 0x555555;
    g_bbs_config.palette[9]  = 0x5555FF;
    g_bbs_config.palette[10] = 0x55FF55;
    g_bbs_config.palette[11] = 0x55FFFF;
    g_bbs_config.palette[12] = 0xFF5555;
    g_bbs_config.palette[13] = 0xFF55FF;
    g_bbs_config.palette[14] = 0xFFFF55;
    g_bbs_config.palette[15] = 0xFFFFFF;

    // Reset ANSI parser state from any previous connection
    cterm_reset_ansi_state();

    IOS_LOG("[native_connect] Calling conn_connect for %{public}s:%d (type=%d)",
           g_bbs_config.addr, g_bbs_config.port, g_bbs_config.conn_type);

    // IMPORTANT: Release lock during conn_connect() because it can block
    // waiting for threads to start, and other code (like native_is_connected)
    // needs to acquire the lock. This prevents deadlock.
    pthread_mutex_unlock(&g_lock);

    bool terminated = conn_connect(&g_bbs_config);

    pthread_mutex_lock(&g_lock);
    IOS_LOG("[native_connect] conn_connect returned terminated=%d", terminated);

    if (!terminated) {
        g_connected = 1;
        g_bytes_sent = 0;
        g_bytes_received = 0;
        g_connect_time_ms = get_current_time_ms();
        IOS_LOG("[native_connect] Connection established, g_connected=1");
    } else {
        IOS_LOG("[native_connect] Connection failed");
    }

    pthread_mutex_unlock(&g_lock);
    return !terminated;
}

void native_disconnect(void) {
    pthread_mutex_lock(&g_lock);

    if (g_connected) {
        conn_close();
        g_connected = 0;
    }

    pthread_mutex_unlock(&g_lock);
}

bool native_is_connected(void) {
    pthread_mutex_lock(&g_lock);
    bool conn_state = conn_connected();
    bool result = g_connected && conn_state;
    pthread_mutex_unlock(&g_lock);
    return result;
}

// ============================================================================
// MARK: - Data Transfer Functions
// ============================================================================

int32_t native_send_data(const uint8_t *data, int32_t count) {
    if (!g_connected || count <= 0) {
        return -1;
    }

    int sent = conn_send(data, (size_t)count, 1000);
    if (sent > 0) {
        pthread_mutex_lock(&g_lock);
        g_bytes_sent += sent;
        pthread_mutex_unlock(&g_lock);
    }
    return (int32_t)sent;
}

int32_t native_send_key(int32_t keyCode) {
    if (!g_connected) {
        return -1;
    }

    unsigned char c = (unsigned char)keyCode;
    int sent = conn_send(&c, 1, 1000);
    if (sent > 0) {
        pthread_mutex_lock(&g_lock);
        g_bytes_sent += sent;
        pthread_mutex_unlock(&g_lock);
    }
    return (int32_t)sent;
}

int32_t native_send_string(const char *str) {
    if (!g_connected || !str) {
        return -1;
    }

    size_t len = strlen(str);
    int sent = conn_send(str, len, 1000);
    if (sent > 0) {
        pthread_mutex_lock(&g_lock);
        g_bytes_sent += sent;
        pthread_mutex_unlock(&g_lock);
    }
    return (int32_t)sent;
}

int32_t native_process_data(void) {
    pthread_mutex_lock(&g_lock);

    if (!g_connected || !g_cterm) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    // Check if ZMODEM already detected
    pthread_mutex_lock(&g_zmodem_lock);
    if (g_zmodem_detected) {
        pthread_mutex_unlock(&g_zmodem_lock);
        pthread_mutex_unlock(&g_lock);
        return -100;
    }
    pthread_mutex_unlock(&g_zmodem_lock);

    size_t waiting = conn_data_waiting();

    if (waiting == 0) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    unsigned char buffer[4096];
    int len = conn_recv_upto(buffer, sizeof(buffer), 0);

    if (len <= 0) {
        pthread_mutex_unlock(&g_lock);
        return len;
    }

    g_bytes_received += len;  // Protected by g_lock

    // Log data if enabled
    if (g_logging_enabled) {
        pthread_mutex_lock(&g_log_lock);
        int space = LOG_BUFFER_SIZE - g_log_buffer_len;
        int to_copy = (len < space) ? len : space;
        if (to_copy > 0) {
            memcpy(g_log_buffer + g_log_buffer_len, buffer, to_copy);
            g_log_buffer_len += to_copy;
        }
        pthread_mutex_unlock(&g_log_lock);
    }

    // Cross-buffer ZMODEM detection: check if previous read ended with ZDLE
    // and this read starts with a header type byte
    if (g_has_prev_byte && g_prev_last_byte == 0x18 && len >= 1 && is_zmodem_header_type(buffer[0])) {
        // ZMODEM header split across reads: ZDLE was last byte of previous read
        // The ZDLE was already sent to terminal (unavoidable), but we catch the rest here
        (void)0;  // Start from beginning of this buffer

        // Save ZMODEM data (prepend the ZDLE we missed)
        pthread_mutex_lock(&g_zmodem_lock);
        g_zmodem_buffer[0] = 0x18;  // ZDLE from previous read
        g_zmodem_buffer_len = len + 1;
        if (g_zmodem_buffer_len > (int)sizeof(g_zmodem_buffer)) {
            g_zmodem_buffer_len = sizeof(g_zmodem_buffer);
        }
        memcpy(g_zmodem_buffer + 1, buffer, g_zmodem_buffer_len - 1);

        // Determine frame type from the reconstructed header
        int frame_type = -1;
        if (is_hex_header(buffer[0]) && len >= 3) {
            char hex[3] = { buffer[1], buffer[2], 0 };
            frame_type = (int)strtol(hex, NULL, 16);
        } else if (!is_hex_header(buffer[0]) && len >= 2) {
            frame_type = buffer[1];
        }

        g_has_prev_byte = 0;

        if (frame_type == ZMODEM_FRAME_ZRINIT) {
            g_zmodem_upload_ready = 1;
            g_zmodem_detected = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -101;
        } else {
            g_zmodem_detected = 1;
            g_zmodem_upload_ready = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -100;
        }
    }

    // Check for ZMODEM in this buffer
    zmodem_detect_result_t zmodem_result = detect_zmodem_ex(buffer, len);
    if (zmodem_result.position >= 0 && zmodem_result.position < len) {
        int zmodem_pos = zmodem_result.position;

        // Process data before ZMODEM
        if (zmodem_pos > 0) {
            char retbuf[256];
            int speed = 0;
            cterm_write(g_cterm, buffer, zmodem_pos, retbuf, sizeof(retbuf), &speed);
            if (retbuf[0] != '\0') {
                conn_send(retbuf, strlen(retbuf), 1000);
            }
        }

        // Save ZMODEM data
        pthread_mutex_lock(&g_zmodem_lock);
        g_zmodem_buffer_len = len - zmodem_pos;
        if (g_zmodem_buffer_len > (int)sizeof(g_zmodem_buffer)) {
            g_zmodem_buffer_len = sizeof(g_zmodem_buffer);
        }
        memcpy(g_zmodem_buffer, buffer + zmodem_pos, g_zmodem_buffer_len);

        if (zmodem_result.frame_type == ZMODEM_FRAME_ZRINIT) {
            g_zmodem_upload_ready = 1;
            g_zmodem_detected = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -101;
        } else {
            g_zmodem_detected = 1;
            g_zmodem_upload_ready = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -100;
        }
    }

    // Check for bell
    for (int i = 0; i < len; i++) {
        if (buffer[i] == 0x07) {
            g_bell_detected = 1;
            break;
        }
    }

    // Process through terminal
    char retbuf[256];
    int speed = 0;
    cterm_write(g_cterm, buffer, len, retbuf, sizeof(retbuf), &speed);

    pthread_mutex_unlock(&g_lock);

    if (retbuf[0] != '\0') {
        conn_send(retbuf, strlen(retbuf), 1000);
    }

    return len;
}

int32_t native_data_waiting(void) {
    if (!g_connected) {
        return 0;
    }
    return (int32_t)conn_data_waiting();
}

// ============================================================================
// MARK: - Screen State Functions
// ============================================================================

// Static buffers for screen data (returned to Swift)
static int32_t g_screen_buffer_cache[132 * 50];  // Max screen size
static int32_t g_palette_cache[16];

/// Convert an RGB color (0x00RRGGBB) to the closest 16-color palette index.
/// Uses squared Euclidean distance in RGB space.
static unsigned int rgb_to_palette_index(uint32_t rgb, const uint32_t *palette) {
    int best = 0;
    int bestDist = 0x7FFFFFFF;
    int r = (rgb >> 16) & 0xFF;
    int g = (rgb >> 8) & 0xFF;
    int b = rgb & 0xFF;

    for (int i = 0; i < 16; i++) {
        int pr = (palette[i] >> 16) & 0xFF;
        int pg = (palette[i] >> 8) & 0xFF;
        int pb = palette[i] & 0xFF;
        int dr = r - pr;
        int dg = g - pg;
        int db = b - pb;
        int dist = dr*dr + dg*dg + db*db;
        if (dist < bestDist) {
            bestDist = dist;
            best = i;
        }
        if (dist == 0) break;  // Exact match
    }
    return (unsigned int)best;
}

const int32_t* native_get_screen_buffer(int32_t *count) {
    pthread_mutex_lock(&g_lock);

    ios_ciolib_lock();

    int width = ios_ciolib_get_screen_width();
    int height = ios_ciolib_get_screen_height();
    int size = width * height;

    if (size <= 0 || size > (132 * 50)) {
        ios_ciolib_unlock();
        pthread_mutex_unlock(&g_lock);
        *count = 0;
        return NULL;
    }

    struct vmem_cell *screen = ios_ciolib_get_screen_buffer();
    if (!screen) {
        ios_ciolib_unlock();
        pthread_mutex_unlock(&g_lock);
        *count = 0;
        return NULL;
    }

    // Get current palette for RGB-to-palette conversion
    uint32_t *current_palette = ios_ciolib_get_palette();

    // Pack cell data
    // Note: vmem_cell.fg/bg are uint32_t:
    //   - If high bit (0x80000000) clear: palette index in low bits
    //   - If high bit set: direct RGB color (0x80RRGGBB)
    for (int i = 0; i < size; i++) {
        unsigned int ch = screen[i].ch & 0xFF;
        unsigned int attr = screen[i].legacy_attr & 0xFF;

        // Extract colors from legacy_attr (canonical source).
        // ios_puttext() (legacy path used by cterm) only sets ch + legacy_attr,
        // leaving vmem_cell.fg/bg at 0. The legacy_attr byte is always correct.
        uint32_t fg_raw = screen[i].fg;
        uint32_t bg_raw = screen[i].bg;
        unsigned int fg, bg;

        // Check if vmem_cell.fg/bg were actually populated (non-zero or RGB mode)
        if ((fg_raw & 0x80000000) && current_palette) {
            // Direct RGB color - convert to closest palette index
            fg = rgb_to_palette_index(fg_raw & 0x00FFFFFF, current_palette);
        } else if (fg_raw != 0 && !(fg_raw & 0xFF000000)) {
            // Non-zero palette index with no flag bits in upper byte
            fg = fg_raw & 0x0F;
        } else {
            // Use legacy_attr as canonical source (always set by both code paths)
            fg = attr & 0x0F;
        }

        if ((bg_raw & 0x80000000) && current_palette) {
            // Direct RGB color - convert to closest palette index
            bg = rgb_to_palette_index(bg_raw & 0x00FFFFFF, current_palette);
        } else if (bg_raw != 0 && !(bg_raw & 0xFF000000)) {
            // Non-zero palette index with no flag bits in upper byte
            bg = bg_raw & 0x0F;
        } else {
            // Use legacy_attr as canonical source (always set by both code paths)
            bg = (attr >> 4) & 0x0F;
        }

        g_screen_buffer_cache[i] = (int32_t)(ch | (attr << 8) | (fg << 16) | (bg << 24));
    }

    ios_ciolib_clear_dirty();
    ios_ciolib_unlock();
    pthread_mutex_unlock(&g_lock);

    *count = size;
    return g_screen_buffer_cache;
}

const int32_t* native_get_palette(int32_t *count) {
    ios_ciolib_lock();
    uint32_t *palette = ios_ciolib_get_palette();

    if (!palette) {
        ios_ciolib_unlock();
        *count = 0;
        return NULL;
    }

    for (int i = 0; i < 16; i++) {
        g_palette_cache[i] = (int32_t)palette[i];
    }

    ios_ciolib_unlock();
    *count = 16;
    return g_palette_cache;
}

void native_get_screen_size(int32_t *columns, int32_t *rows) {
    *columns = ios_ciolib_get_screen_width();
    *rows = ios_ciolib_get_screen_height();
}

void native_get_cursor_pos(int32_t *x, int32_t *y) {
    *x = ios_ciolib_get_cursor_x();
    *y = ios_ciolib_get_cursor_y();
}

bool native_is_cursor_visible(void) {
    return ios_ciolib_is_cursor_visible();
}

bool native_is_screen_dirty(void) {
    return ios_ciolib_is_dirty();
}

bool native_get_dirty_region(int32_t *minX, int32_t *minY, int32_t *maxX, int32_t *maxY) {
    ios_ciolib_lock();
    int has_dirty = ios_ciolib_get_dirty_region(minX, minY, maxX, maxY);
    ios_ciolib_unlock();
    return has_dirty;
}

// ============================================================================
// MARK: - Terminal Control Functions
// ============================================================================

void native_set_terminal_size(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || width > 1000 || height > 1000) {
        return;
    }

    pthread_mutex_lock(&g_lock);

    if (g_term_width == width && g_term_height == height) {
        pthread_mutex_unlock(&g_lock);
        return;
    }

    g_term_width = width;
    g_term_height = height;

    ios_ciolib_resize(width, height);

    if (g_cterm && g_initialized) {
        struct cterminal *old_cterm = g_cterm;
        g_cterm = NULL;
        cterm_end(old_cterm, 0);

        int scrollback_cols = width > 132 ? width : 132;
        size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);

        struct vmem_cell *old_scrollback = g_scrollback;
        g_scrollback = calloc(1, scrollback_size);

        if (g_scrollback) {
            free(old_scrollback);
            g_cterm = cterm_init(height, width, 1, 1,
                                 g_scrollback_lines, scrollback_cols,
                                 g_scrollback, CTERM_EMULATION_ANSI_BBS);
            if (g_cterm) {
                cterm_start(g_cterm);
            }
        } else {
            g_scrollback = old_scrollback;
        }
    }

    pthread_mutex_unlock(&g_lock);
}

bool native_set_font(const char *fontName) {
    if (!g_initialized || !fontName) {
        return false;
    }

    pthread_mutex_lock(&g_lock);

    int font_id = -1;
    for (int i = 0; i < 256; i++) {
        if (conio_fontdata[i].desc != NULL &&
            strcmp(conio_fontdata[i].desc, fontName) == 0) {
            font_id = i;
            break;
        }
    }

    if (font_id >= 0) {
        strncpy(g_font_name, fontName, sizeof(g_font_name) - 1);
        g_current_font_id = font_id;
        int result = ciolib_setfont(font_id, 1, 0);
        pthread_mutex_unlock(&g_lock);
        return result == 0;
    }

    pthread_mutex_unlock(&g_lock);
    return false;
}

bool native_set_font_by_id(int32_t fontId) {
    if (!g_initialized || fontId < 0 || fontId >= 256) {
        return false;
    }

    pthread_mutex_lock(&g_lock);
    g_current_font_id = fontId;
    int result = ciolib_setfont(fontId, 1, 0);
    pthread_mutex_unlock(&g_lock);

    return result == 0;
}

void native_clear_screen(void) {
    pthread_mutex_lock(&g_lock);
    if (g_cterm) {
        cterm_clearscreen(g_cterm, 7);
    }
    pthread_mutex_unlock(&g_lock);
}

void native_reset_terminal(void) {
    pthread_mutex_lock(&g_lock);
    if (g_cterm) {
        // Clear the screen
        cterm_clearscreen(g_cterm, 7);

        // Reset scrollback - clear the backfilled count so old data isn't shown
        g_cterm->backfilled = 0;

        // Clear the scrollback buffer itself
        if (g_scrollback) {
            int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
            size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);
            memset(g_scrollback, 0, scrollback_size);
        }
    }
    pthread_mutex_unlock(&g_lock);
}

void native_push_input(const uint8_t *data, int32_t count) {
    if (count <= 0) return;
    ios_ciolib_push_input_buffer(data, count);
}

void native_set_hide_status_line(bool hide) {
    pthread_mutex_lock(&g_lock);
    g_hide_status_line = hide ? 1 : 0;
    pthread_mutex_unlock(&g_lock);
}

// Declare the Swift bridge function
extern void swift_telnet_set_terminal_size(int width, int height);

void native_set_screen_mode(int32_t mode) {
    pthread_mutex_lock(&g_lock);
    g_screen_mode = mode;
    pthread_mutex_unlock(&g_lock);

    // Convert screen mode to dimensions and resize terminal
    // 0=80x25, 1=80x30, 2=80x50, 3=132x25, 4=132x50, 5=80x40
    int width = 80, height = 25;
    switch (mode) {
        case 0: width = 80;  height = 25; break;
        case 1: width = 80;  height = 30; break;
        case 2: width = 80;  height = 50; break;
        case 3: width = 132; height = 25; break;
        case 4: width = 132; height = 50; break;
        case 5: width = 80;  height = 40; break;
        default: width = 80; height = 25; break;
    }

    // Resize native terminal buffer
    native_set_terminal_size(width, height);

    // Also update TelnetConnection so NAWS reports correct size
    swift_telnet_set_terminal_size(width, height);
}

// ============================================================================
// MARK: - Status Functions
// ============================================================================

static char g_status_info[256];

const char* native_get_status_info(void) {
    if (!g_initialized) {
        snprintf(g_status_info, sizeof(g_status_info), "Not initialized");
    } else if (!g_connected) {
        snprintf(g_status_info, sizeof(g_status_info), "Disconnected");
    } else {
        snprintf(g_status_info, sizeof(g_status_info), "Connected to %s:%d (%dx%d)",
                 g_bbs_config.addr, g_bbs_config.port,
                 g_term_width, g_term_height);
    }
    return g_status_info;
}

bool native_get_connection_stats(int64_t *sent, int64_t *received,
                                  int64_t *connectTime, int64_t *currentTime) {
    pthread_mutex_lock(&g_lock);
    *sent = (int64_t)g_bytes_sent;
    *received = (int64_t)g_bytes_received;
    *connectTime = g_connect_time_ms;
    pthread_mutex_unlock(&g_lock);
    *currentTime = get_current_time_ms();
    return true;
}

// ============================================================================
// MARK: - Font Bitmap Functions
// ============================================================================

static uint8_t g_font_bitmap_cache[256 * 16 + 2];  // Max size + header

const uint8_t* native_get_font_bitmap(int32_t *width, int32_t *height, int32_t *count) {
    pthread_mutex_lock(&g_lock);

    const char *bitmap_data = NULL;
    int font_height = 16;

    // Try current font
    if (g_current_font_id >= 0 && g_current_font_id < 256) {
        if (conio_fontdata[g_current_font_id].eight_by_sixteen != NULL) {
            bitmap_data = conio_fontdata[g_current_font_id].eight_by_sixteen;
            font_height = 16;
        } else if (conio_fontdata[g_current_font_id].eight_by_fourteen != NULL) {
            bitmap_data = conio_fontdata[g_current_font_id].eight_by_fourteen;
            font_height = 14;
        } else if (conio_fontdata[g_current_font_id].eight_by_eight != NULL) {
            bitmap_data = conio_fontdata[g_current_font_id].eight_by_eight;
            font_height = 8;
        }
    }

    // Fallback to font 0
    if (bitmap_data == NULL) {
        if (conio_fontdata[0].eight_by_sixteen != NULL) {
            bitmap_data = conio_fontdata[0].eight_by_sixteen;
            font_height = 16;
        }
    }

    if (bitmap_data == NULL) {
        pthread_mutex_unlock(&g_lock);
        *count = 0;
        return NULL;
    }

    int data_size = 256 * font_height;
    int max_data = (int)sizeof(g_font_bitmap_cache) - 2;
    if (data_size > max_data) {
        data_size = max_data;
    }
    g_font_bitmap_cache[0] = 8;
    g_font_bitmap_cache[1] = (uint8_t)font_height;
    memcpy(g_font_bitmap_cache + 2, bitmap_data, data_size);

    *width = 8;
    *height = font_height;
    *count = data_size;

    pthread_mutex_unlock(&g_lock);
    return g_font_bitmap_cache + 2;  // Return pointer past header
}

// ============================================================================
// MARK: - ZMODEM Functions
// ============================================================================

bool native_is_zmodem_detected(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    bool result = g_zmodem_detected;
    pthread_mutex_unlock(&g_zmodem_lock);
    return result;
}

const uint8_t* native_get_zmodem_buffer(int32_t *count) {
    pthread_mutex_lock(&g_zmodem_lock);
    if (g_zmodem_buffer_len <= 0) {
        pthread_mutex_unlock(&g_zmodem_lock);
        *count = 0;
        return NULL;
    }
    *count = g_zmodem_buffer_len;
    pthread_mutex_unlock(&g_zmodem_lock);
    return g_zmodem_buffer;
}

void native_clear_zmodem_detected(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    g_zmodem_detected = 0;
    g_zmodem_upload_ready = 0;
    g_zmodem_buffer_len = 0;
    g_has_prev_byte = 0;
    pthread_mutex_unlock(&g_zmodem_lock);
}

int32_t native_push_zmodem_buffer(void) {
    pthread_mutex_lock(&g_zmodem_lock);

    // Don't push data back - zmodem_recv_init() sends ZRINIT on its own
    // and doesn't need to see the ZRQINIT. Pushing decoded data back into
    // conn_inbuf would cause rx_parse_cb to process it again.
    g_zmodem_buffer_len = 0;
    g_zmodem_detected = 0;
    g_has_prev_byte = 0;
    pthread_mutex_unlock(&g_zmodem_lock);
    return 0;
}

// ============================================================================
// MARK: - Upload Queue Functions
// ============================================================================

void native_queue_upload(const char *filePath) {
    if (!filePath) return;
    pthread_mutex_lock(&g_zmodem_lock);
    strncpy(g_upload_queued_file, filePath, sizeof(g_upload_queued_file) - 1);
    g_upload_file_queued = 1;
    pthread_mutex_unlock(&g_zmodem_lock);
}

bool native_is_upload_queued(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    bool result = g_upload_file_queued;
    pthread_mutex_unlock(&g_zmodem_lock);
    return result;
}

bool native_is_upload_ready(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    bool result = g_zmodem_upload_ready;
    pthread_mutex_unlock(&g_zmodem_lock);
    return result;
}

const char* native_get_queued_upload(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    if (g_upload_file_queued && g_upload_queued_file[0] != '\0') {
        pthread_mutex_unlock(&g_zmodem_lock);
        return g_upload_queued_file;
    }
    pthread_mutex_unlock(&g_zmodem_lock);
    return NULL;
}

void native_clear_upload_queue(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    g_upload_file_queued = 0;
    g_upload_queued_file[0] = '\0';
    g_zmodem_upload_ready = 0;
    pthread_mutex_unlock(&g_zmodem_lock);
}

// ============================================================================
// MARK: - Scrollback Functions
// ============================================================================

bool native_get_scrollback_info(int32_t *filled, int32_t *capacity, int32_t *columns) {
    pthread_mutex_lock(&g_lock);

    if (!g_cterm || !g_cterm->scrollback) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    *filled = g_cterm->backfilled;
    *capacity = g_cterm->backlines;
    *columns = g_cterm->backwidth;

    pthread_mutex_unlock(&g_lock);
    return true;
}

static int32_t g_scrollback_cache[132 * 100];  // Cache for scrollback

const int32_t* native_get_scrollback_buffer(int32_t offset, int32_t count, int32_t *resultCount) {
    pthread_mutex_lock(&g_lock);

    if (!g_cterm || !g_cterm->scrollback || g_cterm->backfilled <= 0) {
        pthread_mutex_unlock(&g_lock);
        *resultCount = 0;
        return NULL;
    }

    int filled = g_cterm->backfilled;
    int capacity = g_cterm->backlines;
    int cols = g_cterm->backwidth;
    int backpos = g_cterm->backpos;

    if (offset < 0 || count <= 0 || offset >= filled) {
        pthread_mutex_unlock(&g_lock);
        *resultCount = 0;
        return NULL;
    }

    if (count > filled - offset) {
        count = filled - offset;
    }

    int size = count * cols;
    if (size > (132 * 100)) {
        size = 132 * 100;
        count = size / cols;
    }

    struct vmem_cell *scrollback = g_cterm->scrollback;
    int arr_idx = 0;

    for (int line = 0; line < count && arr_idx < size; line++) {
        int lines_back = offset + line;
        int ring_idx = (backpos - 1 - lines_back + capacity * 2) % capacity;
        if (ring_idx < 0 || ring_idx >= capacity) continue;

        for (int col = 0; col < cols && arr_idx < size; col++) {
            int cell_idx = ring_idx * cols + col;
            if (cell_idx < 0 || cell_idx >= capacity * cols) continue;
            struct vmem_cell *cell = &scrollback[cell_idx];

            unsigned int ch = cell->ch & 0xFF;
            unsigned int attr = cell->legacy_attr & 0xFF;
            unsigned int fg = cell->fg & 0xFF;
            unsigned int bg = cell->bg & 0xFF;
            g_scrollback_cache[arr_idx++] = (int32_t)(ch | (attr << 8) | (fg << 16) | (bg << 24));
        }
    }

    pthread_mutex_unlock(&g_lock);
    *resultCount = arr_idx;
    return g_scrollback_cache;
}

// ============================================================================
// MARK: - Bell Detection
// ============================================================================

bool native_check_bell(void) {
    pthread_mutex_lock(&g_lock);
    int detected = g_bell_detected;
    g_bell_detected = 0;
    pthread_mutex_unlock(&g_lock);
    return detected;
}

// ============================================================================
// MARK: - Session Logging
// ============================================================================

void native_set_logging_enabled(bool enabled) {
    pthread_mutex_lock(&g_log_lock);
    g_logging_enabled = enabled ? 1 : 0;
    if (!enabled) {
        g_log_buffer_len = 0;
    }
    pthread_mutex_unlock(&g_log_lock);
}

const uint8_t* native_get_logged_data(int32_t *count) {
    pthread_mutex_lock(&g_log_lock);

    if (g_log_buffer_len <= 0) {
        pthread_mutex_unlock(&g_log_lock);
        *count = 0;
        return NULL;
    }

    *count = g_log_buffer_len;
    // Note: Caller should copy data before next call
    g_log_buffer_len = 0;

    pthread_mutex_unlock(&g_log_lock);
    return g_log_buffer;
}

// ============================================================================
// MARK: - File Transfer Functions (ZMODEM Implementation)
// ============================================================================

bool native_transfer_init(void) {
    // Initialize both the local state and ZMODEM subsystem
    g_transfer_state = 0;
    g_transfer_bytes = 0;
    g_transfer_total = 0;
    g_transfer_filename[0] = '\0';
    g_transfer_error[0] = '\0';

    return zmodem_ios_init() != 0;
}

void native_set_download_dir(const char *dir) {
    if (dir) {
        strncpy(g_download_dir, dir, sizeof(g_download_dir) - 1);
        g_download_dir[sizeof(g_download_dir) - 1] = '\0';
        zmodem_ios_set_download_dir(dir);
    }
}

int32_t native_zmodem_receive(void) {
    // Clear ZMODEM detected flag since we're handling it
    pthread_mutex_lock(&g_zmodem_lock);
    g_zmodem_detected = 0;
    pthread_mutex_unlock(&g_zmodem_lock);

    int result = zmodem_ios_receive();
    return (int32_t)result;
}

int32_t native_zmodem_send(const char *filePath) {
    if (!filePath) {
        return -1;
    }

    int result = zmodem_ios_send(filePath);
    return (int32_t)result;
}

void native_transfer_cancel(void) {
    zmodem_ios_cancel();
}

int32_t native_get_transfer_state(void) {
    return (int32_t)zmodem_ios_get_state();
}

bool native_get_transfer_progress(int64_t *transferred, int64_t *total) {
    zmodem_ios_get_progress(transferred, total);
    return true;
}

const char* native_get_transfer_file_name(void) {
    const char* filename = zmodem_ios_get_filename();
    if (filename && filename[0]) {
        return filename;
    }
    return NULL;
}

const char* native_get_transfer_error(void) {
    const char* error = zmodem_ios_get_error();
    if (error && error[0]) {
        return error;
    }
    return NULL;
}

void native_transfer_reset(void) {
    zmodem_ios_reset();

    // Also reset local state
    g_transfer_state = 0;
    g_transfer_bytes = 0;
    g_transfer_total = 0;
    g_transfer_filename[0] = '\0';
    g_transfer_error[0] = '\0';
}

void native_transfer_cleanup(void) {
    zmodem_ios_cleanup();
    native_transfer_reset();
}

// ============================================================================
// Fast C-based terminal rendering
// ============================================================================

/**
 * Render the terminal screen to a pixel buffer.
 * This is MUCH faster than doing the pixel loop in Swift.
 *
 * @param pixels Output pixel buffer (BGRA format, must be cellWidth*cols * cellHeight*rows * 4 bytes)
 * @param screenBuffer Screen buffer (packed: ch | attr<<8 | fg<<16 | bg<<24)
 * @param cols Number of columns
 * @param rows Number of rows
 * @param cellWidth Width of each cell in pixels (scaled)
 * @param cellHeight Height of each cell in pixels (scaled)
 * @param fontData Font bitmap data (1 bit per pixel, 8 pixels per row)
 * @param fontWidth Native font width (typically 8)
 * @param fontHeight Native font height (typically 16)
 * @param palette 16-entry color palette (RGB format: 0x00RRGGBB)
 */
void native_render_terminal(uint8_t *pixels,
                            int pixelBufferSize,
                            const int32_t *screenBuffer,
                            int screenBufferCount,
                            int cols, int rows,
                            int cellWidth, int cellHeight,
                            const uint8_t *fontData,
                            int fontDataSize,
                            int fontWidth, int fontHeight,
                            const uint32_t *palette) {
    if (!pixels || !screenBuffer || !fontData || !palette) return;
    if (cols <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0) return;
    if (fontWidth <= 0 || fontHeight <= 0) return;

    // Integer overflow checks on pixel dimensions
    if (cols > 10000 || rows > 10000 || cellWidth > 100 || cellHeight > 100) return;
    int termWidthPx = cols * cellWidth;
    int termHeightPx = rows * cellHeight;
    int requiredPixelBytes = termWidthPx * termHeightPx * 4;
    if (requiredPixelBytes <= 0 || requiredPixelBytes > pixelBufferSize) return;
    if (cols * rows > screenBufferCount) return;

    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < cols; col++) {
            int idx = row * cols + col;
            uint32_t cell = (uint32_t)screenBuffer[idx];

            int charCode = cell & 0xFF;
            int fgIndex = (cell >> 16) & 0x0F;
            int bgIndex = (cell >> 24) & 0x0F;

            // Get colors from palette (0x00RRGGBB format)
            uint32_t fgColor = palette[fgIndex];
            uint32_t bgColor = palette[bgIndex];

            // Extract RGB components
            uint8_t fgR = (fgColor >> 16) & 0xFF;
            uint8_t fgG = (fgColor >> 8) & 0xFF;
            uint8_t fgB = fgColor & 0xFF;
            uint8_t bgR = (bgColor >> 16) & 0xFF;
            uint8_t bgG = (bgColor >> 8) & 0xFF;
            uint8_t bgB = bgColor & 0xFF;

            // Glyph offset in font bitmap
            int glyphOffset = charCode * fontHeight;
            if (glyphOffset + fontHeight > fontDataSize) continue;

            // Cell position in output buffer
            int cellStartX = col * cellWidth;
            int cellStartY = row * cellHeight;

            // Render scaled glyph
            for (int destY = 0; destY < cellHeight; destY++) {
                // Center-sampling: ((2 * destY + 1) * fontHeight) / (2 * cellHeight)
                // This samples from pixel centers, avoiding empty scanlines at glyph boundaries
                int srcY = ((2 * destY + 1) * fontHeight) / (2 * cellHeight);
                if (srcY >= fontHeight) srcY = fontHeight - 1;

                uint8_t rowByte = fontData[glyphOffset + srcY];

                int termY = cellStartY + destY;
                int rowStart = termY * termWidthPx;

                for (int destX = 0; destX < cellWidth; destX++) {
                    // Center-sampling for X
                    int srcX = ((2 * destX + 1) * fontWidth) / (2 * cellWidth);
                    if (srcX >= fontWidth) srcX = fontWidth - 1;

                    int bitIndex = 7 - srcX;
                    int isSet = (rowByte >> bitIndex) & 1;

                    int termX = cellStartX + destX;
                    int pixelIdx = (rowStart + termX) * 4;

                    // Write BGRA (CGImage noneSkipFirst + byteOrder32Little expects B,G,R,X)
                    if (isSet) {
                        pixels[pixelIdx + 0] = fgB;
                        pixels[pixelIdx + 1] = fgG;
                        pixels[pixelIdx + 2] = fgR;
                        pixels[pixelIdx + 3] = 0xFF;
                    } else {
                        pixels[pixelIdx + 0] = bgB;
                        pixels[pixelIdx + 1] = bgG;
                        pixels[pixelIdx + 2] = bgR;
                        pixels[pixelIdx + 3] = 0xFF;
                    }
                }
            }
        }
    }
}
