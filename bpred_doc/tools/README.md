# Инструменты оценки предсказателя (Stage-2)

Офлайн-модель точности направления + извлечение трейсов, к [../trace_accuracy.md](../trace_accuracy.md).

## Файлы
- `bpsim.c` — эталонная модель направления: always-NT / bimodal-2b-1024 (= BHT SCR1) /
  gshare 2-10б / gshare-64K / local-2level. Читает трейс `PC taken`, печатает mispred/accuracy.
- `bpsize.c` — свип размера таблицы (bimodal и gshare) по трейсу.
- `extract_trace.cpp` — извлекает `(PC, taken)` условных веток из CBP-NG трейса
  (нужен `trace_reader.hpp` из репозитория AmpereComputing/cbp-ng).

## Как получить трейс из SCR1 и прогнать
```bash
# 1. трейс реального прогона SCR1 (условные ветки):
make run_verilator CFG=MAX BUS=AHB TARGETS=<bench> SIM_BUILD_OPTS="-DSCR1_BP_PROFILE -DSCR1_BP_TRACE" \
  | grep '^BT ' | awk '{print $2,$3}' > bench.trace
# 2. модель:
gcc -O2 -o bpsim bpsim.c && ./bpsim bench.trace
gcc -O2 -o bpsize bpsize.c && ./bpsize bench.trace
# 3. CBP-NG трейс (в клоне cbp-ng):
./compile extract_trace -Wno-error && ./extract_trace trace.gz > cbp.trace && ./bpsim cbp.trace
```
