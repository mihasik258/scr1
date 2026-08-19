/// SCR1 Embench-IoT harness
/// @file       <embench_main.c>
/// @brief      Runs one Embench-IoT benchmark under the verilator testbench.
///
/// Replaces Embench's support/main.c: no timing triggers (cycle/MPKI come from
/// the testbench BP_PROFILE counters), output via sc_printf. main() returns 0
/// iff verify_benchmark() passes, so the tb passes on a0==0. A short warm-up
/// pass trains the predictor before the measured run.
#include "sc_print.h"

extern void initialise_benchmark (void);
extern void warm_caches (int temperature);
extern int  benchmark (void);
extern int  verify_benchmark (int result);

#ifndef WARMUP_HEAT
#define WARMUP_HEAT 1
#endif
#ifndef BENCH_NAME
#define BENCH_NAME "embench"
#endif

int main (void)
{
    int result, correct;
    initialise_benchmark ();
    warm_caches (WARMUP_HEAT);
    result  = benchmark ();
    correct = verify_benchmark (result);
    sc_printf ("Embench %s: result=%d %s\n", BENCH_NAME, result,
               correct ? "OK" : "FAIL");
    return correct ? 0 : 1;
}
