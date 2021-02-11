#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "libc.h"

typedef struct phil_t phil_t;

struct phil_t
{
    int forks;
    bool hungry;
    phil_t *left;
    phil_t *right;
};