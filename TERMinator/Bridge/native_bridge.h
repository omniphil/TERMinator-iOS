/**
 * Native Bridge Header for iOS
 *
 * Declares the C functions that Swift will call via @_silgen_name.
 * These functions are implemented in syncterm_ios.c and ios_ciolib.c.
 */

#ifndef NATIVE_BRIDGE_H
#define NATIVE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// MARK: - Initialization
// ============================================================================

/**
 * Set the files directory for SSH keys and other data.
 */
void native_set_files_dir(const char *path);

/**
 * Initialize the native terminal system.
 * Returns true on success, false on failure.
 */
bool native_init(void);

/**
 * Clean up native resources.
 */
void native_destroy(void);

// ============================================================================
// MARK: - Connection Management
// ============================================================================

/**
 * Connect to a server.
 * @param host Hostname or IP address
 * @param port Port number
 * @param protocol CONN_TYPE_TELNET (3) or CONN_TYPE_SSH (5)
 * @param username Username for SSH (NULL for Telnet)
 * @param password Password for SSH (NULL for Telnet)
 * @return true on success, false on failure
 */
bool native_connect(const char *host, int32_t port, int32_t protocol,
                    const char *username, const char *password);

/**
 * Disconnect from the server.
 */
void native_disconnect(void);

/**
 * Check if connected.
 */
bool native_is_connected(void);

// ============================================================================
// MARK: - Data Transfer
// ============================================================================

/**
 * Send raw data to the server.
 * @return Bytes sent, or -1 on error
 */
int32_t native_send_data(const uint8_t *data, int32_t count);

/**
 * Send a key code to the server.
 * @return 1 on success, -1 on error
 */
int32_t native_send_key(int32_t keyCode);

/**
 * Send a string to the server.
 * @return Bytes sent, or -1 on error
 */
int32_t native_send_string(const char *str);

/**
 * Process incoming data.
 * @return Bytes processed, -100 for ZMODEM download, -101 for upload ready
 */
int32_t native_process_data(void);

/**
 * Check if data is waiting.
 * @return Bytes waiting
 */
int32_t native_data_waiting(void);

// ============================================================================
// MARK: - Screen State
// ============================================================================

/**
 * Get the screen buffer as packed integers.
 * Each int: character | (attr << 8) | (fg << 16) | (bg << 24)
 * @param count Output: number of cells
 * @return Pointer to screen buffer (do not free)
 */
const int32_t* native_get_screen_buffer(int32_t *count);

/**
 * Get the color palette.
 * @param count Output: number of colors (16)
 * @return Pointer to palette (do not free)
 */
const int32_t* native_get_palette(int32_t *count);

/**
 * Get the screen size.
 */
void native_get_screen_size(int32_t *columns, int32_t *rows);

/**
 * Get cursor position.
 */
void native_get_cursor_pos(int32_t *x, int32_t *y);

/**
 * Check if cursor is visible.
 */
bool native_is_cursor_visible(void);

/**
 * Check if BBS explicitly changed cursor type (read and clear).
 */
bool native_cursor_type_changed(void);

/**
 * Check if the screen has changed since last render.
 */
bool native_is_screen_dirty(void);

/**
 * Get dirty region bounds for partial redraw optimization.
 * @return true if there is a dirty region
 */
bool native_get_dirty_region(int32_t *minX, int32_t *minY, int32_t *maxX, int32_t *maxY);

// ============================================================================
// MARK: - Terminal Control
// ============================================================================

/**
 * Set terminal size.
 */
void native_set_terminal_size(int32_t width, int32_t height);

/**
 * Set font by name.
 * @return true on success
 */
bool native_set_font(const char *fontName);

/**
 * Set font by ID.
 * @return true on success
 */
bool native_set_font_by_id(int32_t fontId);

/**
 * Clear the screen.
 */
void native_clear_screen(void);

/**
 * Reset terminal state completely (screen + scrollback).
 * Call this when connecting to a new BBS.
 */
void native_reset_terminal(void);

/**
 * Reset ANSI parser state (colors, bold, ice mode).
 * Call this when starting a new connection.
 */
void cterm_reset_ansi_state(void);

/**
 * Push input data to the terminal.
 */
void native_push_input(const uint8_t *data, int32_t count);

/**
 * Hide or show the status line.
 */
void native_set_hide_status_line(bool hide);

/**
 * Set screen mode (0=80x25, 1=80x30, 2=80x50, 3=132x25, 4=132x50, 5=80x40).
 */
void native_set_screen_mode(int32_t mode);

// ============================================================================
// MARK: - Status
// ============================================================================

/**
 * Get status information string.
 */
const char* native_get_status_info(void);

/**
 * Get connection statistics.
 * @return true on success
 */
bool native_get_connection_stats(int64_t *sent, int64_t *received,
                                  int64_t *connectTime, int64_t *currentTime);

// ============================================================================
// MARK: - Font Bitmap
// ============================================================================

/**
 * Get font bitmap data.
 * @param width Output: font width (8)
 * @param height Output: font height (8, 14, or 16)
 * @param count Output: data size in bytes
 * @return Pointer to bitmap data (do not free)
 */
const uint8_t* native_get_font_bitmap(int32_t *width, int32_t *height, int32_t *count);

// ============================================================================
// MARK: - File Transfer (ZMODEM)
// ============================================================================

/**
 * Initialize the file transfer subsystem.
 */
bool native_transfer_init(void);

/**
 * Set the download directory.
 */
void native_set_download_dir(const char *dir);

/**
 * Start a ZMODEM receive operation.
 * @return 0 on success, negative on error
 */
int32_t native_zmodem_receive(void);

/**
 * Start a ZMODEM send operation.
 * @return 0 on success, negative on error
 */
int32_t native_zmodem_send(const char *filePath);

/**
 * Cancel the current transfer.
 */
void native_transfer_cancel(void);

/**
 * Get the current transfer state.
 * 0=idle, 1=receiving, 2=sending, 3=complete, 4=error, 5=cancelled
 */
int32_t native_get_transfer_state(void);

/**
 * Get transfer progress.
 * @return true on success
 */
bool native_get_transfer_progress(int64_t *transferred, int64_t *total);

/**
 * Get the name of the file being transferred.
 */
const char* native_get_transfer_file_name(void);

/**
 * Get the error message from the last failed transfer.
 */
const char* native_get_transfer_error(void);

/**
 * Reset transfer state after completion or error.
 */
void native_transfer_reset(void);

/**
 * Cleanup file transfer resources.
 */
void native_transfer_cleanup(void);

// ============================================================================
// MARK: - ZMODEM Auto-Detection
// ============================================================================

/**
 * Check if ZMODEM was auto-detected.
 */
bool native_is_zmodem_detected(void);

/**
 * Get buffered ZMODEM data from detection.
 * @param count Output: buffer size
 * @return Pointer to buffer (do not free)
 */
const uint8_t* native_get_zmodem_buffer(int32_t *count);

/**
 * Clear ZMODEM detection state.
 */
void native_clear_zmodem_detected(void);

/**
 * Push buffered ZMODEM data back into connection buffer.
 */
int32_t native_push_zmodem_buffer(void);

// ============================================================================
// MARK: - Upload Queue
// ============================================================================

/**
 * Queue a file for upload.
 */
void native_queue_upload(const char *filePath);

/**
 * Check if a file is queued for upload.
 */
bool native_is_upload_queued(void);

/**
 * Check if the BBS is ready for upload (ZRINIT received).
 */
bool native_is_upload_ready(void);

/**
 * Get the path of the queued upload file.
 */
const char* native_get_queued_upload(void);

/**
 * Clear the upload queue.
 */
void native_clear_upload_queue(void);

// ============================================================================
// MARK: - Scrollback Buffer
// ============================================================================

/**
 * Get scrollback buffer info.
 * @return true on success
 */
bool native_get_scrollback_info(int32_t *filled, int32_t *capacity, int32_t *columns);

/**
 * Get scrollback buffer content.
 * @param offset Lines from current position
 * @param count Lines to retrieve
 * @param resultCount Output: cells returned
 * @return Pointer to buffer (do not free)
 */
const int32_t* native_get_scrollback_buffer(int32_t offset, int32_t count, int32_t *resultCount);

// ============================================================================
// MARK: - Bell Detection
// ============================================================================

/**
 * Check if a bell (BEL character) was received and clear the flag.
 */
bool native_check_bell(void);

// ============================================================================
// MARK: - Session Logging
// ============================================================================

/**
 * Enable or disable session logging.
 */
void native_set_logging_enabled(bool enabled);

/**
 * Get and clear logged data from the buffer.
 * @param count Output: data size
 * @return Pointer to log buffer (do not free)
 */
const uint8_t* native_get_logged_data(int32_t *count);

// ============================================================================
// MARK: - Audio Command (OSC 800 / TAP)
// ============================================================================

/**
 * Check if an audio command is pending (lockless volatile read).
 */
bool native_check_audio_command(void);

/**
 * Get the pending audio command string and clear the flag.
 * @return Pointer to command string (static buffer, do not free), or NULL
 */
const char* native_get_audio_command(void);

// ============================================================================
// MARK: - MOD Player (libxmp)
// ============================================================================

/**
 * Load a tracker module file and start the player.
 * @param filePath Path to MOD/S3M/XM/IT file
 * @return true on success
 */
bool native_mod_load(const char *filePath);

/**
 * Render PCM frames from the loaded module.
 * Output: interleaved 16-bit stereo samples.
 * @param buffer Output buffer for PCM data
 * @param frames Number of frames to render
 * @return Frames rendered, or -1 on end/error
 */
int32_t native_mod_get_pcm(int16_t *buffer, int32_t frames);

/**
 * Stop and release the current module.
 */
void native_mod_stop(void);

/**
 * Set MOD playback volume (0.0 - 1.0).
 */
void native_mod_set_volume(float volume);

/**
 * Check if a module is currently playing.
 */
bool native_mod_is_playing(void);

// ============================================================================
// MARK: - Fast Terminal Rendering
// ============================================================================

/**
 * Render the terminal screen to a pixel buffer (fast C implementation).
 * @param pixels Output buffer (BGRA, size: cellWidth*cols * cellHeight*rows * 4)
 * @param screenBuffer Screen buffer from native_get_screen_buffer
 * @param cols Number of columns
 * @param rows Number of rows
 * @param cellWidth Cell width in pixels (scaled)
 * @param cellHeight Cell height in pixels (scaled)
 * @param fontData Font bitmap from native_get_font_bitmap
 * @param fontWidth Native font width (8)
 * @param fontHeight Native font height (16)
 * @param palette 16-color palette from native_get_palette
 */
void native_render_terminal(uint8_t *pixels,
                            int32_t pixelBufferSize,
                            const int32_t *screenBuffer,
                            int32_t screenBufferCount,
                            int32_t cols, int32_t rows,
                            int32_t cellWidth, int32_t cellHeight,
                            const uint8_t *fontData,
                            int32_t fontDataSize,
                            int32_t fontWidth, int32_t fontHeight,
                            const uint32_t *palette);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_BRIDGE_H */
