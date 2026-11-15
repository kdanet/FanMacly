#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>

// AppleSMC user-client ABI. Keep native alignment: the driver expects 80 bytes.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key;
    Version version;
    Limits limits;
    KeyInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} Message;
_Static_assert(sizeof(Message) == 80, "AppleSMC ABI mismatch");
struct FMConnection { io_connect_t port; FMResult last_result; };

FMConnection *fm_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    FMConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { IOObjectRelease(service); return NULL; }
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection->port);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS) { free(connection); return NULL; }
    return connection;
}
void fm_close(FMConnection *connection) {
    if (!connection) return;
    IOServiceClose(connection->port);
    free(connection);
}
static bool call(FMConnection *connection, Message *input, Message *output) {
    if (!connection) return false;
    size_t length = sizeof(*output);
    kern_return_t status = IOConnectCallStructMethod(connection->port, 2, input, sizeof(*input), output, &length);
    connection->last_result = (FMResult){ .io_return = status, .result = output->result, .status = output->status };
    return status == KERN_SUCCESS && length == sizeof(*output) && output->result == 0;
}
FMResult fm_last_result(FMConnection *connection) {
    return connection ? connection->last_result : (FMResult){ .io_return = kIOReturnNotOpen };
}
bool fm_read(FMConnection *connection, uint32_t key, FMValue *value) {
    if (!value) return false;
    Message input = {0}, output = {0};
    input.key = key; input.command = 9;
    if (!call(connection, &input, &output) || output.info.size == 0 || output.info.size > 32) return false;
    value->size = output.info.size; value->type = output.info.type;
    memset(&input, 0, sizeof(input)); memset(&output, 0, sizeof(output));
    input.key = key; input.command = 5; input.info.size = value->size;
    if (!call(connection, &input, &output)) return false;
    memcpy(value->bytes, output.bytes, value->size);
    return true;
}
bool fm_write(FMConnection *connection, uint32_t key, const uint8_t *bytes, uint32_t size) {
    if (!bytes || !size || size > 32) return false;
    // Prime metadata before writes too, and reject a mismatched payload size.
    Message input = {0}, output = {0};
    input.key = key; input.command = 9;
    if (!call(connection, &input, &output) || output.info.size != size) return false;
    memset(&input, 0, sizeof(input)); memset(&output, 0, sizeof(output));
    input.key = key; input.command = 6; input.info.size = size;
    memcpy(input.bytes, bytes, size);
    return call(connection, &input, &output);
}
uint32_t fm_key_at(FMConnection *connection, uint32_t index) {
    Message input = {0}, output = {0};
    input.command = 8; input.index = index;
    return call(connection, &input, &output) ? output.key : 0;
}
