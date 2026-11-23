#ifndef PQCLEAN_RANDOMBYTES_H
#define PQCLEAN_RANDOMBYTES_H
#include <stddef.h>
#include <stdint.h>
int PQCLEAN_randombytes(uint8_t *output, size_t n);
#define randombytes PQCLEAN_randombytes
#endif
