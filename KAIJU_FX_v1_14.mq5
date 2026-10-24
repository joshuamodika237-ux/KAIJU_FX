//+------------------------------------------------------------------+
//|                         KAIJU FX v1.14                           |
//| MT5 Expert Advisor: MA crossover, RSI reversion, breakout        |
//| Preserves banner, trailing stop, schedule, and risk controls     |
//+------------------------------------------------------------------+
#property copyright "KAIJU FX"
#property version   "1.14"
#property strict

#include <Trade\Trade.mqh>

input string Strategy         = "MA_Crossover"; // MA_Crossover | RSI_Reversion | Breakout
input ulong  MagicNumber      = 20250919;
input double RiskPercent      = 0.75;   // percent of equity risked, estimated from stop distance
input double FixedLot         = 0.0;    // >0 uses fixed volume
input double MaxSpreadPoints  = 30.0;
input int    SlippagePoints   = 5;
input int    StopLossPoints   = 400;
input int    TakeProfitPoints = 800;    // 0 = no TP
input bool   UseTrailing      = true;
input int    TrailingStartPts = 300;
input int    TrailingStepPts  = 100;
input int    MaxTrades        = 1;
input int    TradeStartHour   = 0;      // broker/server time; 0-23
input int    TradeEndHour     = 24;     // exclusive; 24 means through end of day
input bool   TradeOnMonday    = true;
input bool   TradeOnTuesday   = true;
input bool   TradeOnWednesday = true;
input bool   TradeOnThursday  = true;
input bool   TradeOnFriday    = true;

input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int FastMAPeriod = 9;
input int SlowMAPeriod = 21;
input ENUM_MA_METHOD MA_Method = MODE_EMA;
input ENUM_APPLIED_PRICE MA_PriceType = PRICE_CLOSE;
input int RSIPeriod = 14;
input double RSI_Oversold = 30.0;
input double RSI_Overbought = 70.0;
input int BreakoutLookback = 20;

input bool   ShowBanner   = true;
input string BannerFile   = "\\Images\\kaiju_banner.bmp";
input int    BannerCorner = 0;
input int    BannerX      = 10;
input int    BannerY      = 10;

CTrade trade;
int fastMAHandle = INVALID_HANDLE;
int slowMAHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
datetime lastSignalBarTime = 0;
string bannerObjectName = "KAIJU_FX_BANNER";

int VolumeDigitsFromStep(double step)
{
   int digits = 0;
   while(digits < 8 && MathAbs(step - MathRound(step)) > 1e-8)
   {
      step *= 10.0;
      digits++;
   }
   return digits;
}

double NormalizeVolumeDown(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || minLot <= 0.0 || maxLot <= 0.0) return 0.0;
   volume = MathMin(volume, maxLot);
   volume = MathFloor((volume + 1e-10) / step) * step;
   volume = NormalizeDouble(volume, VolumeDigitsFromStep(step));
   // Do not force the broker minimum if that would exceed the requested risk.
   if(volume < minLot) return 0.0;
   return volume;
}

// Align prices to the symbol's tradable tick size, not only its decimal digits.
double NormalizePriceDown(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tickSize <= 0.0) return NormalizeDouble(price, digits);
   return NormalizeDouble(MathFloor(price / tickSize + 1e-10) * tickSize, digits);
}

double NormalizePriceUp(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tickSize <= 0.0) return NormalizeDouble(price, digits);
   return NormalizeDouble(MathCeil(price / tickSize - 1e-10) * tickSize, digits);
}

int CountPositionsByMagic()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) count++;
   }
   return count;
}

bool IsTradingAllowedNow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Reject invalid hours and treat equal start/end as a disabled session.
   if(TradeStartHour < 0 || TradeStartHour > 23 ||
      TradeEndHour < 1 || TradeEndHour > 24 ||
      TradeStartHour == TradeEndHour)
      return false;

   bool inSession = false;
   if(TradeEndHour == 24 || TradeStartHour < TradeEndHour)
      inSession = (dt.hour >= TradeStartHour && dt.hour < TradeEndHour);
   else
      // Overnight session, e.g. 22:00 to 06:00 server time.
      inSession = (dt.hour >= TradeStartHour || dt.hour < TradeEndHour);

   if(!inSession) return false;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 1 && !TradeOnMonday) return false;
   if(dt.day_of_week == 2 && !TradeOnTuesday) return false;
   if(dt.day_of_week == 3 && !TradeOnWednesday) return false;
   if(dt.day_of_week == 4 && !TradeOnThursday) return false;
   if(dt.day_of_week == 5 && !TradeOnFriday) return false;
   return true;
}

bool IsSpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0) return false;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return false;
   return ((tick.ask - tick.bid) / point) <= MaxSpreadPoints;
}

bool IsNewSignalBar()
{
   datetime barTime = iTime(_Symbol, SignalTimeframe, 0);
   if(barTime == 0 || barTime == lastSignalBarTime) return false;
   lastSignalBarTime = barTime;
   return true;
}

bool GetBufferValue(int handle, int shift, double &value)
{
   double values[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, shift, 1, values) != 1) return false;
   value = values[0];
   return true;
}

int GetSignal()
{
   if(Strategy == "MA_Crossover")
   {
      double fast1, fast2, slow1, slow2;
      if(!GetBufferValue(fastMAHandle, 1, fast1) ||
         !GetBufferValue(fastMAHandle, 2, fast2) ||
         !GetBufferValue(slowMAHandle, 1, slow1) ||
         !GetBufferValue(slowMAHandle, 2, slow2)) return 0;
      if(fast2 <= slow2 && fast1 > slow1) return 1;
      if(fast2 >= slow2 && fast1 < slow1) return -1;
      return 0;
   }

   if(Strategy == "RSI_Reversion")
   {
      double rsi1, rsi2;
      if(!GetBufferValue(rsiHandle, 1, rsi1) || !GetBufferValue(rsiHandle, 2, rsi2)) return 0;
      if(rsi2 < RSI_Oversold && rsi1 >= RSI_Oversold) return 1;
      if(rsi2 > RSI_Overbought && rsi1 <= RSI_Overbought) return -1;
      return 0;
   }

   if(Strategy == "Breakout")
   {
      if(BreakoutLookback < 2) return 0;
      double highs[], lows[];
      ArraySetAsSeries(highs, true);
      ArraySetAsSeries(lows, true);
      // Start at shift 2 so the signal candle cannot be part of the range.
      if(CopyHigh(_Symbol, SignalTimeframe, 2, BreakoutLookback, highs) != BreakoutLookback ||
         CopyLow(_Symbol, SignalTimeframe, 2, BreakoutLookback, lows) != BreakoutLookback) return 0;
      int hiIndex = ArrayMaximum(highs);
      int loIndex = ArrayMinimum(lows);
      if(hiIndex < 0 || loIndex < 0) return 0;
      double priorHigh = highs[hiIndex];
      double priorLow = lows[loIndex];
      double close1 = iClose(_Symbol, SignalTimeframe, 1);
      if(close1 > priorHigh) return 1;
      if(close1 < priorLow) return -1;
   }
   else
   {
      Print("KAIJU FX: Unknown Strategy input: ", Strategy);
   }
   return 0;
}

double CalcLotByRisk(ENUM_ORDER_TYPE orderType, double entry, double stop)
{
   // Fixed-lot mode intentionally bypasses percentage-based sizing.
   if(FixedLot > 0.0)
      return NormalizeVolumeDown(FixedLot);

   if(RiskPercent <= 0.0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
   double estimatedProfit = 0.0;
   ResetLastError();
   if(equity <= 0.0 || riskMoney <= 0.0 ||
      !OrderCalcProfit(orderType, _Symbol, 1.0, entry, stop, estimatedProfit))
   {
      Print("KAIJU FX: Could not calculate risk-based volume. Error ", GetLastError());
      return 0.0;
   }
   double lossOneLot = MathAbs(estimatedProfit);
   if(lossOneLot <= 0.0) return 0.0;

   double lots = NormalizeVolumeDown(riskMoney / lossOneLot);
   if(lots <= 0.0) return 0.0;

   // Recalculate estimated loss for the final, broker-normalized volume.
   double finalProfit = 0.0;
   ResetLastError();
   if(!OrderCalcProfit(orderType, _Symbol, lots, entry, stop, finalProfit))
   {
      Print("KAIJU FX: Could not verify estimated loss for normalized volume. Error ", GetLastError());
      return 0.0;
   }
   double estimatedLoss = MathAbs(finalProfit);
   if(estimatedLoss > riskMoney + 0.01)
   {
      Print("KAIJU FX: Normalized volume would exceed configured estimated risk; trade skipped.");
      return 0.0;
   }
   Print("KAIJU FX: Risk sizing: equity=", DoubleToString(equity, 2),
         " riskBudget=", DoubleToString(riskMoney, 2),
         " estimatedSLloss=", DoubleToString(estimatedLoss, 2),
         " lots=", DoubleToString(lots, VolumeDigitsFromStep(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP))));
   return lots;
}

bool OpenPosition(bool buy)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || !IsSpreadOK())
   {
      Print("KAIJU FX: No trade; price unavailable or spread too high.");
      return false;
   }
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(point <= 0 || StopLossPoints <= 0)
   {
      Print("KAIJU FX: StopLossPoints must be greater than zero.");
      return false;
   }

   double entry = buy ? tick.ask : tick.bid;
   double slDistance = StopLossPoints * point;
   double tpDistance = TakeProfitPoints * point;
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (double)stopLevel * point;
   if(slDistance + 1e-10 < minDistance || (TakeProfitPoints > 0 && tpDistance + 1e-10 < minDistance))
   {
      Print("KAIJU FX: SL/TP distance is below broker minimum stop distance.");
      return false;
   }
   double sl = buy ? NormalizePriceDown(entry - slDistance) : NormalizePriceUp(entry + slDistance);
   double tp = 0.0;
   if(TakeProfitPoints > 0)
      tp = buy ? NormalizePriceUp(entry + tpDistance) : NormalizePriceDown(entry - tpDistance);
   // Recheck the rounded prices against the current market and broker stop level.
   if((buy && (entry - sl + 1e-10 < minDistance || (tp > 0.0 && tp - entry + 1e-10 < minDistance))) ||
      (!buy && (sl - entry + 1e-10 < minDistance || (tp > 0.0 && entry - tp + 1e-10 < minDistance))))
   {
      Print("KAIJU FX: Rounded SL/TP does not meet broker stop distance.");
      return false;
   }

   ENUM_ORDER_TYPE orderType = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lots = CalcLotByRisk(orderType, entry, sl);
   if(lots <= 0.0)
   {
      Print("KAIJU FX: Calculated volume is below broker minimum or risk inputs are invalid; skipped.");
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool sent = buy ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "KAIJU FX buy")
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, "KAIJU FX sell");
   if(!sent || (trade.ResultRetcode() != TRADE_RETCODE_DONE &&
                trade.ResultRetcode() != TRADE_RETCODE_PLACED &&
                trade.ResultRetcode() != TRADE_RETCODE_DONE_PARTIAL))
   {
      Print("KAIJU FX: Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   Print("KAIJU FX: Order accepted. Side=", buy ? "BUY" : "SELL",
         " lots=", DoubleToString(lots, VolumeDigitsFromStep(volumeStep)), " SL=", DoubleToString(sl, digits),
         " TP=", tp == 0.0 ? "none" : DoubleToString(tp, digits));
   return true;
}

void ManageTrailingStops()
{
   if(!UseTrailing || TrailingStartPts <= 0 || TrailingStepPts <= 0) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return;
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   // Keep the proposed SL outside both broker restriction zones, with one extra point.
   double minDistance = (double)MathMax(stopLevel, freezeLevel) * point + point;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber ||
         PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_BUY && type != POSITION_TYPE_SELL) continue;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double current = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      double profitPoints = (type == POSITION_TYPE_BUY ? current - openPrice : openPrice - current) / point;
      if(profitPoints < TrailingStartPts) continue;
      double oldSL = PositionGetDouble(POSITION_SL);
      double oldTP = PositionGetDouble(POSITION_TP);
      // Avoid modification when the existing stop is inside the broker freeze zone.
      if(oldSL > 0.0 && freezeLevel > 0 && MathAbs(current - oldSL) <= (double)freezeLevel * point)
         continue;
      double newSL = (type == POSITION_TYPE_BUY) ? current - TrailingStepPts * point
                                                 : current + TrailingStepPts * point;
      if(type == POSITION_TYPE_BUY)
      {
         if(current - newSL < minDistance) newSL = current - minDistance;
         newSL = NormalizePriceDown(newSL);
         if(oldSL != 0.0 && newSL <= oldSL + point * 0.5) continue;
         if(current - newSL + 1e-10 < (double)stopLevel * point) continue;
      }
      else
      {
         if(newSL - current < minDistance) newSL = current + minDistance;
         newSL = NormalizePriceUp(newSL);
         if(oldSL != 0.0 && newSL >= oldSL - point * 0.5) continue;
         if(newSL - current + 1e-10 < (double)stopLevel * point) continue;
      }
      if(!trade.PositionModify(ticket, newSL, oldTP) ||
         (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_NO_CHANGES))
         Print("KAIJU FX: Trailing-stop update failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

void CreateBannerObject()
{
   if(!ShowBanner) return;
   if(ObjectFind(0, bannerObjectName) >= 0) ObjectDelete(0, bannerObjectName);
   if(!ObjectCreate(0, bannerObjectName, OBJ_BITMAP_LABEL, 0, 0, 0))
   {
      Print("KAIJU FX: Could not create banner object. Check BMP path.");
      return;
   }
   ObjectSetInteger(0, bannerObjectName, OBJPROP_CORNER, BannerCorner);
   ObjectSetInteger(0, bannerObjectName, OBJPROP_XDISTANCE, BannerX);
   ObjectSetInteger(0, bannerObjectName, OBJPROP_YDISTANCE, BannerY);
   ObjectSetString(0, bannerObjectName, OBJPROP_BMPFILE, 0, BannerFile);
   ObjectSetInteger(0, bannerObjectName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bannerObjectName, OBJPROP_HIDDEN, false);
   ChartRedraw(0);
}

int OnInit()
{
   if(FastMAPeriod < 1 || SlowMAPeriod < 2 || RSIPeriod < 2 ||
      RSI_Oversold < 0 || RSI_Overbought > 100 || RSI_Oversold >= RSI_Overbought ||
      MaxTrades < 1 || MaxSpreadPoints < 0 || SlippagePoints < 0 ||
      StopLossPoints <= 0 || TakeProfitPoints < 0 ||
      RiskPercent < 0.0 || RiskPercent > 100.0 || FixedLot < 0.0 ||
      (FixedLot == 0.0 && RiskPercent <= 0.0) ||
      TrailingStartPts < 0 || TrailingStepPts < 0 || BreakoutLookback < 2 ||
      TradeStartHour < 0 || TradeStartHour > 23 || TradeEndHour < 1 || TradeEndHour > 24 ||
      BannerCorner < 0 || BannerCorner > 3 ||
      (Strategy != "MA_Crossover" && Strategy != "RSI_Reversion" && Strategy != "Breakout"))
   {
      Print("KAIJU FX: Invalid input settings.");
      return INIT_PARAMETERS_INCORRECT;
   }
   fastMAHandle = iMA(_Symbol, SignalTimeframe, FastMAPeriod, 0, MA_Method, MA_PriceType);
   slowMAHandle = iMA(_Symbol, SignalTimeframe, SlowMAPeriod, 0, MA_Method, MA_PriceType);
   rsiHandle = iRSI(_Symbol, SignalTimeframe, RSIPeriod, PRICE_CLOSE);
   if(fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      Print("KAIJU FX: Indicator creation failed. Error ", GetLastError());
      return INIT_FAILED;
   }
   if(FixedLot > 0.0)
      Print("KAIJU FX: Fixed-lot mode active; RiskPercent is not used for position sizing.");
   else
      Print("KAIJU FX: Percentage-risk mode active at ", DoubleToString(RiskPercent, 2), "% of equity (estimated SL risk).");
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   lastSignalBarTime = iTime(_Symbol, SignalTimeframe, 0);
   CreateBannerObject();
   Print("KAIJU FX v1.14 initialized. Strategy=", Strategy, " symbol=", _Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE) IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE) IndicatorRelease(slowMAHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(ObjectFind(0, bannerObjectName) >= 0) ObjectDelete(0, bannerObjectName);
   ChartRedraw(0);
}

void OnTick()
{
   // Manage an open position on every tick, not only when a new candle appears.
   ManageTrailingStops();
   if(!IsNewSignalBar()) return;
   if(!IsTradingAllowedNow() || !IsSpreadOK()) return;
   if(CountPositionsByMagic() >= MaxTrades) return;
   int signal = GetSignal();
   if(signal == 1) OpenPosition(true);
   else if(signal == -1) OpenPosition(false);
}
//+------------------------------------------------------------------+
