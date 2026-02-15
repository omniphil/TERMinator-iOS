/**
 * Safe Math Operations
 *
 * Provides overflow-safe arithmetic operations for C.
 * These macros/functions detect and prevent integer overflow.
 */

#ifndef SAFE_MATH_H
#define SAFE_MATH_H

#include <stdint.h>
#include <stdbool.h>
#include <limits.h>
#include <stddef.h>

/**
 * Safe multiplication with overflow detection.
 * Returns true on success, false on overflow.
 * Result is stored in *result only on success.
 */
static inline bool safe_mult_int(int a, int b, int *result) {
    if (a == 0 || b == 0) {
        *result = 0;
        return true;
    }

    // Check for potential overflow
    if (a > 0) {
        if (b > 0) {
            if (a > INT_MAX / b) return false;
        } else {
            if (b < INT_MIN / a) return false;
        }
    } else {
        if (b > 0) {
            if (a < INT_MIN / b) return false;
        } else {
            if (a != 0 && b < INT_MAX / a) return false;
        }
    }

    *result = a * b;
    return true;
}

/**
 * Safe multiplication for size_t (unsigned).
 * Returns true on success, false on overflow.
 */
static inline bool safe_mult_size(size_t a, size_t b, size_t *result) {
    if (a == 0 || b == 0) {
        *result = 0;
        return true;
    }

    if (a > SIZE_MAX / b) {
        return false;
    }

    *result = a * b;
    return true;
}

/**
 * Safe addition with overflow detection.
 * Returns true on success, false on overflow.
 */
static inline bool safe_add_int(int a, int b, int *result) {
    if ((b > 0) && (a > INT_MAX - b)) return false;
    if ((b < 0) && (a < INT_MIN - b)) return false;

    *result = a + b;
    return true;
}

/**
 * Safe addition for size_t.
 */
static inline bool safe_add_size(size_t a, size_t b, size_t *result) {
    if (a > SIZE_MAX - b) return false;

    *result = a + b;
    return true;
}

/**
 * Safe subtraction with underflow detection.
 * Returns true on success, false on underflow.
 */
static inline bool safe_sub_int(int a, int b, int *result) {
    if ((b > 0) && (a < INT_MIN + b)) return false;
    if ((b < 0) && (a > INT_MAX + b)) return false;

    *result = a - b;
    return true;
}

/**
 * Validate dimensions for buffer allocation.
 * Returns true if width * height won't overflow and both are positive.
 */
static inline bool validate_dimensions(int width, int height, int *total_size) {
    if (width <= 0 || height <= 0) {
        return false;
    }

    return safe_mult_int(width, height, total_size);
}

/**
 * Validate dimensions with element size for allocation.
 * Returns true if width * height * elem_size won't overflow.
 */
static inline bool validate_alloc_size(int width, int height, size_t elem_size, size_t *alloc_size) {
    if (width <= 0 || height <= 0 || elem_size == 0) {
        return false;
    }

    size_t area;
    if (!safe_mult_size((size_t)width, (size_t)height, &area)) {
        return false;
    }

    return safe_mult_size(area, elem_size, alloc_size);
}

/**
 * Validate array index calculation.
 * Returns true if (y * width + x) won't overflow and is within bounds.
 */
static inline bool validate_index(int x, int y, int width, int height, int *index) {
    if (x < 0 || y < 0 || width <= 0 || height <= 0) {
        return false;
    }

    if (x >= width || y >= height) {
        return false;
    }

    int row_offset;
    if (!safe_mult_int(y, width, &row_offset)) {
        return false;
    }

    return safe_add_int(row_offset, x, index);
}

/**
 * Validate port number from Swift int to unsigned short.
 * Returns true if port is in valid range (1-65535).
 */
static inline bool validate_port(int port, unsigned short *result) {
    if (port < 1 || port > 65535) {
        return false;
    }
    *result = (unsigned short)port;
    return true;
}

/**
 * Clamp a value to the range [min, max].
 */
static inline int clamp_int(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

/**
 * Validate rectangle dimensions (ex - sx + 1, ey - sy + 1).
 * Ensures the resulting width/height are positive.
 */
static inline bool validate_rect_dims(int sx, int sy, int ex, int ey, int *width, int *height) {
    // Ensure start <= end
    if (sx > ex || sy > ey) {
        return false;
    }

    // Calculate width = ex - sx + 1, with overflow check
    int w, h;
    if (!safe_sub_int(ex, sx, &w)) return false;
    if (!safe_add_int(w, 1, &w)) return false;

    if (!safe_sub_int(ey, sy, &h)) return false;
    if (!safe_add_int(h, 1, &h)) return false;

    if (w <= 0 || h <= 0) {
        return false;
    }

    *width = w;
    *height = h;
    return true;
}

#endif /* SAFE_MATH_H */
