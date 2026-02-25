/**
 * iOS-specific ciolib interface
 *
 * Provides the screen buffer and terminal I/O abstraction for iOS.
 * This replaces the Android-specific android_ciolib.h
 */

#ifndef IOS_CIOLIB_H
#define IOS_CIOLIB_H

#include <stdint.h>
#include <stdbool.h>

// Forward declaration from ciolib
struct vmem_cell;

// Initialization and cleanup
int  ios_ciolib_init(void);
void ios_ciolib_cleanup(void);

// Screen buffer access
void ios_ciolib_lock(void);
void ios_ciolib_unlock(void);
struct vmem_cell* ios_ciolib_get_screen_buffer(void);
uint32_t* ios_ciolib_get_palette(void);

// Screen dimensions
int ios_ciolib_get_screen_width(void);
int ios_ciolib_get_screen_height(void);
void ios_ciolib_resize(int width, int height);

// Cursor
int ios_ciolib_get_cursor_x(void);
int ios_ciolib_get_cursor_y(void);
bool ios_ciolib_is_cursor_visible(void);
bool ios_ciolib_cursor_type_changed(void);

// Dirty tracking
bool ios_ciolib_is_dirty(void);
void ios_ciolib_clear_dirty(void);
bool ios_ciolib_get_dirty_region(int32_t *minX, int32_t *minY,
                                  int32_t *maxX, int32_t *maxY);

// Input
void ios_ciolib_push_input_buffer(const unsigned char *data, int len);

#endif /* IOS_CIOLIB_H */
