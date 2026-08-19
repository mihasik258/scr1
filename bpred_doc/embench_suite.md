# Embench-IoT suite для оценки предсказателя SCR1

Расширенный набор нагрузок для оценки предсказателя переходов — 16 программ
Embench-IoT, портированных в верилятор-харнес SCR1, плюс уже имевшиеся
CoreMark / Dhrystone / qsort. Даёт широкую и достоверную картину вместо 2 бенчей:
диапазон MPKI **0.1–48.8** и плотность ветвления **0–45%**.

## 1. Что сравнивали и как

- **Инструмент:** verilator, `CFG=RV32IMC_MAX`, rv32imc, каждый бенч CRC/verify-проверен
  (`main()` возвращает 0 iff `verify_benchmark()` прошёл).
- **Метрика предсказателя:** циклы при предсказателе **ON** (ранний BTB 256 + BTFN +
  BHT 1024×2b + RAS 4) против **No-BPU** (все блоки предсказателя выключены), при
  равной глубине очереди. Δ = (pred − NoBPU) / NoBPU.
- Интеграция: `sim/tests/benchmarks/embench_common/` (общий beebsc/main/support через
  VPATH) + папка на бенч; watchdog tb поднят до 500M циклов (длинные бенчи), стек в
  `link_tcm.ld` поднят до 16 КБ (иначе большие локалы в `verify` переполняют стек).

## 2. Результаты (predictor-only, % снижения циклов)

| Бенч | MPKI | плотн. веток | Δ очередь=2 | Δ очередь=4 |
|---|---|---|---|---|
| tarfind | 3.0 | 23% | **−18.44 %** | **−19.15 %** |
| wikisort | 16.8 | 18% | −12.36 % | −12.96 % |
| statemate | 6.9 | 22% | −9.18 % | −11.02 % |
| slre | 17.6 | 27% | −8.97 % | −10.08 % |
| huffbench | 33.2 | 23% | −8.48 % | −9.32 % |
| depthconv | 0.6 | 10% | −8.07 % | −8.80 % |
| nsichneu | 48.8 | 45% | −6.44 % | −7.11 % |
| sglib-combined | 46.5 | 27% | −5.94 % | −6.65 % |
| md5sum | 14.5 | 14% | −5.52 % | −6.89 % |
| edn | 3.7 | 3% | −2.29 % | −3.71 % |
| aha-mont64 | 22.1 | 8% | −2.68 % | −3.20 % |
| nettle-aes | 1.1 | 2% | −1.40 % | −1.89 % |
| crc32 | 0.1 | 1% | −0.83 % | −1.19 % |
| ud | 45.8 | 14% | −0.99 % | −0.84 % |
| matmult-int | 10.0 | 5% | −0.76 % | −0.81 % |
| nettle-sha256 | 0.9 | 0% | −0.09 % | −0.12 % |
| **Σ АГРЕГАТ** | | | **−5.38 %** | **−6.32 %** |

## 3. Выводы

1. **Агрегат predictor-only: −5.38 % (очередь=2), −6.32 % (очередь=4)** на 16 бенчах.
   Предсказатель конвертируется лучше на очереди=4 (глубже очередь — меньше маскировки
   пузырей), для почти всех бенчей Δq4 > Δq2.
2. **MPKI не равно выигрышу по циклам.** `ud` имеет MPKI 45.8 (очень branchy), но лишь
   −0.99 % — compute-bound (soft-float), промахи спрятаны за исполнением. Наоборот,
   `tarfind` при MPKI всего 3.0 даёт **−18.4 %** — call-heavy код, где RAS и ранний
   steer сильно экономят. Разброс −0.09 %…−19.2 % виден только на широком наборе;
   CoreMark один (−6.98 % q2) этого не показывает.
3. Наибольшая польза — на call-heavy / цикло-branchy коде (tarfind, wikisort,
   statemate, slre, huffbench); наименьшая — на compute-bound (matmult, ud) и
   слабо-ветвящихся (sha256, crc32).

## 4. Статус набора

- **16/16 PASS** (verify): nsichneu, sglib-combined, ud, huffbench, aha-mont64, slre,
  wikisort, md5sum, matmult-int, statemate, edn, tarfind, depthconv, nettle-aes,
  nettle-sha256, crc32.
- FP-бенчи (depthconv, statemate, ud) идут soft-float. Мульти-файловые (picojpeg,
  qrduino, xgboost) пока не подключены.
- Запуск: `make run_verilator CFG=MAX BUS=AHB TARGETS=<bench> SIM_BUILD_OPTS=-DSCR1_BP_PROFILE`.

*Все измерения: verilator, CFG=RV32IMC_MAX, CRC/verify-проверено. См. также
[optimization_study.md](optimization_study.md) и [board_silicon_matrix.md](board_silicon_matrix.md).*
