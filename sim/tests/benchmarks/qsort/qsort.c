/// SCR1 qsort benchmark
/// @file       <qsort.c>
/// @brief      Deterministic recursive quicksort over 2048 integers.
///
/// A branch-heavy integer workload (recursion + per-element comparisons),
/// added as a third performance point next to coremark/dhrystone for
/// branch-predictor evaluation. Matches the "Qsort 2048 numbers" workload
/// used in Martinez Aceves, "Implementation and evaluation of Branch
/// Predictors on RISC-V" (ch07). Self-checking: main() returns 0 iff the
/// array is correctly sorted (the testbench passes on a0==0).

#include "sc_print.h"

#define QSORT_N 2048

// Deterministic LCG so every run sorts the exact same permutation.
static unsigned long lcg_state;
static unsigned lcg_next(void)
{
    lcg_state = lcg_state * 1103515245UL + 12345UL;
    return (unsigned)(lcg_state >> 16) & 0xffffu;
}

static int arr[QSORT_N];

// Hoare-partition quicksort. Recurses into the smaller half and loops on the
// larger one (bounds the stack). Deliberately branchy: the two inner do/while
// scan loops and the recursion are exactly the hard-to-predict control flow a
// branch predictor is meant to help.
static void quicksort(int *a, int lo, int hi)
{
    while (lo < hi) {
        int pivot = a[(lo + hi) >> 1];
        int i = lo - 1;
        int j = hi + 1;
        for (;;) {
            do { i++; } while (a[i] < pivot);
            do { j--; } while (a[j] > pivot);
            if (i >= j) break;
            int t = a[i]; a[i] = a[j]; a[j] = t;
        }
        if (j - lo < hi - (j + 1)) {
            quicksort(a, lo, j);
            lo = j + 1;
        } else {
            quicksort(a, j + 1, hi);
            hi = j;
        }
    }
}

int main(void)
{
    lcg_state = 0x12345678UL;
    for (int i = 0; i < QSORT_N; i++)
        arr[i] = (int)lcg_next();

    quicksort(arr, 0, QSORT_N - 1);

    int ok = 1;
    unsigned sum = 0;
    for (int i = 0; i < QSORT_N; i++) {
        if (i > 0 && arr[i] < arr[i - 1]) ok = 0;
        sum += (unsigned)arr[i];
    }

    sc_printf("Qsort %d ints: checksum=0x%x %s\n",
              QSORT_N, sum, ok ? "SORTED" : "UNSORTED");

    return ok ? 0 : 1;
}
