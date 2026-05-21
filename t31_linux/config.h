#ifndef CONFIG_H
#define CONFIG_H

#include "types.h"

void config_init_defaults(app_config_t *cfg);
int config_load(app_config_t *cfg, const char *path);

#endif