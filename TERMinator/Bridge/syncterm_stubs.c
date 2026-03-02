/**
 * SyncTERM Stub Implementations for iOS
 *
 * Provides stub implementations of SyncTERM functions.
 * Connection functions now delegate to Swift TelnetConnection
 * via the swift_telnet_* bridge functions.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdbool.h>
#include <pthread.h>

#include "ciolib.h"
#include "cterm.h"
#include "gen_defs.h"
#include "bbslist.h"
#include "conn.h"

// ============================================================================
// Swift Bridge Function Declarations
// ============================================================================

// These are implemented in TelnetConnection.swift via @_cdecl
extern void swift_telnet_set_terminal_size(int width, int height);
extern bool swift_telnet_connect(const char *host, int port);
extern void swift_telnet_disconnect(void);
extern bool swift_telnet_is_connected(void);
extern int swift_telnet_send(const unsigned char *data, int length);
extern int swift_telnet_send_byte(unsigned char byte);
extern int swift_telnet_data_waiting(void);
extern int swift_telnet_receive(unsigned char *buffer, int maxLength);

// These are implemented in SSHConnection.swift via @_cdecl
extern bool swift_ssh_connect(const char *host, int port, const char *username, const char *password);
extern bool swift_ssh_connect_with_key(const char *host, int port, const char *username,
                                        const char *privateKey, const char *publicKey, const char *passphrase);
extern void swift_ssh_disconnect(void);
extern bool swift_ssh_is_connected(void);
extern int swift_ssh_send(const unsigned char *data, int length);
extern int swift_ssh_send_byte(unsigned char byte);
extern int swift_ssh_data_waiting(void);
extern int swift_ssh_receive(unsigned char *buffer, int maxLength);
extern void swift_ssh_set_terminal_size(int width, int height);

// Font data is provided by allfonts.c - declared as extern here
extern struct conio_font_data_struct conio_fontdata[257];

// ============================================================================
// Connection Functions - Now provided by SyncTERM's conn.c
// ============================================================================

/* Note: Connection functions are now provided by conn.c from SyncTERM.
 * The Swift bridge integrates at a higher level via the terminal view model.
 * These stub implementations are kept for reference but commented out.
 */

#if 0  // Connection stubs - replaced by conn.c
bool conn_connect(struct bbslist *bbs) {
    if (!bbs) return false;

    bool success = false;
    g_current_conn_type = bbs->conn_type;

    if (bbs->conn_type == CONN_TYPE_SSH) {
        printf("[conn_connect] Connecting via SSH to %s:%d as %s\n",
               bbs->addr, bbs->port, bbs->user);
        success = swift_ssh_connect(bbs->addr, bbs->port, bbs->user, bbs->password);
    } else {
        printf("[conn_connect] Connecting via Telnet to %s:%d\n", bbs->addr, bbs->port);
        success = swift_telnet_connect(bbs->addr, bbs->port);
    }

    return success;
}

int conn_close(void) {
    if (g_current_conn_type == CONN_TYPE_SSH) {
        swift_ssh_disconnect();
    } else {
        swift_telnet_disconnect();
    }
    return 0;
}

bool conn_connected(void) {
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return swift_ssh_is_connected();
    } else {
        return swift_telnet_is_connected();
    }
}

size_t conn_data_waiting(void) {
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return (size_t)swift_ssh_data_waiting();
    } else {
        return (size_t)swift_telnet_data_waiting();
    }
}

int conn_recv_upto(void *buf, size_t buflen, unsigned int timeout) {
    (void)timeout;
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return swift_ssh_receive((unsigned char *)buf, (int)buflen);
    } else {
        return swift_telnet_receive((unsigned char *)buf, (int)buflen);
    }
}

int conn_send(const void *buf, size_t len, unsigned int timeout) {
    (void)timeout;
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return swift_ssh_send((const unsigned char *)buf, (int)len);
    } else {
        return swift_telnet_send((const unsigned char *)buf, (int)len);
    }
}
#endif  // Connection stubs

// ============================================================================
// CTerm Stubs
// ============================================================================

// Global cterm instance
static struct cterminal *g_cterm = NULL;

struct cterminal *cterm_init(int height, int width, int xpos, int ypos,
                             int backlines, int backcols,
                             struct vmem_cell *scrollback,
                             int emulation) {
    if (g_cterm == NULL) {
        g_cterm = calloc(1, sizeof(struct cterminal));
    }
    // Always update dimensions (fix for resize not working)
    if (g_cterm) {
        g_cterm->height = height;
        g_cterm->width = width;
        g_cterm->x = xpos;
        g_cterm->y = ypos;
        g_cterm->backlines = backlines;
        g_cterm->backwidth = backcols;
        g_cterm->scrollback = scrollback;
        g_cterm->emulation = emulation;
    }
    return g_cterm;
}

void cterm_start(struct cterminal *cterm) {
    if (cterm) {
        cterm->started = true;
    }
}

void cterm_end(struct cterminal *cterm, int free_fonts) {
    if (cterm) {
        cterm->started = false;
    }
    (void)free_fonts;  // Unused in stub
}

// Simple ANSI state machine for basic terminal emulation
// States: 0=normal, 1=got ESC, 2=in CSI, 3=in OSC, 4=OSC got ESC (awaiting \)
static int ansi_state = 0;
static char ansi_params[64];
static int ansi_param_len = 0;

// OSC accumulation buffer (for OSC 800 / TAP and other OSC sequences)
#define OSC_BUFFER_SIZE 4096
static char osc_buffer[OSC_BUFFER_SIZE];
static int osc_buffer_len = 0;

// Forward declaration - implemented in syncterm_ios.c
extern void ios_audio_command(const char *cmd, int len);

// Dispatch completed OSC sequence
static void dispatch_osc(void) {
    if (osc_buffer_len <= 0) return;
    osc_buffer[osc_buffer_len] = '\0';

    // Check for OSC 800 (TAP audio command)
    if (osc_buffer_len > 4 && strncmp(osc_buffer, "800;", 4) == 0) {
        ios_audio_command(osc_buffer + 4, osc_buffer_len - 4);
    }
    // Other OSC sequences can be handled here in the future

    osc_buffer_len = 0;
}

// Response buffer for ANSI queries (like cursor position report)
static char ansi_response[64];
static int ansi_response_len = 0;

// Saved cursor position for ESC[s / ESC[u
static int saved_cursor_x = 1;
static int saved_cursor_y = 1;

// Last printed character for ESC[b (REP - repeat previous character)
unsigned char cterm_last_printed_char = 0;

// ANSI color to CGA palette index mapping
// ANSI: 0=Black, 1=Red, 2=Green, 3=Yellow, 4=Blue, 5=Magenta, 6=Cyan, 7=White
// CGA:  0=Black, 1=Blue, 2=Green, 3=Cyan, 4=Red, 5=Magenta, 6=Brown, 7=LightGray
static const int ansi_to_cga[8] = {0, 4, 2, 6, 1, 5, 3, 7};

// iCE mode state - when enabled, background colors should be bright (add 8)
// This persists across SGR commands until reset (SGR 0)
static int ice_mode_enabled = 0;

// Bold/bright mode state - when enabled, foreground colors should be bright (add 8)
// This persists across SGR commands until reset (SGR 0)
static int bold_mode_enabled = 0;

// Underline mode state - tracks ESC[4m / ESC[24m
static int underline_enabled = 0;

// Reset ANSI parser state for clean connection
void cterm_reset_ansi_state(void) {
    ansi_state = 0;
    ansi_param_len = 0;
    ansi_response_len = 0;
    ice_mode_enabled = 0;
    bold_mode_enabled = 0;
    underline_enabled = 0;
    saved_cursor_x = 1;
    saved_cursor_y = 1;
    osc_buffer_len = 0;
    cterm_last_printed_char = 0;
}

static void process_ansi_sequence(void) {
    // Parse CSI parameters
    int params[16] = {0};
    int param_count = 0;
    int has_digits = 0;

    // Parse parameters from ansi_params buffer (excludes the final command char)
    for (int i = 0; i < ansi_param_len; i++) {
        char c = ansi_params[i];
        if (c >= '0' && c <= '9') {
            if (params[param_count] <= 100000)
                params[param_count] = params[param_count] * 10 + (c - '0');
            has_digits = 1;
        } else if (c == ';') {
            if (param_count < 15) param_count++;
            has_digits = 0;
        } else if (c >= '@') {
            // Command character - stop parsing
            break;
        }
    }
    // Count the last parameter if we had digits
    if (has_digits || param_count > 0) {
        param_count++;
    }

    // Get the command character (last char in buffer)
    char cmd = 0;
    for (int i = ansi_param_len - 1; i >= 0; i--) {
        if (ansi_params[i] >= '@' && ansi_params[i] <= '~') {
            cmd = ansi_params[i];
            break;
        }
    }

    switch (cmd) {
        case 'H': case 'f':  // Cursor position
            {
                int target_x = params[1] > 0 ? params[1] : 1;
                int target_y = params[0] > 0 ? params[0] : 1;
                ciolib_gotoxy(target_x, target_y);
            }
            break;
        case 'A':  // Cursor up - clamp to top of screen
            { int y = ciolib_wherey() - (params[0] > 0 ? params[0] : 1);
              if (y < 1) y = 1;
              ciolib_gotoxy(ciolib_wherex(), y); }
            break;
        case 'B':  // Cursor down - clamp to bottom of screen
            { struct text_info bti;
              ciolib_gettextinfo(&bti);
              int y = ciolib_wherey() + (params[0] > 0 ? params[0] : 1);
              if (y > bti.screenheight) y = bti.screenheight;
              ciolib_gotoxy(ciolib_wherex(), y); }
            break;
        case 'C':  // Cursor forward - clamp to right edge
            { struct text_info cti;
              ciolib_gettextinfo(&cti);
              int x = ciolib_wherex() + (params[0] > 0 ? params[0] : 1);
              if (x > cti.screenwidth) x = cti.screenwidth;
              ciolib_gotoxy(x, ciolib_wherey()); }
            break;
        case 'D':  // Cursor back
            { int x = ciolib_wherex() - (params[0] > 0 ? params[0] : 1);
              if (x < 1) x = 1;
              ciolib_gotoxy(x, ciolib_wherey()); }
            break;
        case 'J':  // Erase in Display
            if (params[0] == 0 || param_count == 0) {
                // ESC[0J or ESC[J - Clear from cursor to end of screen
                ciolib_clreol();  // Clear rest of current line
                {
                    struct text_info jti;
                    ciolib_gettextinfo(&jti);
                    int saved_x = ciolib_wherex();
                    int saved_y = ciolib_wherey();
                    for (int line = saved_y + 1; line <= jti.screenheight; line++) {
                        ciolib_gotoxy(1, line);
                        ciolib_clreol();
                    }
                    ciolib_gotoxy(saved_x, saved_y);
                }
            } else if (params[0] == 1) {
                // ESC[1J - Clear from start of screen to cursor
                {
                    struct text_info jti;
                    ciolib_gettextinfo(&jti);
                    int saved_x = ciolib_wherex();
                    int saved_y = ciolib_wherey();
                    for (int line = 1; line < saved_y; line++) {
                        ciolib_gotoxy(1, line);
                        ciolib_clreol();
                    }
                    // Clear current line from start to cursor
                    ciolib_gotoxy(1, saved_y);
                    for (int i = 1; i <= saved_x; i++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(saved_x, saved_y);
                }
            } else if (params[0] == 2) {
                // ESC[2J - Clear entire screen
                ciolib_clrscr();
            }
            break;
        case 'K':  // Erase in Line
            if (params[0] == 0 || param_count == 0) {
                // ESC[0K or ESC[K - Clear from cursor to end of line
                ciolib_clreol();
            } else if (params[0] == 1) {
                // ESC[1K - Clear from start of line to cursor
                {
                    int saved_x = ciolib_wherex();
                    int cur_y = ciolib_wherey();
                    ciolib_gotoxy(1, cur_y);
                    for (int i = 1; i <= saved_x; i++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(saved_x, cur_y);
                }
            } else if (params[0] == 2) {
                // ESC[2K - Clear entire line
                {
                    int saved_x = ciolib_wherex();
                    int cur_y = ciolib_wherey();
                    ciolib_gotoxy(1, cur_y);
                    ciolib_clreol();
                    ciolib_gotoxy(saved_x, cur_y);
                }
            }
            break;
        case 'm':  // SGR - Set Graphics Rendition
            if (param_count == 0) {
                // ESC[m with no params means reset
                ciolib_textattr(7);
                ice_mode_enabled = 0;
                bold_mode_enabled = 0;
                underline_enabled = 0;
                ciolib_setunderline(false);
            }
            for (int i = 0; i < param_count; i++) {
                int p = params[i];
                if (p == 0) {
                    ciolib_textattr(7);  // Reset
                    ice_mode_enabled = 0;
                    bold_mode_enabled = 0;
                    underline_enabled = 0;
                    ciolib_setunderline(false);
                }
                else if (p == 1) {
                    // Bold/bright - enable bright foreground mode
                    bold_mode_enabled = 1;
                    ciolib_highvideo();  // Also brighten current foreground
                }
                else if (p == 2 || p == 22) {
                    // Dim or normal intensity - disable bold
                    bold_mode_enabled = 0;
                    ciolib_lowvideo();
                }
                else if (p == 4) {
                    // Underline
                    underline_enabled = 1;
                    ciolib_setunderline(true);
                }
                else if (p == 5) {
                    // Blink/iCE mode - enable bright backgrounds
                    ice_mode_enabled = 1;
                    ciolib_brightbackground();  // Also brighten current background
                }
                else if (p == 7) ciolib_reversevideo();  // Reverse video - swap fg/bg
                else if (p == 24) {
                    // SGR 24 - disable underline
                    underline_enabled = 0;
                    ciolib_setunderline(false);
                }
                else if (p == 25) {
                    // SGR 25 - disable blink/iCE mode
                    ice_mode_enabled = 0;
                }
                else if (p >= 30 && p <= 37) {
                    // Map ANSI color to CGA palette index
                    int fg = ansi_to_cga[p - 30];
                    // If bold mode is enabled, add 8 for bright foreground
                    if (bold_mode_enabled && fg < 8) {
                        fg += 8;
                    }
                    ciolib_textcolor(fg);
                }
                else if (p >= 40 && p <= 47) {
                    // Map ANSI color to CGA palette index
                    int bg = ansi_to_cga[p - 40];
                    // If iCE mode is enabled, add 8 for bright background
                    if (ice_mode_enabled && bg < 8) {
                        bg += 8;
                    }
                    ciolib_textbackground(bg);
                }
                else if (p >= 90 && p <= 97) {
                    // Bright FG colors - map and add 8 for bright
                    ciolib_textcolor(ansi_to_cga[p - 90] + 8);
                }
                else if (p >= 100 && p <= 107) {
                    // Bright BG colors - map and add 8 for bright
                    ciolib_textbackground(ansi_to_cga[p - 100] + 8);
                }
            }
            break;
        case 's':  // Save cursor position
            saved_cursor_x = ciolib_wherex();
            saved_cursor_y = ciolib_wherey();
            break;
        case 'u':  // Restore cursor position
            ciolib_gotoxy(saved_cursor_x, saved_cursor_y);
            break;
        case 'n':  // Device Status Report
            if (params[0] == 6) {
                // Cursor Position Report - respond with ESC[row;colR
                int row = ciolib_wherey();
                int col = ciolib_wherex();
                ansi_response_len = snprintf(ansi_response, sizeof(ansi_response),
                                             "\033[%d;%dR", row, col);
            } else if (params[0] == 5) {
                // Device Status Report - respond "OK"
                ansi_response_len = snprintf(ansi_response, sizeof(ansi_response), "\033[0n");
            }
            break;
        case 'c':  // Device Attributes
            // Respond as VT102 - this tells the BBS we're an ANSI terminal
            ansi_response_len = snprintf(ansi_response, sizeof(ansi_response), "\033[?6c");
            break;
        case 'G': case '`':  // CHA/HPA - Cursor Horizontal Absolute
            {
                int col = params[0] > 0 ? params[0] : 1;
                ciolib_gotoxy(col, ciolib_wherey());
            }
            break;
        case 'd':  // VPA - Cursor Vertical Absolute (line position)
            {
                int row = params[0] > 0 ? params[0] : 1;
                ciolib_gotoxy(ciolib_wherex(), row);
            }
            break;
        case 'E':  // CNL - Cursor Next Line (move down N lines, to column 1)
            {
                struct text_info eti;
                ciolib_gettextinfo(&eti);
                int n = params[0] > 0 ? params[0] : 1;
                int y = ciolib_wherey() + n;
                if (y > eti.screenheight) y = eti.screenheight;
                ciolib_gotoxy(1, y);
            }
            break;
        case 'F':  // CPL - Cursor Previous Line (move up N lines, to column 1)
            {
                int n = params[0] > 0 ? params[0] : 1;
                int y = ciolib_wherey() - n;
                if (y < 1) y = 1;
                ciolib_gotoxy(1, y);
            }
            break;
        case 'L':  // IL - Insert Line(s)
            {
                int n = params[0] > 0 ? params[0] : 1;
                for (int j = 0; j < n; j++) {
                    ciolib_insline();
                }
            }
            break;
        case 'M':  // DL - Delete Line(s)
            {
                int n = params[0] > 0 ? params[0] : 1;
                for (int j = 0; j < n; j++) {
                    ciolib_delline();
                }
            }
            break;
        case '@':  // ICH - Insert Character(s) (shift line right, insert blanks)
            {
                int n = params[0] > 0 ? params[0] : 1;
                struct text_info ati;
                ciolib_gettextinfo(&ati);
                int cx = ciolib_wherex();
                int cy = ciolib_wherey();
                int w = ati.screenwidth;
                if (cx <= w) {
                    int line_len = w - cx + 1;
                    if (n < line_len) {
                        ciolib_movetext(cx, cy, w - n, cy, cx + n, cy);
                    }
                    // Fill inserted area with spaces
                    ciolib_gotoxy(cx, cy);
                    for (int j = 0; j < n && cx + j <= w; j++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(cx, cy);
                }
            }
            break;
        case 'P':  // DCH - Delete Character(s) (shift line left, blank at end)
            {
                int n = params[0] > 0 ? params[0] : 1;
                struct text_info pti;
                ciolib_gettextinfo(&pti);
                int cx = ciolib_wherex();
                int cy = ciolib_wherey();
                int w = pti.screenwidth;
                if (cx <= w) {
                    int chars_remaining = w - cx + 1;
                    if (n < chars_remaining) {
                        // Shift chars left
                        ciolib_movetext(cx + n, cy, w, cy, cx, cy);
                    }
                    // Fill end of line with spaces
                    int blank_start = w - n + 1;
                    if (blank_start < cx) blank_start = cx;
                    int save_x = ciolib_wherex();
                    int save_y = ciolib_wherey();
                    ciolib_gotoxy(blank_start, cy);
                    for (int j = blank_start; j <= w; j++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(save_x, save_y);
                }
            }
            break;
        case 'X':  // ECH - Erase Character(s) (overwrite with spaces, don't move cursor)
            {
                int n = params[0] > 0 ? params[0] : 1;
                struct text_info xti;
                ciolib_gettextinfo(&xti);
                int cx = ciolib_wherex();
                int cy = ciolib_wherey();
                for (int j = 0; j < n && cx + j <= xti.screenwidth; j++) {
                    ciolib_gotoxy(cx + j, cy);
                    ciolib_putch(' ');
                }
                ciolib_gotoxy(cx, cy);
            }
            break;
        case 'S':  // SU - Scroll Up
            {
                int n = params[0] > 0 ? params[0] : 1;
                for (int j = 0; j < n; j++) {
                    ciolib_wscroll();
                }
            }
            break;
        case 'T':  // SD - Scroll Down (reverse scroll)
            {
                struct text_info tti;
                ciolib_gettextinfo(&tti);
                int n = params[0] > 0 ? params[0] : 1;
                // Save cursor, go to top, insert lines, restore cursor
                int save_x = ciolib_wherex();
                int save_y = ciolib_wherey();
                ciolib_gotoxy(1, 1);
                for (int j = 0; j < n; j++) {
                    ciolib_insline();
                }
                ciolib_gotoxy(save_x, save_y);
            }
            break;
        case 'b':  // REP - Repeat previous graphic character
            {
                int n = params[0] > 0 ? params[0] : 1;
                if (cterm_last_printed_char != 0) {
                    for (int j = 0; j < n; j++) {
                        ciolib_putch(cterm_last_printed_char);
                    }
                }
            }
            break;
        default:
            break;
    }
}

size_t cterm_write(struct cterminal *cterm, const void *buf, int buflen,
                   char *retbuf, size_t retsize, int *speed) {
    if (speed) *speed = 0;
    if (retbuf && retsize > 0) retbuf[0] = '\0';
    ansi_response_len = 0;  // Clear any previous response

    const unsigned char *data = (const unsigned char *)buf;

    for (int i = 0; i < buflen; i++) {
        unsigned char c = data[i];

        switch (ansi_state) {
            case 0:  // Normal state
                if (c == 27) {  // ESC
                    ansi_state = 1;
                } else if (c == 0x9B) {
                    // 8-bit CSI (used by Amiga terminals instead of ESC[)
                    ansi_state = 2;
                    ansi_param_len = 0;
                    memset(ansi_params, 0, sizeof(ansi_params));
                } else if (c == '\r') {
                    ciolib_gotoxy(1, ciolib_wherey());
                } else if (c == '\n') {
                    int y = ciolib_wherey();
                    struct text_info ti;
                    ciolib_gettextinfo(&ti);
                    if (y >= ti.screenheight) {
                        ciolib_wscroll();
                    } else {
                        ciolib_gotoxy(ciolib_wherex(), y + 1);
                    }
                } else if (c == '\b') {
                    int x = ciolib_wherex();
                    if (x > 1) ciolib_gotoxy(x - 1, ciolib_wherey());
                } else if (c == '\t') {
                    int x = ciolib_wherex();
                    int next_tab = ((x - 1) / 8 + 1) * 8 + 1;
                    ciolib_gotoxy(next_tab, ciolib_wherey());
                } else if (c == 7) {
                    // Bell - handled elsewhere
                } else if (c == 0) {
                    // NUL - ignore (telnet sends CR+NUL for bare carriage return)
                } else {
                    // All printable characters including CP437 graphics (0x01-0x1F)
                    // In CP437, characters 1-31 have graphical glyphs
                    ciolib_putch(c);
                    cterm_last_printed_char = c;
                }
                break;

            case 1:  // Got ESC
                if (c == '[') {
                    ansi_state = 2;
                    ansi_param_len = 0;
                    memset(ansi_params, 0, sizeof(ansi_params));
                } else if (c == ']') {
                    // Start OSC sequence (ESC])
                    ansi_state = 3;
                    osc_buffer_len = 0;
                } else {
                    ansi_state = 0;
                }
                break;

            case 2:  // In CSI sequence
                if (c >= '@' && c <= '~') {
                    // Final character
                    if (ansi_param_len < (int)sizeof(ansi_params) - 1) {
                        ansi_params[ansi_param_len++] = c;
                    }
                    process_ansi_sequence();
                    ansi_state = 0;
                } else if (c >= 0x20 && c <= 0x3F) {
                    // Parameter byte
                    if (ansi_param_len < (int)sizeof(ansi_params) - 1) {
                        ansi_params[ansi_param_len++] = c;
                    } else {
                        // Sequence too long - discard as malformed
                        ansi_state = 0;
                        ansi_param_len = 0;
                    }
                } else {
                    // Invalid, reset
                    ansi_state = 0;
                }
                break;

            case 3:  // In OSC sequence - accumulating characters
                if (c == 0x07) {
                    // BEL terminates OSC (xterm-style)
                    dispatch_osc();
                    ansi_state = 0;
                } else if (c == 27) {
                    // ESC - might be start of ST (ESC\)
                    ansi_state = 4;
                } else {
                    // Accumulate character
                    if (osc_buffer_len < OSC_BUFFER_SIZE - 1) {
                        osc_buffer[osc_buffer_len++] = (char)c;
                    } else {
                        // Buffer overflow - abort OSC
                        osc_buffer_len = 0;
                        ansi_state = 0;
                    }
                }
                break;

            case 4:  // OSC got ESC - awaiting backslash for ST (ESC\)
                if (c == '\\') {
                    // ST complete - dispatch OSC
                    dispatch_osc();
                } else {
                    // Not a valid ST - abort OSC
                    osc_buffer_len = 0;
                }
                ansi_state = 0;
                break;
        }
    }

    // Copy any ANSI response to retbuf (for cursor position reports, device attributes, etc.)
    if (ansi_response_len > 0 && retbuf && retsize > 0) {
        int copy_len = ansi_response_len;
        if (copy_len >= (int)retsize) {
            copy_len = (int)retsize - 1;
        }
        memcpy(retbuf, ansi_response, copy_len);
        retbuf[copy_len] = '\0';
        ansi_response_len = 0;  // Clear after copying
    }

    return 0;
}

void cterm_clearscreen(struct cterminal *cterm, char attr) {
    // Stub - actual clear handled in iOS ciolib implementation
    (void)cterm;
    (void)attr;
}

// ============================================================================
// Utility Functions
// ============================================================================

// Note: safe_snprintf() is now provided by xpdev/genwrap.c
