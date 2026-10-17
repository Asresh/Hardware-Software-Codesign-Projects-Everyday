/* Author: Asresh */
#include "pcie_reorder.h"
pcr_result pcr_reference(uint16_t id, uint32_t opaque) {
    pcr_result result;
    uint32_t salt = (uint32_t)id * UINT32_C(0x9e3779b9);
    result.id = id;
    result.opaque = opaque;
    result.data = opaque ^ salt ^ (salt >> 13);
    result.status = (uint8_t)(id & 3u);
    return result;
}
uint64_t pcr_checksum(const pcr_result *results, size_t count) {
    uint64_t checksum = UINT64_C(0xcbf29ce484222325);
    size_t i;
    for (i=0; i<count; ++i) {
        checksum ^= ((uint64_t)results[i].id << 48) |
                    ((uint64_t)results[i].status << 40) |
                    ((uint64_t)results[i].opaque << 8) |
                    results[i].data;
        checksum *= UINT64_C(0x100000001b3);
    }
    return checksum;
}
