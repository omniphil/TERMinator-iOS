/**
 * ios_stubs.c - iOS-specific stub implementations for SyncTERM
 *
 * Provides stub implementations of UI and platform-specific functions
 * required by the SyncTERM codebase but not needed on iOS.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include "gen_defs.h"

// Forward declarations for iOS-specific functions
extern const char* ios_get_documents_directory(void);

// ============================================================================
// File Path Functions
// ============================================================================

// SYNCTERM path type enum values (must match syncterm.h)
// These are defined here to avoid circular includes
enum {
    IOS_SYNCTERM_PATH_INI = 0,
    IOS_SYNCTERM_PATH_LIST = 1,
    IOS_SYNCTERM_DEFAULT_TRANSFER_PATH = 2,
    IOS_SYNCTERM_PATH_CACHE = 3,
    IOS_SYNCTERM_PATH_KEYS = 4,
    IOS_SYNCTERM_PATH_SYSTEM_CACHE = 5
};

static char g_ios_files_dir[1024] = "";

void ios_set_files_dir(const char *path) {
    if (path) {
        strncpy(g_ios_files_dir, path, sizeof(g_ios_files_dir) - 1);
        g_ios_files_dir[sizeof(g_ios_files_dir) - 1] = '\0';
    }
}

char *get_syncterm_filename(char *fn, int fnlen, int type, bool shared) {
    const char *filename = NULL;
    (void)shared;  // Unused on iOS

    switch (type) {
        case IOS_SYNCTERM_PATH_KEYS:  // 4
            filename = "ssh_keys.p15";  // SSH key storage
            break;
        case IOS_SYNCTERM_PATH_INI:  // 0
            filename = "syncterm.ini";
            break;
        case IOS_SYNCTERM_PATH_LIST:  // 1
            filename = "bbslist.ini";
            break;
        default:
            filename = "unknown";
            break;
    }

    if (g_ios_files_dir[0] != '\0') {
        snprintf(fn, fnlen, "%s/%s", g_ios_files_dir, filename);
    } else {
        // Fallback - try to use a reasonable default
        snprintf(fn, fnlen, "/tmp/%s", filename);
    }

    return fn;
}

// ============================================================================
// UI Stub Functions
// ============================================================================

// These are called by SyncTERM but we handle UI differently on iOS

int uifcmsg(const char *msg, const char *helptext) {
    (void)helptext;
    printf("[SyncTERM] Message: %s\n", msg ? msg : "(null)");
    return 0;
}

int uifcinput(const char *title, int maxlen, char *buf, int mode, const char *help) {
    (void)title;
    (void)maxlen;
    (void)buf;
    (void)mode;
    (void)help;
    return -1;  // Cancelled
}

int uifcyesno(const char *title, const char *question) {
    (void)title;
    printf("[SyncTERM] Question: %s\n", question ? question : "(null)");
    return 0;  // No by default
}

void uifcbail(void) {
    // Nothing to do on iOS
}

int uifcinit(void) {
    return 0;
}

// ============================================================================
// Window/UI Stub Functions
// ============================================================================

// Note: win_t is defined in uifc.h

// ============================================================================
// Sound/Beep Stub Functions
// ============================================================================

void xp_beep(unsigned int freq, unsigned int dur) {
    (void)freq;
    (void)dur;
    // Bell is handled in Swift via BellManager
}

void xptone_open(void) {
    // Nothing needed
}

void xptone_close(void) {
    // Nothing needed
}

int xptone(double freq, int dur, int device) {
    (void)freq;
    (void)dur;
    (void)device;
    return 0;
}

// ============================================================================
// Serial Port Stub Functions (not used on iOS)
// ============================================================================

int comOpen(const char *device) {
    (void)device;
    return -1;
}

int comClose(int port) {
    (void)port;
    return -1;
}

int comReadByte(int port) {
    (void)port;
    return -1;
}

int comWriteByte(int port, unsigned char byte) {
    (void)port;
    (void)byte;
    return -1;
}

// ============================================================================
// Miscellaneous Stub Functions
// ============================================================================

// Popup dialogs - we don't use these on iOS
void popupmsg(const char *msg, int wait) {
    (void)wait;
    printf("[Popup] %s\n", msg ? msg : "(null)");
}

// Status line updates
void update_status_line(const char *status) {
    printf("[Status] %s\n", status ? status : "(null)");
}

// Get terminal type string
const char *get_terminal_type(void) {
    return "ANSI";
}

// Logging function
void lprintf(int level, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    printf("[Log %d] ", level);
    vprintf(fmt, args);
    printf("\n");
    va_end(args);
}

// Note: mkpath() is now provided by xpdev/dirwrap.c

// ============================================================================
// Connection Type Stubs (not supported on iOS)
// ============================================================================

// Modem connections - not supported on iOS
int modem_connect(void *bbs) {
    (void)bbs;
    return -1;
}

int modem_close(void) {
    return -1;
}

// PTY connections - not supported on iOS
int pty_connect(void *bbs) {
    (void)bbs;
    return -1;
}

int pty_close(void) {
    return -1;
}

// RLogin connections - implemented in rlogin.c (not stubbed)
// The real implementations handle Telnet as well via shared thread code

// Serial connections - not supported on iOS
int serial_close(void) {
    return -1;
}

// Telnet+TLS (TelnetS) - uses socketpair + NWConnection TLS proxy in Swift
#include "conn.h"
#include "conn_telnet.h"
#include "rlogin.h"

// From telnet_io.h (can't include directly due to sbbs3/telnet.h type conflicts)
extern unsigned char telnet_local_option[0x100];
extern unsigned char telnet_remote_option[0x100];

extern int telnet_log_level;

// Swift bridge functions for TelnetS
extern int swift_telnets_connect(const char *host, int port);
extern void swift_telnets_disconnect(void);

int telnets_connect(void *arg) {
    struct bbslist *bbs = (struct bbslist *)arg;

    telnet_log_level = bbs->telnet_loglevel;

    // Call Swift to establish TLS connection and get socketpair fd
    int fd = swift_telnets_connect(bbs->addr, bbs->port);
    if (fd < 0)
        return -1;

    rlogin_sock = fd;

    // Create connection buffers (same as telnet_connect)
    if (!create_conn_buf(&conn_inbuf, BUFFER_SIZE)) {
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }
    if (!create_conn_buf(&conn_outbuf, BUFFER_SIZE)) {
        destroy_conn_buf(&conn_inbuf);
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }

    conn_api.rd_buf = (unsigned char *)malloc(BUFFER_SIZE);
    if (!conn_api.rd_buf) {
        destroy_conn_buf(&conn_inbuf);
        destroy_conn_buf(&conn_outbuf);
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }
    conn_api.rd_buf_size = BUFFER_SIZE;

    conn_api.wr_buf = (unsigned char *)malloc(BUFFER_SIZE);
    if (!conn_api.wr_buf) {
        FREE_AND_NULL(conn_api.rd_buf);
        destroy_conn_buf(&conn_inbuf);
        destroy_conn_buf(&conn_outbuf);
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }
    conn_api.wr_buf_size = BUFFER_SIZE;

    // Set up telnet parse callbacks (reuse telnet's IAC parsing)
    memset(telnet_local_option, 0, sizeof(telnet_local_option));
    memset(telnet_remote_option, 0, sizeof(telnet_remote_option));
    conn_api.rx_parse_cb = telnet_rx_parse_cb;
    conn_api.tx_parse_cb = telnet_tx_parse_cb;

    telnet_deferred = bbs->defer_telnet_negotiation;
    telnet_no_binary = bbs->telnet_no_binary;
    strlcpy(term_name, get_emulation_str(bbs), sizeof(term_name));

    // Start rlogin I/O threads (they read/write rlogin_sock)
    _beginthread(rlogin_output_thread, 0, NULL);
    _beginthread(rlogin_input_thread, 0, bbs);

    if (!telnet_deferred)
        send_initial_state();

    return 0;
}

int telnets_close(void) {
    // Use rlogin_close to shut down threads and close socket
    int ret = rlogin_close();
    // Then tear down the Swift-side TLS proxy
    swift_telnets_disconnect();
    return ret;
}

// ============================================================================
// Terminal Function Stubs
// ============================================================================

extern int g_term_width;
extern int g_term_height;

void get_cterm_size(int *cols, int *rows, int ns) {
    if (cols) *cols = g_term_width;
    if (rows) *rows = g_term_height;
}

void get_term_win_size(int *width, int *height, int *pixelw, int *pixelh, int *nostatus) {
    if (width) *width = g_term_width;
    if (height) *height = g_term_height;
    if (pixelw) *pixelw = 0;
    if (pixelh) *pixelh = 0;
    if (nostatus) *nostatus = 1;
}

// ============================================================================
// UIFC Stubs
// ============================================================================

// Stub uifc structure - minimal implementation
#include "uifc.h"

uifcapi_t uifc = {0};

int init_uifc(bool usemouse, bool allow_redraw) {
    (void)usemouse;
    (void)allow_redraw;
    return 0;
}

// ============================================================================
// INI and BBS List Stubs
// ============================================================================

#include "bbslist.h"
#include "ini_file.h"

ini_style_t ini_style = {0};

str_list_t iniReadBBSList(FILE *fp, bool userList) {
    (void)fp;
    (void)userList;
    return NULL;
}

// ============================================================================
// Logging Stubs
// ============================================================================

FILE *log_fp = NULL;
char *log_levels[] = { "EMERG", "ALERT", "CRIT", "ERR", "WARNING", "NOTICE", "INFO", "DEBUG", NULL };

// ============================================================================
// Global Settings Stub
// ============================================================================

#include "syncterm.h"

struct syncterm_settings settings = {0};

// ============================================================================
// Telnet Option Descriptors
// ============================================================================

const char *telnet_cmd_desc(int cmd) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "CMD_%d", cmd);
    return buf;
}

const char *telnet_opt_desc(int opt) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "OPT_%d", opt);
    return buf;
}

const char *telnet_opt_ack(int opt) {
    (void)opt;
    return "ACK";
}

const char *telnet_opt_nak(int opt) {
    (void)opt;
    return "NAK";
}

// ============================================================================
// Terminal Emulation Stubs
// ============================================================================

#include "cterm.h"

const char *get_emulation_str(struct bbslist *bbs) {
    (void)bbs;
    return "ANSI-BBS";
}

cterm_emulation_t get_emulation(struct bbslist *bbs) {
    (void)bbs;
    return CTERM_EMULATION_ANSI_BBS;
}

// ============================================================================
// ciolib Pixel/Graphics Stubs
// ============================================================================

#include "ciolib.h"
#include "ios_ciolib.h"

// Pixel manipulation - forwards to ios_ciolib for sixel graphics rendering
int ciolib_setpixels(uint32_t sx, uint32_t sy, uint32_t ex, uint32_t ey,
                     uint32_t x_off, uint32_t y_off, uint32_t mx_off, uint32_t my_off,
                     struct ciolib_pixels *pixels, struct ciolib_mask *mask) {
    return ios_ciolib_setpixels(sx, sy, ex, ey, x_off, y_off, mx_off, my_off, pixels, mask);
}

struct ciolib_pixels *ciolib_getpixels(uint32_t sx, uint32_t sy, uint32_t ex, uint32_t ey, int force) {
    (void)sx; (void)sy; (void)ex; (void)ey; (void)force;
    return NULL;  // Not supported
}

void ciolib_freepixels(struct ciolib_pixels *pixels) {
    (void)pixels;
    // No-op
}

// Custom cursor - not supported on iOS
void ciolib_getcustomcursor(int *startline, int *endline, int *range, int *blink, int *visible) {
    if (startline) *startline = 0;
    if (endline) *endline = 0;
    if (range) *range = 0;
    if (blink) *blink = 1;
    if (visible) *visible = 1;
}
