/* Tiny dependency-free test harness: EXPECT_* macros + a pass/fail tally.
 * No external framework (matches the minimal-deps / nix-purity approach). */
#ifndef PM_TEST_H
#define PM_TEST_H

#include <stdio.h>
#include <inttypes.h>

extern int pm_tests_run, pm_tests_failed;
extern const char *pm_cur_test;

#define TEST(name) \
    static void name(void); \
    static void name##_wrap(void) { pm_cur_test = #name; name(); } \
    static void name(void)

#define RUN(name) do { name##_wrap(); } while (0)

#define EXPECT(cond) do { \
    pm_tests_run++; \
    if (!(cond)) { pm_tests_failed++; \
        printf("  FAIL [%s] %s:%d  EXPECT(%s)\n", pm_cur_test, __FILE__, __LINE__, #cond); } \
} while (0)

#define EXPECT_EQ(a, b) do { \
    pm_tests_run++; \
    uint64_t _a = (uint64_t)(a), _b = (uint64_t)(b); \
    if (_a != _b) { pm_tests_failed++; \
        printf("  FAIL [%s] %s:%d  EXPECT_EQ(%s, %s): 0x%" PRIx64 " != 0x%" PRIx64 "\n", \
               pm_cur_test, __FILE__, __LINE__, #a, #b, _a, _b); } \
} while (0)

#endif
