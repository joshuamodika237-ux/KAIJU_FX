# KAIJU FX

KAIJU FX — an MT5 Expert Advisor implementing an MA Crossover strategy by default.  
Includes optional on-chart BMP banner support.

## Files
- `KAIJU_FX.mq5` — main EA source.
- `Images/kaiju_banner.bmp` — optional banner image (place in MT5 `MQL5\Images`).

## Install (MT5 Desktop)
1. Download or clone this repo.
2. In MT5 Desktop: **File → Open Data Folder**.
3. Copy `KAIJU_FX.mq5` into `MQL5/Experts/`.
4. Copy `kaiju_banner.bmp` into `MQL5/Images/`.
5. Open MetaEditor (F4), find `KAIJU_FX.mq5` and **Compile** (F7).
6. Attach the EA to a chart (Navigator → Expert Advisors → KAIJU FX).
7. Enable **AutoTrading** and adjust inputs as needed.

## Inputs (high level)
- `Strategy` — `"MA_Crossover"` (default), `"RSI_Reversion"`, `"Breakout"`.
- `RiskPercent` — percentage of free margin risked per trade.
- `StopLossPoints` / `TakeProfitPoints` — expressed in **points** (note: 1 pip = 10 points for 5-digit FX pairs).
- `ShowBanner` / `BannerFile` / `BannerCorner` / `BannerX` / `BannerY` — banner configuration.

## Notes & Warnings
- EAs run only on **MT5 Desktop** (not mobile).
- Use a demo account first.
- This software is for educational/demo use. Trade at your own risk.

## License
MIT — see `LICENSE`.
