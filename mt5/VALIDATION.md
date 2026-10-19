# Validation — EA 5.00 (multi-timeframe)

**Not compiled yet.** Version 5.00 was written without access to MetaEditor (the build machine
cannot download MetaTrader). Before use:

1. Run `Install-MT5.ps1` (it compiles with the terminal's MetaEditor and prints `Compiled:` or the errors),
   or open `AI_Zone_Trader_EA.mq5` in MetaEditor and press F7. Expect 0 errors.
2. Compile and run `tests/test_mt5_signals.mq5` (new checks: timeframe list, strict gate, defaults).
   `tests/test_mt5_structure_history.mq5` exercises the history replay, which now also applies the strict
   gate (`RequireAllChecks`): if its expected counts change, review them against the new rule.
3. On a demo account: attach to one chart, press **Telegram TEST** and **AI TEST**, wait for the
   "EA ISHGA TUSHDI" message listing M5..D1 as ready.

Changes in 5.00: one chart scans `ScanTimeframes`; higher-timeframe alignment gate; no opposing
confluence factor allowed; Claude APPROVE >= `MinAIConfidence` required before anything is sent;
chart image only for verified signals; heartbeat/start messages; AI-failure warning; default
`AZT_SIGNALS_ONLY`; `AZT_signals_v5.csv` export with the AI verdict; Install-MT5.ps1 compiles instead
of shipping a prebuilt .ex5.

Fixes after 5.00 review (not compiled yet either; compile and run the tests as above):
- MTF filter: when higher timeframes exist but none has data yet, the signal is blocked instead of passing unchecked
  (new check in `test_mt5_signals`).
- Timeframes are scanned highest first, so slow Claude calls cannot make H4/D1 signals "late".
- Telegram queue holds 30 items (was 8): several timeframes closing together no longer drop signals.
- Auto orders: if the new position is not yet visible, the trade result is used so TP1/TP2 management still runs.
- Closed-trade report waits for the exit deal in history (no false "SAVDO YOPILDI" after a reconnect).
- `AZT_signals_v5.csv` is written as UTF-8; Claude prompt, journal memory and lessons use the configured TP R values.
- Failed OnInit no longer leaves stale indicator handles for OnDeinit.

EA 5.20 (not compiled yet; compile and run the tests as above):
- One EA instance scans every Market Watch symbol (`ScanSymbols`, `MaxSymbols`) on `M1,M5,M15,M30,H1,H4,D1,W1`.
  Code uses `Sym`/`SymPoint`/`SymDigits` (AZT_Json.mqh) instead of `_Symbol`/`_Point`/`_Digits`; state is per
  slot = symbol x timeframe (`SwitchSlot`). Tests call `AZTSelectSymbol(_Symbol)` first.
- First history load is throttled to 4 slots per scan; the rule replay refreshes every `HistoryRefreshBars` candles.
- `EntryMode` market / limit / both; BUY/SELL LIMIT at the zone with its own targets, cancelled after
  `LimitExpiryBars`; `MaxOpenPositions` 10, `MaxPendingOrders` 10. Position records are scoped by magic only.
- Accuracy %: TP1 hit rate of the rules on that symbol/TF (averaged with Claude's confidence); `MinAccuracyPercent` gate.
- Default exit back to partial TP1 (50%) with the stop locked at entry + `BreakevenLockR` (0.1R).
- Asset class (forex, crypto, index, stock, bond, commodity) from the symbol path; London/NY session filter only for FX/metals.
- Telegram photo caption: one value per line with emojis.

EA 5.10 (not compiled yet; compile and run the tests as above):
- New `AZT_Strategies.mqh`, which `Install-MT5.ps1` now copies too. It adds SMC/ICT liquidity sweeps and
  premium/discount, range breakouts, morning/evening star, inside bar, three soldiers/crows, HH/HL structure,
  Stochastic, ADX, tick-volume spikes and a volatility-regime filter.
- `StrategyGates` (called from `StrictChecks`, so live signals and the history replay both use it) applies the
  London/New York session filter on M5/M15, a spread/SL cost limit and a sniper limit on how far price is from the
  zone. It then requires `MinFamilies` (default 5) of the 11 strategy families to confirm.
- Live quant gate: no signal when this timeframe's replay has `MinHistorySamples`+ results and expectancy
  < `MinHistoryExpectancyR`.
- `UsePartialTP=false` (default): the whole lot runs to TP3 = 3R (1:3) and the stop trails to entry/TP1.
  `test_mt5_structure_history` expectations now depend on this input.
- Defaults tightened: RSI 50–65 / 35–50, `MTFMinAgreePercent` 67.

---

Current revision: Claude-only. Earlier runtime results below predate this change.

# Validation — EA 4.00

- `AI_Zone_Trader_EA.mq5` compiled with MetaEditor: **0 errors, 0 warnings** (X64 Regular).
- Test scripts were compiled (0 errors, 0 warnings) and run in an isolated portable
  MT5 instance with Algo Trading off and no account login:
  - `test_mt5_signals`: **17 passed, 0 failed**. Covers signal rules and defaults
    (AI hybrid mode, 1:3 main target).
  - `test_mt5_structure_history`: **31 passed, 0 failed**. Covers structure and order
    blocks, plus the 3-part exit plan:
    - full plan = 2.0625R
    - TP1 then breakeven = +0.75R
    - TP1 and TP2, then stop at TP1 = +1.6875R
    - stop-first on ambiguous bars
    - lot splitting (0.04 → 0.02/0.01/0.01; 0.01 never split)
    - journal scoring, per-AI precision and memory text
    - CSV save/load
  - `test_mt5_telegram`: **40 passed, 0 failed**. WebRequest is faked, so nothing reaches
    Telegram, Anthropic. Covers:
    - the send queue
    - JSON decoding
    - AI verdict parsing
    - the lessons file (newest 30)
    - approval buttons and `getUpdates` callbacks
    - rejection of the wrong chat and of non-admin users
- `Install-MT5.ps1` was run against the local MT5 terminal. It installed the EA into
  `MQL5/Experts/AI_Zone_Trader/` and created `MQL5/Files/AZT_Config.ini` with the

Not verified: live Claude answers (use the chart's **AI TEST** button), live
Telegram button presses, broker execution of partial closes and stop moves, and
profitability. Check these on a demo account.

To run a test: compile it in place, copy the EX5 to the portable terminal's
`MQL5/Scripts`, then start `terminal64.exe /portable /config:<ini>` with the script
named in `[StartUp]`. Results are written to `MQL5/Files/azt_*_result.txt`.

Claude-only revision: EA compiled with 0 errors, 0 warnings. Offline structure/history: 31 passed, 0 failed. Offline Telegram/AI/lessons: 40 passed, 0 failed. Live API calls were not tested.


2026-10-14: image signals / parallel positions revision
- EA: MetaEditor 0 errors, 0 warnings.
- Offline Telegram/AI: 44 passed, 0 failed; includes PNG multipart assembly and queue cleanup.
- Offline structure/history: 31 passed, 0 failed.
- Offline signals/position capacity: 27 passed, 0 failed; includes second/third hedging entries, fourth-entry rejection, pending orders and netting guard.
- Production screenshot path exercised in isolated terminal on cached EURUSD candles; 1600x900 PNG visually inspected. Preview is explicitly labelled offline, with synthetic trade levels.
- No live API messages or broker trades were sent. Installed live terminal was not changed.
