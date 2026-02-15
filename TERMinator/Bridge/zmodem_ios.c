/**
 * ZMODEM iOS Bridge
 *
 * Provides C functions to connect iOS/Swift with the native
 * ZMODEM file transfer protocol implementation.
 *
 * This is the iOS equivalent of Android's zmodem_jni.c
 */

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

// Type definitions
#include "gen_defs.h"
#include "genwrap.h"
#include "filewrap.h"
#include "dirwrap.h"

// ZMODEM protocol
#include "zmodem.h"

// Connection API (declared in conn.h)
#include "conn.h"

// Swift bridge: enable/disable raw mode on telnet connection
extern void swift_telnet_set_raw_mode(int enabled);

// Transfer states
typedef enum {
    TRANSFER_IDLE = 0,
    TRANSFER_RECEIVING = 1,
    TRANSFER_SENDING = 2,
    TRANSFER_COMPLETE = 3,
    TRANSFER_ERROR = 4,
    TRANSFER_CANCELLED = 5
} transfer_state_t;

// Transfer context
typedef struct {
    zmodem_t zm;
    transfer_state_t state;
    int cancelled;
    int64_t current_pos;
    int64_t total_size;
    char current_file[MAX_PATH + 1];
    char download_dir[MAX_PATH + 1];
    char error_message[256];
    int log_level;
    pthread_mutex_t lock;
} transfer_context_t;

// Global transfer context
static transfer_context_t g_zmodem_transfer = {
    .state = TRANSFER_IDLE,
    .cancelled = 0,
    .current_pos = 0,
    .total_size = 0,
    .current_file = "",
    .download_dir = "",
    .error_message = "",
    .log_level = LOG_DEBUG
};

static int g_zmodem_initialized = 0;

// Forward declarations for callbacks
static int zmodem_lputs_cb(void* cbdata, int level, const char* str);
static int zmodem_send_byte_cb(void* cbdata, BYTE ch, unsigned timeout);
static int zmodem_recv_byte_cb(void* cbdata, unsigned timeout);
static void zmodem_progress_cb(void* cbdata, int64_t current_pos);
static BOOL zmodem_is_connected_cb(void* cbdata);
static BOOL zmodem_is_cancelled_cb(void* cbdata);
static BOOL zmodem_data_waiting_cb(void* cbdata, unsigned timeout);
static void zmodem_flush_cb(void* cbdata);

// ============================================================================
// MARK: - ZMODEM Callbacks
// ============================================================================

/**
 * ZMODEM Callback: Log output (no-op)
 */
static int zmodem_lputs_cb(void* cbdata, int level, const char* str) {
    (void)cbdata;
    (void)level;
    (void)str;
    return 0;
}

/**
 * ZMODEM Callback: Send a byte with timeout
 */
static int zmodem_send_byte_cb(void* cbdata, BYTE ch, unsigned timeout) {
    (void)cbdata;

    if (!conn_connected()) {
        return -1;
    }

    int sent = conn_send(&ch, 1, timeout * 1000);  // Convert to milliseconds
    return (sent == 1) ? 0 : -1;
}

/**
 * ZMODEM Callback: Receive a byte with timeout
 *
 * Uses an internal read-ahead buffer to avoid calling conn_recv_upto()
 * for every single byte (which is extremely slow due to mutex overhead).
 */
static BYTE recv_buf[4096];
static int recv_buf_pos = 0;
static int recv_buf_len = 0;

static int zmodem_recv_byte_cb(void* cbdata, unsigned timeout) {
    (void)cbdata;

    // Return buffered byte if available
    if (recv_buf_pos < recv_buf_len) {
        return recv_buf[recv_buf_pos++];
    }

    if (!conn_connected()) {
        return -1;
    }

    // Poll for data with actual timeout.
    // conn_recv_upto() ignores its timeout parameter (returns immediately),
    // so we must poll here to give the BBS time to respond.
    unsigned clamped_timeout = (timeout > 300) ? 300 : timeout;
    unsigned timeout_ms = clamped_timeout * 1000;
    unsigned elapsed_ms = 0;

    while (elapsed_ms < timeout_ms) {
        recv_buf_pos = 0;
        recv_buf_len = conn_recv_upto(recv_buf, sizeof(recv_buf), 0);

        if (recv_buf_len > 0) {
            return recv_buf[recv_buf_pos++];
        }
        recv_buf_len = 0;

        if (!conn_connected()) {
            return -1;
        }

        // Check for cancellation
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        int cancelled = g_zmodem_transfer.cancelled;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        if (cancelled) {
            return -1;
        }

        usleep(10000);  // 10ms
        elapsed_ms += 10;
    }

    return -1;  // Timeout
}

/**
 * ZMODEM Callback: Progress update
 */
static void zmodem_progress_cb(void* cbdata, int64_t current_pos) {
    (void)cbdata;

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.current_pos = current_pos;

    // Also update from zmodem structure
    g_zmodem_transfer.total_size = g_zmodem_transfer.zm.current_file_size;
    if (g_zmodem_transfer.zm.current_file_name[0] != '\0') {
        // Strip path components to prevent path traversal from malicious BBS
        const char *safe_name = strrchr(g_zmodem_transfer.zm.current_file_name, '/');
        safe_name = safe_name ? safe_name + 1 : g_zmodem_transfer.zm.current_file_name;
        strncpy(g_zmodem_transfer.current_file, safe_name, MAX_PATH);
        g_zmodem_transfer.current_file[MAX_PATH] = '\0';
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * ZMODEM Callback: Check if connected
 */
static BOOL zmodem_is_connected_cb(void* cbdata) {
    (void)cbdata;
    return conn_connected() ? TRUE : FALSE;
}

/**
 * ZMODEM Callback: Check if cancelled
 */
static BOOL zmodem_is_cancelled_cb(void* cbdata) {
    (void)cbdata;

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    int cancelled = g_zmodem_transfer.cancelled;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return cancelled ? TRUE : FALSE;
}

/**
 * ZMODEM Callback: Check if data is waiting
 */
static BOOL zmodem_data_waiting_cb(void* cbdata, unsigned timeout) {
    (void)cbdata;

    // Check read-ahead buffer first
    if (recv_buf_pos < recv_buf_len) {
        return TRUE;
    }

    if (!conn_connected()) {
        return FALSE;
    }

    // Poll for data with timeout
    unsigned clamped_timeout = (timeout > 300) ? 300 : timeout;
    unsigned elapsed = 0;
    while (elapsed < clamped_timeout * 1000) {
        size_t waiting = conn_data_waiting();
        if (waiting > 0) {
            return TRUE;
        }

        // Check for cancellation
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        int cancelled = g_zmodem_transfer.cancelled;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        if (cancelled) {
            return FALSE;
        }

        usleep(10000);  // 10ms
        elapsed += 10;
    }

    return conn_data_waiting() > 0 ? TRUE : FALSE;
}

/**
 * ZMODEM Callback: Flush output
 */
static void zmodem_flush_cb(void* cbdata) {
    (void)cbdata;
    // Connection is already unbuffered, nothing to do
}

/**
 * ZMODEM Callback: Handle duplicate filename
 *
 * Called when a file already exists and has different CRC (corrupt partial)
 * or is larger than remote. Deletes the existing file and returns TRUE
 * to retry the download from scratch.
 */
static BOOL zmodem_duplicate_filename_cb(void* cbdata, void* zm_ptr) {
    (void)cbdata;
    zmodem_t* zm = (zmodem_t*)zm_ptr;

    // Build path to existing file (strip path components for safety)
    const char *safe_name = strrchr(zm->current_file_name, '/');
    safe_name = safe_name ? safe_name + 1 : zm->current_file_name;

    char fpath[MAX_PATH * 2 + 2];
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    snprintf(fpath, sizeof(fpath), "%s/%s",
             g_zmodem_transfer.download_dir, safe_name);
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    // Delete the corrupt/mismatched file so we can re-download
    if (remove(fpath) == 0) {
        return TRUE;  // Retry - file is gone, download will proceed
    } else {
        return FALSE;  // Can't delete, skip
    }
}

// ============================================================================
// MARK: - Public API (called from syncterm_ios.c)
// ============================================================================

/**
 * Initialize the ZMODEM transfer system
 */
int zmodem_ios_init(void) {
    if (g_zmodem_initialized) {
        return 1;
    }

    // Initialize mutex
    if (pthread_mutex_init(&g_zmodem_transfer.lock, NULL) != 0) {
        return 0;
    }

    // Initialize ZMODEM structure
    zmodem_init(&g_zmodem_transfer.zm,
                &g_zmodem_transfer,        // cbdata
                zmodem_lputs_cb,           // lputs
                zmodem_progress_cb,        // progress
                zmodem_send_byte_cb,       // send_byte
                zmodem_recv_byte_cb,       // recv_byte
                zmodem_is_connected_cb,    // is_connected
                zmodem_is_cancelled_cb,    // is_cancelled
                zmodem_data_waiting_cb,    // data_waiting
                zmodem_flush_cb);          // flush

    // Configure ZMODEM
    g_zmodem_transfer.zm.log_level = &g_zmodem_transfer.log_level;
    g_zmodem_transfer.zm.max_errors = 10;
    g_zmodem_transfer.zm.recv_timeout = 10;
    g_zmodem_transfer.zm.send_timeout = 10;
    g_zmodem_transfer.zm.escape_telnet_iac = TRUE;   // Escape 0xFF (IAC) for Telnet
    g_zmodem_transfer.zm.escape_ctrl_chars = TRUE;   // Request ESCCTL to prevent CR+NUL stripping
    g_zmodem_transfer.zm.duplicate_filename = zmodem_duplicate_filename_cb;

    g_zmodem_transfer.state = TRANSFER_IDLE;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_initialized = 1;

    return 1;
}

/**
 * Set download directory
 */
void zmodem_ios_set_download_dir(const char* dir) {
    if (!dir) return;

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(g_zmodem_transfer.download_dir, dir, MAX_PATH - 1);
    g_zmodem_transfer.download_dir[MAX_PATH - 1] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Receive files via ZMODEM
 * Returns: number of files received, or negative on error
 */
int zmodem_ios_receive(void) {
    // Reset read-ahead buffer for fresh transfer
    recv_buf_pos = 0;
    recv_buf_len = 0;

    if (!g_zmodem_initialized) {
        return -1;
    }

    if (!conn_connected()) {
        return -2;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -3;
    }

    g_zmodem_transfer.state = TRANSFER_RECEIVING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file[0] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';

    char download_dir[MAX_PATH + 1];
    strncpy(download_dir, g_zmodem_transfer.download_dir, MAX_PATH);
    download_dir[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    if (download_dir[0] == '\0') {
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        strncpy(g_zmodem_transfer.error_message, "Download directory not set",
                sizeof(g_zmodem_transfer.error_message) - 1);
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -4;
    }

    // Create download directory if it doesn't exist
    int mkdir_result = mkdir(download_dir, 0755);
    int saved_errno = errno;
    if (mkdir_result != 0 && saved_errno != EEXIST) {
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "Failed to create directory: %s", strerror(saved_errno));
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -5;
    }

    // Perform ZMODEM receive
    uint64_t bytes_received = 0;
    swift_telnet_set_raw_mode(1);  // Bypass telnet IAC parsing during binary transfer
    int result = zmodem_recv_files(&g_zmodem_transfer.zm, download_dir, &bytes_received);
    swift_telnet_set_raw_mode(0);  // Restore telnet parsing

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
    } else if (result < 0) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "ZMODEM receive failed (code %d)", result);
    } else if (result == 0 && bytes_received == 0) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "No files received - check BBS is sending");
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return result;
}

/**
 * Send a file via ZMODEM
 * Returns: 0 on success, negative on error
 */
int zmodem_ios_send(const char* file_path) {
    // Reset read-ahead buffer for fresh transfer
    recv_buf_pos = 0;
    recv_buf_len = 0;

    if (!g_zmodem_initialized) {
        return -1;
    }

    if (!conn_connected()) {
        return -2;
    }

    if (!file_path) {
        return -3;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -4;
    }

    g_zmodem_transfer.state = TRANSFER_SENDING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    strncpy(g_zmodem_transfer.current_file, file_path, MAX_PATH);
    g_zmodem_transfer.current_file[MAX_PATH] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    // Open the file
    FILE *fp = fopen(file_path, "rb");
    if (!fp) {
        int saved_errno = errno;
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "Failed to open file: %s", strerror(saved_errno));
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -5;
    }

    // Get file name from path
    const char *filename = strrchr(file_path, '/');
    if (filename) {
        filename++;  // Skip the slash
    } else {
        filename = file_path;
    }

    // Make a mutable copy of filename for zmodem_send_file
    char name_buf[MAX_PATH + 1];
    strncpy(name_buf, filename, MAX_PATH);
    name_buf[MAX_PATH] = '\0';

    // Perform ZMODEM send
    time_t start_time = 0;
    uint64_t bytes_sent = 0;
    swift_telnet_set_raw_mode(1);  // Bypass telnet IAC parsing during binary transfer
    BOOL success = zmodem_send_file(&g_zmodem_transfer.zm, name_buf, fp, TRUE, &start_time, &bytes_sent);
    swift_telnet_set_raw_mode(0);  // Restore telnet parsing

    fclose(fp);

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
    } else if (!success) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        strncpy(g_zmodem_transfer.error_message, "ZMODEM send failed",
                sizeof(g_zmodem_transfer.error_message) - 1);
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    // Properly end the ZMODEM session
    zmodem_get_zfin(&g_zmodem_transfer.zm);

    return success ? 0 : -6;
}

/**
 * Cancel current transfer
 */
void zmodem_ios_cancel(void) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.cancelled = 1;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    // Send abort sequence
    if (g_zmodem_initialized) {
        zmodem_send_zabort(&g_zmodem_transfer.zm);
    }
}

/**
 * Get current transfer state
 */
int zmodem_ios_get_state(void) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    int state = (int)g_zmodem_transfer.state;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return state;
}

/**
 * Get transfer progress
 */
void zmodem_ios_get_progress(int64_t *transferred, int64_t *total) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    *transferred = g_zmodem_transfer.current_pos;
    *total = g_zmodem_transfer.total_size;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Get current file name being transferred
 */
const char* zmodem_ios_get_filename(void) {
    static char filename_copy[MAX_PATH + 1];
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(filename_copy, g_zmodem_transfer.current_file, MAX_PATH);
    filename_copy[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return filename_copy;
}

/**
 * Get last error message
 */
const char* zmodem_ios_get_error(void) {
    static char error_copy[256];
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(error_copy, g_zmodem_transfer.error_message, sizeof(error_copy) - 1);
    error_copy[sizeof(error_copy) - 1] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return error_copy;
}

/**
 * Reset transfer state to idle
 */
void zmodem_ios_reset(void) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.state = TRANSFER_IDLE;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file[0] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Cleanup transfer system
 */
void zmodem_ios_cleanup(void) {
    if (!g_zmodem_initialized) {
        return;
    }

    pthread_mutex_destroy(&g_zmodem_transfer.lock);
    g_zmodem_initialized = 0;
}
