#define _POSIX_C_SOURCE 200809L

#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

static volatile sig_atomic_t running = 1;
static volatile uint64_t result;

static void stop(int signal_number) {
    (void)signal_number;
    running = 0;
}

static uint64_t nanoseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

int main(void) {
    enum { memory_size = 16 * 1024 * 1024 };
    volatile unsigned char *memory = malloc(memory_size);
    if (memory == NULL || signal(SIGTERM, stop) == SIG_ERR) {
        free((void *)memory);
        return 1;
    }

    for (size_t offset = 0; offset < memory_size; offset += 4096) {
        memory[offset] = (unsigned char)offset;
    }

    uint64_t state = 1;
    while (running) {
        uint64_t deadline = nanoseconds() + 120000000ULL;
        while (running && nanoseconds() < deadline) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state += memory[state % memory_size];
        }
        result = state;
        struct timespec pause = { .tv_sec = 0, .tv_nsec = 80000000L };
        nanosleep(&pause, NULL);
    }

    free((void *)memory);
    return 0;
}
