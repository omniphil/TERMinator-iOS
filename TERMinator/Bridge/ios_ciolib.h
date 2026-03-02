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

// Sixel pixel framebuffer
struct ciolib_pixels;
struct ciolib_mask;
int ios_ciolib_setpixels(uint32_t sx, uint32_t sy, uint32_t ex, uint32_t ey,
                          uint32_t x_off, uint32_t y_off, uint32_t mx_off, uint32_t my_off,
                          struct ciolib_pixels *pixels, struct ciolib_mask *mask);
void ios_ciolib_clear_pixels(void);
void ios_ciolib_set_char_pixel_height(int h);
int ios_ciolib_has_sixel_data(void);
int ios_ciolib_is_pixel_dirty(void);
void ios_ciolib_clear_pixel_dirty(void);
uint32_t* ios_ciolib_get_pixel_buffer(void);
int ios_ciolib_get_pixel_width(void);
int ios_ciolib_get_pixel_height(void);

#endif /* IOS_CIOLIB_H */
