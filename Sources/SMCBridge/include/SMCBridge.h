#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct FMConnection FMConnection;
typedef struct { uint32_t size; uint32_t type; uint8_t bytes[32]; } FMValue;
typedef struct { int32_t io_return; uint8_t result; uint8_t status; } FMResult;
FMConnection *fm_open(void);
void fm_close(FMConnection *connection);
bool fm_read(FMConnection *connection, uint32_t key, FMValue *value);
bool fm_write(FMConnection *connection, uint32_t key, const uint8_t *bytes, uint32_t size);
uint32_t fm_key_at(FMConnection *connection, uint32_t index);
FMResult fm_last_result(FMConnection *connection);
