#ifndef AUDIO_PROMPT_H
#define AUDIO_PROMPT_H

#include <stddef.h>

/* 提示音桩：产品层可替换为 Codec/IMP 播放 wav */
void audio_prompt_init(void);
int audio_prompt_play(const char *name);
int audio_prompt_get_status(char *buf, size_t buf_size);

#endif
