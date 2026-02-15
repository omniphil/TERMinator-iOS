/**
 * vidmodes.h - Minimal iOS version
 *
 * Provides video mode definitions for iOS.
 */

#ifndef _VIDMODES_H_
#define _VIDMODES_H_

#include <stdbool.h>
#include "ciolib.h"

#define TOTAL_DAC_SIZE 282

// Entry type for the DAC table
struct dac_colors {
    unsigned char red;
    unsigned char green;
    unsigned char blue;
};

// Video parameters structure
struct video_params {
    int mode;
    int palette;
    int cols;
    int rows;
    int curs_start;
    int curs_end;
    int charheight;
    int charwidth;
    int vmultiplier;
    int flags;
};

// Video mode flags
#define CIOLIB_VIDEO_ALTCHARS             (1<<0)
#define CIOLIB_VIDEO_NOBRIGHT             (1<<1)
#define CIOLIB_VIDEO_BGBRIGHT             (1<<2)
#define CIOLIB_VIDEO_BLINKALTCHARS        (1<<3)
#define CIOLIB_VIDEO_NOBLINK              (1<<4)
#define CIOLIB_VIDEO_EXPAND               (1<<5)
#define CIOLIB_VIDEO_LINE_GRAPHICS_EXPAND (1<<6)

#endif /* _VIDMODES_H_ */
