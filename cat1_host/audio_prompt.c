#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "audio_prompt.h"
#include "log.h"

#define PROMPT_STUB_MS 120

static const char *g_last_name = "";
static int g_playing = 0;

void audio_prompt_init(void)
{
    g_last_name = "";
    g_playing = 0;
    log_print("APP", "audio_prompt stub ready (replace with IMP/Codec)");
}

int audio_prompt_play(const char *name)
{
    if (name == NULL || name[0] == '\0') {
        return -1;
    }

    g_playing = 1;
    g_last_name = name;
    log_print("APP", "audio_prompt PLAY stub: %s (%dms)", name, PROMPT_STUB_MS);

    /* TODO: SPEAK_EN + /etc/sounds/{name}.wav */
    usleep((useconds_t)PROMPT_STUB_MS * 1000U);

    g_playing = 0;
    log_print("APP", "audio_prompt DONE: %s", name);
    return 0;
}

int audio_prompt_get_status(char *buf, size_t buf_size)
{
    if (buf == NULL || buf_size == 0) {
        return -1;
    }
    if (g_playing) {
        snprintf(buf, buf_size, "playing,%s", g_last_name);
    } else if (g_last_name[0] != '\0') {
        snprintf(buf, buf_size, "done,%s", g_last_name);
    } else {
        snprintf(buf, buf_size, "idle");
    }
    return 0;
}
