# AI Zone Trader 5 (MT5)

A MetaTrader 5 Expert Advisor. One chart scans every Market Watch symbol (forex, crypto, indices, stocks,
bonds, commodities: whatever the broker offers) on M1, M5, M15, M30, H1, H4, D1 and W1. It finds rule-based
setups (EMA/RSI/ATR, order blocks, BOS/CHOCH, trendlines), requires every confluence check and the
higher timeframes to agree, and sends a signal to Telegram only after Claude approves it.
Optional ✅/❌ approval buttons and auto-trading modes. Each trade has a stop-loss and a 3-part take profit: 50% at
1.5R, 25% at 2.25R and 25% at 3R, with the stop moved to entry and then to TP1.
Each AI keeps a journal of its past calls and writes itself lessons after mistakes.

Full guide (Uzbek): [mt5/README_UZ.md](mt5/README_UZ.md)

| Path | Purpose |
|---|---|
| `mt5/` | Everything that goes into MT5 and `Install-MT5.ps1`, which installs and compiles it |
| `mt5/AZT_Config.ini.example` | Format of the private `MQL5/Files/AZT_Config.ini` (all keys live there) |
| `tests/` | MQL5 test scripts, run in an isolated portable terminal |
| `mt5/VALIDATION.md` | What was compiled and tested |

No AI review guarantees profitable trades. Test on a demo account first.
