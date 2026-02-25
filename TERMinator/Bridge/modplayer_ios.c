/**
 * MOD/Tracker Playback Bridge for iOS
 *
 * Uses libxmp to load and render MOD/S3M/XM/IT tracker modules
 * as PCM audio for playback via AVAudioEngine (pulled from Swift).
 */

#include <string.h>
#include <pthread.h>
#include <stdio.h>

#include "libxmp/xmp.h"
#include "native_bridge.h"

#define MOD_SAMPLE_RATE 44100

static xmp_context g_mod_ctx = NULL;
static volatile int g_mod_playing = 0;
static volatile int g_mod_volume = 100;  /* 0-100 */
static pthread_mutex_t g_mod_lock = PTHREAD_MUTEX_INITIALIZER;

/* Load a module file and start the player */
bool native_mod_load(const char *filePath) {
    if (!filePath) return false;

    pthread_mutex_lock(&g_mod_lock);

    /* Clean up any existing context */
    if (g_mod_ctx != NULL) {
        if (g_mod_playing) {
            xmp_end_player(g_mod_ctx);
            g_mod_playing = 0;
        }
        xmp_release_module(g_mod_ctx);
        xmp_free_context(g_mod_ctx);
        g_mod_ctx = NULL;
    }

    /* Create new context and load */
    g_mod_ctx = xmp_create_context();
    if (g_mod_ctx == NULL) {
        pthread_mutex_unlock(&g_mod_lock);
        return false;
    }

    int ret = xmp_load_module(g_mod_ctx, filePath);
    if (ret < 0) {
        xmp_free_context(g_mod_ctx);
        g_mod_ctx = NULL;
        pthread_mutex_unlock(&g_mod_lock);
        return false;
    }

    /* Start the player: 44100 Hz, 16-bit stereo (default flags = 0) */
    ret = xmp_start_player(g_mod_ctx, MOD_SAMPLE_RATE, 0);
    if (ret < 0) {
        xmp_release_module(g_mod_ctx);
        xmp_free_context(g_mod_ctx);
        g_mod_ctx = NULL;
        pthread_mutex_unlock(&g_mod_lock);
        return false;
    }

    /* Apply current volume */
    xmp_set_player(g_mod_ctx, XMP_PLAYER_VOLUME, g_mod_volume);

    g_mod_playing = 1;

    pthread_mutex_unlock(&g_mod_lock);
    return true;
}

/**
 * Render PCM frames from the loaded module.
 * Output: interleaved 16-bit stereo samples written into `buffer`.
 * Returns number of frames rendered, or -1 on end/error.
 */
int32_t native_mod_get_pcm(int16_t *buffer, int32_t frames) {
    pthread_mutex_lock(&g_mod_lock);

    if (g_mod_ctx == NULL || !g_mod_playing) {
        pthread_mutex_unlock(&g_mod_lock);
        return -1;
    }

    /* Calculate buffer size: stereo 16-bit = 4 bytes per frame */
    int buf_size = frames * 4;

    /* xmp_play_buffer returns 0 on success, -XMP_END on end, negative on error
     * loop parameter: 0 = loop indefinitely, 1 = play once */
    int ret = xmp_play_buffer(g_mod_ctx, buffer, buf_size, 1);

    if (ret < 0) {
        /* -XMP_END means module finished */
        pthread_mutex_unlock(&g_mod_lock);
        return -1;
    }

    pthread_mutex_unlock(&g_mod_lock);
    return frames;
}

/* Stop and release the current module */
void native_mod_stop(void) {
    pthread_mutex_lock(&g_mod_lock);

    if (g_mod_ctx != NULL) {
        if (g_mod_playing) {
            xmp_end_player(g_mod_ctx);
            g_mod_playing = 0;
        }
        xmp_release_module(g_mod_ctx);
        xmp_free_context(g_mod_ctx);
        g_mod_ctx = NULL;
    }

    pthread_mutex_unlock(&g_mod_lock);
}

/* Set playback volume (0.0 - 1.0 mapped to 0-100) */
void native_mod_set_volume(float volume) {
    int vol = (int)(volume * 100.0f);
    if (vol < 0) vol = 0;
    if (vol > 100) vol = 100;

    pthread_mutex_lock(&g_mod_lock);
    g_mod_volume = vol;
    if (g_mod_ctx != NULL && g_mod_playing) {
        xmp_set_player(g_mod_ctx, XMP_PLAYER_VOLUME, vol);
    }
    pthread_mutex_unlock(&g_mod_lock);
}

/* Check if a module is currently playing */
bool native_mod_is_playing(void) {
    return g_mod_playing ? true : false;
}
