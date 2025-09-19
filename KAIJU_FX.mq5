//+------------------------------------------------------------------+
//|                           KAIJU FX                                |
//|  Multi-strategy EA with a banner/picture area (OBJ_BITMAP_LABEL)  |
//|  Default strategy: MA_Crossover                                   |
//+------------------------------------------------------------------+
#property copyright "KAIJU FX"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

// ----------------- USER INPUTS -----------------
input string Strategy         = "MA_Crossover"; // "MA_Crossover" | "RSI_Reversion" | "Breakout"
input int    MagicNumber      = 20250919;
input double RiskPercent      = 0.75;           // risk per trade (% of free margin)
input double FixedLot         = 0.0;            // if >0 uses fixed lot instead of risk sizing
input double MaxSpreadPoints  = 30.0;           // allowed spread (points)
input int    SlippagePoints   = 5;              // slippage in points
input int    StopLossPoints   = 400;            // stop loss in points (1 pip = 10 points for 5-digit pairs)
input int    TakeProfitPoints = 800;            // take profit in points (0 = none)
input bool   UseTrailing      = true;
input int    TrailingStartPts = 300;            // start trailing after this many points
input int    TrailingStepPts  = 100;
input int    MaxTrades        = 1;
input int    TradeStartHour   = 0;              // server time
input int    TradeEndHour     = 24;
input bool   TradeOnMonday    = true;
input bool   TradeOnTuesday   = true;
input bool   TradeOnWednesday = true;
input bool   TradeOnThursday  = true;
input bool   TradeOnFriday    = true;

// MA strategy inputs
input int FastMAPeriod = 9;
input int SlowMAPeriod = 21;
input ENUM_MA_METHOD MA_Method = MODE_EMA;
input ENUM_APPLIED_PRICE MA_PriceType = PRICE_CLOSE;

// Banner / picture settings (BMP)
input bool   ShowBanner   = true;
input string BannerFile   = "\\Images\\kaiju_banner.bmp"; // place BMP file in MQL5\\Images folder
input int    BannerCorner = 0;   // 0=CORNER_LEFT_UPPER, 1=CORNER_RIGHT_UPPER, 2=CORNER_LEFT_LOWER, 3=CORNER_RIGHT_LOWER
input int    BannerX      = 10;  // X offset in pixels from corner
input int    BannerY      = 10;  // Y offset in pixels from corner
// ------------------------------------------------

CTrade trade;

// --- helper: count positions opened by this EA on current symbol
int CountPositionsByMagic()
{
   int cnt = 0;
   for(int i=0; i<PositionsTotal(); ++i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) cnt++;
   }
   return cnt;
}

// --- compute lots from risk %
double CalcLotByRisk(double stopLossPoints)
{
   if(FixedLot > 0.0) return(NormalizeDouble(FixedLot, (int)SymbolInfoInteger(_Symbol, SYMBOL_VOLUME_DIGITS)));
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(freeMargin <= 0.0) return 0.0;
   double riskMoney = freeMargin * (RiskPercent/100.0);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double priceDiff = stopLossPoints * point;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
   {
      // fallback minimal lot
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      return NormalizeDouble(minLot, (int)SymbolInfoInteger(_Symbol, SYMBOL_VOLUME_DIGITS));
   }
   double ticks = priceDiff / tickSize;
   double valuePerLot = ticks * tickValue;
   if(valuePerLot <= 0.0) return 0.0;

   double lots = riskMoney / valuePerLot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double normalized = MathFloor(lots / lotStep) * lotStep;
   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;
   return NormalizeDouble(normalized, (int)SymbolInfoInteger(_Symbol, SYMBOL_VOLUME_DIGITS));
}

// --- time filter
bool IsTradingAllowedNow()
{
   int h = TimeHour(TimeCurrent());
   if(h < TradeStartHour || h >= TradeEndHour) return false;
   int wd = TimeDayOfWeek(TimeCurrent()); // 0=Sunday..6=Saturday
   if(wd == 1 && !TradeOnMonday) return false;
   if(wd == 2 && !TradeOnTuesday) return false;
   if(wd == 3 && !TradeOnWednesday) return false;
   if(wd == 4 && !TradeOnThursday) return false;
   if(wd == 5 && !TradeOnFriday) return false;
   if(wd == 0 || wd == 6) return false;
   return true;
}

// --- spread check
bool IsSpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask == 0.0 || bid == 0.0) return false;
   double spread_pts = (ask - bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return spread_pts <= MaxSpreadPoints;
}

// --- open order wrapper
bool OpenPosition(bool buy, double lots, int sl_pts, int tp_pts)
{
   if(lots <= 0.0) return false;
   if(!IsSpreadOK()) { Print("Spread too large, skipping trade."); return false; }

   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double sl = 0.0, tp = 0.0;
   if(sl_pts > 0)
   {
      if(buy) sl = price - sl_pts * point; else sl = price + sl_pts * point;
   }
   if(tp_pts > 0)
   {
      if(buy) tp = price + tp_pts * point; else tp = price - tp_pts * point;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   bool res = buy ? trade.Buy(lots, NULL, sl, tp, "KAIJU FX buy") : trade.Sell(lots, NULL, sl, tp, "KAIJU FX sell");
   if(!res)
   {
      Print("Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }
   PrintFormat("Opened %s %.2f lots (sl=%d tp=%d) ticket=%d", buy ? "BUY" : "SELL", lots, sl_pts, tp_pts, trade.ResultOrder());
   return true;
}

// --- trailing stop management
void ManageTrailingStops()
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      double profit_points = ((type==POSITION_TYPE_BUY) ? (current_price - open_price) : (open_price - current_price)) / point;
      double curr_sl = PositionGetDouble(POSITION_SL);

      if(profit_points >= TrailingStartPts)
      {
         double new_sl = (type==POSITION_TYPE_BUY) ? (current_price - TrailingStepPts*point) : (current_price + TrailingStepPts*point);
         bool need = (type==POSITION_TYPE_BUY) ? (new_sl > curr_sl + (0.5*point)) : (new_sl < curr_sl - (0.5*point));
         if(need)
         {
            trade.SetExpertMagicNumber(MagicNumber);
            if(!trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP)))
               Print("Trailing modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            else
               PrintFormat("Trailing SL updated for ticket %d to %.5f", ticket, new_sl);
         }
      }
   }
}

// --- create banner object (if requested)
void CreateBannerObject()
{
   if(!ShowBanner) return;
   string objName = "KAIJU_FX_BANNER";
   if(ObjectFind(0, objName) != -1) ObjectDelete(0, objName);

   if(!ObjectCreate(0, objName, OBJ_BITMAP_LABEL, 0, 0, 0))
   {
      Print("Failed to create banner object.");
      return;
   }
   ObjectSetInteger(0, objName, OBJPROP_CORNER, BannerCorner);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, BannerX);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, BannerY);
   ObjectSetString(0, objName, OBJPROP_BMPFILE, BannerFile);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, false);
   Print("Banner created. File: ", BannerFile);
}

void DeleteBannerObject()
{
   string objName = "KAIJU_FX_BANNER";
   if(ObjectFind(0, objName) != -1) ObjectDelete(0, objName);
}

int OnInit()
{
   Print("KAIJU FX initialized. Strategy=", Strategy);
   CreateBannerObject();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteBannerObject();
   Print("KAIJU FX deinitialized.");
}

void OnTick()
{
   static datetime lastBarTime = 0;
   MqlRates rates[];
   int neededBars = MathMax(SlowMAPeriod, 14) + 5;
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, neededBars, rates) <= 0) return;

   if(rates[0].time == lastBarTime) return;
   lastBarTime = rates[0].time;

   if(UseTrailing) ManageTrailingStops();
   if(!IsTradingAllowedNow()) return;
   if(!IsSpreadOK()) return;

   int openCount = CountPositionsByMagic();
   if(openCount >= MaxTrades) return;

   bool signalBuy = false, signalSell = false;

   if(Strategy == "MA_Crossover")
   {
      double fast = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, MA_Method, MA_PriceType, 1);
      double fast_prev = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, MA_Method, MA_PriceType, 2);
      double slow = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MA_Method, MA_PriceType, 1);
      double slow_prev = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MA_Method, MA_PriceType, 2);

      if(fast_prev <= slow_prev && fast > slow) signalBuy = true;
      if(fast_prev >= slow_prev && fast < slow) signalSell = true;
   }
   else if(Strategy == "RSI_Reversion")
   {
      double rsi = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE, 1);
      if(rsi < 30) signalBuy = true;
      if(rsi > 70) signalSell = true;
   }
   else if(Strategy == "Breakout")
   {
      int look = 20;
      double hh = iHigh(_Symbol, PERIOD_CURRENT, iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, look, 1));
      double ll = iLow(_Symbol, PERIOD_CURRENT, iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, look, 1));
      double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
      if(lastClose > hh) signalBuy = true;
      if(lastClose < ll) signalSell = true;
   }

   if(signalBuy || signalSell)
   {
      double lots = CalcLotByRisk(StopLossPoints);
      if(lots <= 0.0) { Print("Calculated lot <=0, skipping."); return; }
      OpenPosition(signalBuy, lots, StopLossPoints, TakeProfitPoints);
   }
}
//+------------------------------------------------------------------+
