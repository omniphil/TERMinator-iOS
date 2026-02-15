/**
 * ZMODEM iOS Bridge Header
 *
 * Public API for ZMODEM file transfers on iOS
 */

#ifndef _ZMODEM_IOS_H_
#define _ZMODEM_IOS_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Transfer states (matches Swift TransferState enum)
#define ZMODEM_STATE_IDLE       0
#define ZMODEM_STATE_RECEIVING  1
#define ZMODEM_STATE_SENDING    2
#define ZMODEM_STATE_COMPLETE   3
#define ZMODEM_STATE_ERROR      4
#define ZMODEM_STATE_CANCELLED  5

/**
 * Initialize the ZMODEM transfer system
 * Returns: 1 on success, 0 on failure
 */
int zmodem_ios_init(void);

/**
 * Set download directory for received files
 */
void zmodem_ios_set_download_dir(const char* dir);

/**
 * Receive files via ZMODEM
 * Returns: number of files received, or negative on error
 */
int zmodem_ios_receive(void);

/**
 * Send a file via ZMODEM
 * Returns: 0 on success, negative on error
 */
int zmodem_ios_send(const char* file_path);

/**
 * Cancel current transfer
 */
void zmodem_ios_cancel(void);

/**
 * Get current transfer state
 * Returns: ZMODEM_STATE_* constant
 */
int zmodem_ios_get_state(void);

/**
 * Get transfer progress
 * @param transferred Output: bytes transferred so far
 * @param total Output: total bytes to transfer
 */
void zmodem_ios_get_progress(int64_t *transferred, int64_t *total);

/**
 * Get current file name being transferred
 * Returns: pointer to internal buffer (copy immediately if needed)
 */
const char* zmodem_ios_get_filename(void);

/**
 * Get last error message
 * Returns: pointer to internal buffer
 */
const char* zmodem_ios_get_error(void);

/**
 * Reset transfer state to idle
 */
void zmodem_ios_reset(void);

/**
 * Cleanup transfer system
 */
void zmodem_ios_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* _ZMODEM_IOS_H_ */
