//+------------------------------------------------------------------+
//|                         XAUUSD_M1_Scalper.mq5 (EMA + Pyramiding) |
//|   Gold trading bot with EMA trend filter, news filter, TP1/TP2   |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property copyright "EA Bot"

#include <Trade/Trade.mqh>

enum DailyProfitMode
{
   DAILY_PROFIT_OFF = 0,
   DAILY_PROFIT_PERCENT = 1
};

enum CurrencyFilter
{
   CURR_ANY = 0,
   CURR_USD = 1,
   CURR_EUR = 2,
   CURR_GBP = 3,
   CURR_JPY = 4,
   CURR_CHF = 5,
   CURR_AUD = 6,
   CURR_CAD = 7,
   CURR_NZD = 8
};

const int PYRAMID_LEVELS = 100;
CTrade trade;

input group "Main Settings"
input int            InpMagicNumber                 = 7;
input int            InpMaxLegsForTP1               = 5;
input double         InpTP1Points                   = 800.0;
input double         InpTP2Points                   = 400.0;
input double         InpMaxEquityLossPercent        = 50.0;
input DailyProfitMode InpDailyProfitMode            = DAILY_PROFIT_OFF;
input double         InpDailyProfitValue            = 10.0;
input int            InpEMAPeriod                   = 200;
input ENUM_TIMEFRAMES InpTrendTimeframe             = PERIOD_M1;
input int            InpSlippagePoints              = 20;

input group "Lot Settings"
input double         InpBaseLotSize                 = 0.01;
input double         InpLotStepPerLevel             = 0.01;
input double         InpMaxLotSize                  = 1.00;

input group "News Filter"
input bool           InpUseNewsFilter               = true;
input CurrencyFilter InpPrimaryCurrency             = CURR_ANY;
input CurrencyFilter InpSecondaryCurrency           = CURR_ANY;
input int            InpMinutesBeforeHighNews       = 30;
input int            InpMinutesAfterHighNews        = 10;
input bool           InpDisplayNewsAlerts           = true;
input int            InpNewsLookaheadHours          = 24;
input color          InpNewsHighlightColor          = clrWhite;

input group "Trade Controls"
input bool           InpAllowLong                   = true;
input bool           InpAllowShort                  = true;
input bool           InpOneDirectionAtATime         = true;

int      hEMA = INVALID_HANDLE;
datetime gLastM1BarTime = 0;
double   gSessionStartEquity = 0.0;
int      gCurrentDayKey = -1;
bool     gTradingHalted = false;
string   gStatus = "Initializing";
datetime gLastNewsAlertTime = 0;

//+------------------------------------------------------------------+
string CurrencyCodeFromFilter(const CurrencyFilter c)
{
   switch(c)
   {
      case CURR_USD: return "USD";
      case CURR_EUR: return "EUR";
      case CURR_GBP: return "GBP";
      case CURR_JPY: return "JPY";
      case CURR_CHF: return "CHF";
      case CURR_AUD: return "AUD";
      case CURR_CAD: return "CAD";
      case CURR_NZD: return "NZD";
      default:       return "";
   }
}

//+------------------------------------------------------------------+
int DayKey(const datetime ts)
{
   MqlDateTime t;
   TimeToStruct(ts, t);
   return (t.year * 10000 + t.mon * 100 + t.day);
}

//+------------------------------------------------------------------+
bool IsNewM1Bar()
{
   datetime barTs = iTime(_Symbol, PERIOD_M1, 0);
   if(barTs == 0)
      return false;
   if(barTs != gLastM1BarTime)
   {
      gLastM1BarTime = barTs;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool GetEMAValue(const int shift, double &ema)
{
   if(hEMA == INVALID_HANDLE)
      return false;
   double buf[];
   if(CopyBuffer(hEMA, 0, shift, 1, buf) != 1)
      return false;
   ema = buf[0];
   return (ema > 0.0);
}

//+------------------------------------------------------------------+
double NormalizeVolume(const double rawVolume)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepVol <= 0.0)
      stepVol = 0.01;

   double vol = MathFloor(rawVolume / stepVol) * stepVol;
   vol = MathMax(vol, minVol);
   vol = MathMin(vol, maxVol);
   return NormalizeDouble(vol, 2);
}

//+------------------------------------------------------------------+
double LotForLevel(const int level)
{
   int lv = MathMax(1, MathMin(PYRAMID_LEVELS, level));
   double lot = InpBaseLotSize + ((double)(lv - 1) * InpLotStepPerLevel);
   lot = MathMin(InpMaxLotSize, lot);
   return NormalizeVolume(lot);
}

//+------------------------------------------------------------------+
double DistancePointsForLevel(const int level)
{
   int lv = MathMax(1, MathMin(PYRAMID_LEVELS, level));
   if(PYRAMID_LEVELS <= 1)
      return 100.0;

   double dist = 100.0 + ((double)(lv - 1) * 400.0 / (double)(PYRAMID_LEVELS - 1));
   return MathRound(dist);
}

//+------------------------------------------------------------------+
bool PassesCurrencyFilter(const string eventCurrency)
{
   string c1 = CurrencyCodeFromFilter(InpPrimaryCurrency);
   string c2 = CurrencyCodeFromFilter(InpSecondaryCurrency);
   if(c1 == "" && c2 == "")
      return true;

   if(c1 != "" && eventCurrency == c1)
      return true;
   if(c2 != "" && eventCurrency == c2)
      return true;
   return false;
}

//+------------------------------------------------------------------+
string EventCurrencyFromCountry(const MqlCalendarEvent &ev)
{
   MqlCalendarCountry country;
   if(CalendarCountryById(ev.country_id, country))
      return country.currency;
   return "";
}

//+------------------------------------------------------------------+
bool IsHighImpactNewsBlocked(datetime &nearestEventTs, string &nearestCurrency)
{
   nearestEventTs = 0;
   nearestCurrency = "";

   if(!InpUseNewsFilter)
      return false;

   MqlCalendarValue events[];
   datetime fromTs = TimeTradeServer() - (datetime)(InpMinutesBeforeHighNews * 60);
   datetime toTs = TimeTradeServer() + (datetime)(InpNewsLookaheadHours * 3600);
   int count = CalendarValueHistory(events, fromTs, toTs, NULL, NULL);
   if(count <= 0)
      return false;

   datetime nowTs = TimeTradeServer();
   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(events[i].event_id, ev))
         continue;
      string eventCurrency = EventCurrencyFromCountry(ev);

      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      if(!PassesCurrencyFilter(eventCurrency))
         continue;

      datetime eventTs = events[i].time;
      long deltaSec = (long)(eventTs - nowTs);
      long startBlock = -(long)InpMinutesBeforeHighNews * 60;
      long endBlock = (long)InpMinutesAfterHighNews * 60;

      if(deltaSec >= startBlock && deltaSec <= endBlock)
      {
         nearestEventTs = eventTs;
         nearestCurrency = eventCurrency;
         return true;
      }

      if(nearestEventTs == 0 || MathAbs((long)(eventTs - nowTs)) < MathAbs((long)(nearestEventTs - nowTs)))
      {
         nearestEventTs = eventTs;
         nearestCurrency = eventCurrency;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
void NewsAlert(const string msg)
{
   if(!InpDisplayNewsAlerts)
      return;

   datetime nowTs = TimeTradeServer();
   if((nowTs - gLastNewsAlertTime) < 30)
      return;

   gLastNewsAlertTime = nowTs;
   Alert(msg);
   Print(msg);
}

//+------------------------------------------------------------------+
void UpdateNewsLabel(const bool newsBlocked, const string newsText)
{
   string name = "EA_NEWS_ALERT_LABEL";
   if(!InpDisplayNewsAlerts)
   {
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
      return;
   }

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 160);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, InpNewsHighlightColor);
   ObjectSetString(0, name, OBJPROP_TEXT, (newsBlocked ? "NEWS BLOCK: " : "News: ") + newsText);
}

//+------------------------------------------------------------------+
void GetPositionStats(
   const ENUM_POSITION_TYPE side,
   int &count,
   double &totalLots,
   double &weightedEntry,
   double &floatingProfit,
   double &lastEntryPrice,
   ulong &lastTicket,
   datetime &lastOpenTime
)
{
   count = 0;
   totalLots = 0.0;
   weightedEntry = 0.0;
   floatingProfit = 0.0;
   lastEntryPrice = 0.0;
   lastTicket = 0;
   lastOpenTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
         continue;

      double lots = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime openTs = (datetime)PositionGetInteger(POSITION_TIME);

      count++;
      totalLots += lots;
      weightedEntry += (entry * lots);
      floatingProfit += PositionGetDouble(POSITION_PROFIT);

      if(openTs >= lastOpenTime)
      {
         lastOpenTime = openTs;
         lastEntryPrice = entry;
         lastTicket = ticket;
      }
   }

   if(totalLots > 0.0)
      weightedEntry /= totalLots;
}

//+------------------------------------------------------------------+
bool CloseAllBySide(const ENUM_POSITION_TYPE side)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
         continue;

      if(!trade.PositionClose(ticket))
      {
         ok = false;
         Print("Close failed ticket=", (string)ticket,
               " retcode=", IntegerToString(trade.ResultRetcode()),
               " msg=", trade.ResultRetcodeDescription());
      }
   }
   return ok;
}

//+------------------------------------------------------------------+
bool CloseAllEAOrders()
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
      {
         ok = false;
         Print("Emergency close failed ticket=", (string)ticket,
               " retcode=", IntegerToString(trade.ResultRetcode()),
               " msg=", trade.ResultRetcodeDescription());
      }
   }
   return ok;
}

//+------------------------------------------------------------------+
void RefreshDailyBaseline()
{
   int dayKey = DayKey(TimeTradeServer());
   if(dayKey != gCurrentDayKey)
   {
      gCurrentDayKey = dayKey;
      gSessionStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

//+------------------------------------------------------------------+
bool IsDailyProfitReached()
{
   if(InpDailyProfitMode == DAILY_PROFIT_OFF)
      return false;
   if(gSessionStartEquity <= 0.0)
      return false;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double targetEq = gSessionStartEquity * (1.0 + InpDailyProfitValue / 100.0);
   return (eq >= targetEq);
}

//+------------------------------------------------------------------+
bool IsEquityLossExceeded()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal <= 0.0)
      return false;
   double ddPct = (bal - eq) / bal * 100.0;
   return (ddPct >= InpMaxEquityLossPercent);
}

//+------------------------------------------------------------------+
int TrendDirectionByEMA()
{
   double ema = 0.0;
   if(!GetEMAValue(1, ema))
      return 0;

   double closeRef = iClose(_Symbol, InpTrendTimeframe, 1);
   if(closeRef <= 0.0)
      return 0;
   if(closeRef > ema)
      return 1;
   if(closeRef < ema)
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
bool IsTrendBreakoutSignal(const int trendDirection)
{
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double high2 = iHigh(_Symbol, PERIOD_M1, 2);
   double low2 = iLow(_Symbol, PERIOD_M1, 2);

   if(close1 <= 0.0 || high2 <= 0.0 || low2 <= 0.0)
      return false;

   if(trendDirection > 0)
      return (close1 > high2);
   if(trendDirection < 0)
      return (close1 < low2);
   return false;
}

//+------------------------------------------------------------------+
void ManageTakeProfits()
{
   int buyCount = 0, sellCount = 0;
   double buyLots = 0.0, sellLots = 0.0;
   double buyAvg = 0.0, sellAvg = 0.0;
   double buyPnL = 0.0, sellPnL = 0.0;
   double buyLast = 0.0, sellLast = 0.0;
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyLastTs = 0, sellLastTs = 0;

   GetPositionStats(POSITION_TYPE_BUY, buyCount, buyLots, buyAvg, buyPnL, buyLast, buyTicket, buyLastTs);
   GetPositionStats(POSITION_TYPE_SELL, sellCount, sellLots, sellAvg, sellPnL, sellLast, sellTicket, sellLastTs);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(buyCount > 0 && bid > 0.0)
   {
      double targetPoints = (buyCount <= InpMaxLegsForTP1 ? InpTP1Points : InpTP2Points);
      double tpPrice = buyAvg + targetPoints * _Point;
      if(bid >= tpPrice)
      {
         if(CloseAllBySide(POSITION_TYPE_BUY))
            Print("BUY basket TP hit. Legs=", IntegerToString(buyCount),
                  " targetPts=", DoubleToString(targetPoints, 1),
                  " pnl=", DoubleToString(buyPnL, 2));
      }
   }

   if(sellCount > 0 && ask > 0.0)
   {
      double targetPoints = (sellCount <= InpMaxLegsForTP1 ? InpTP1Points : InpTP2Points);
      double tpPrice = sellAvg - targetPoints * _Point;
      if(ask <= tpPrice)
      {
         if(CloseAllBySide(POSITION_TYPE_SELL))
            Print("SELL basket TP hit. Legs=", IntegerToString(sellCount),
                  " targetPts=", DoubleToString(targetPoints, 1),
                  " pnl=", DoubleToString(sellPnL, 2));
      }
   }
}

//+------------------------------------------------------------------+
void TryOpenInitialEntry(const int trendDirection)
{
   if(trendDirection > 0 && !InpAllowLong)
      return;
   if(trendDirection < 0 && !InpAllowShort)
      return;
   if(!IsTrendBreakoutSignal(trendDirection))
      return;

   double lot = LotForLevel(1);
   if(lot <= 0.0)
      return;

   bool ok = false;
   string reason = "trend+breakout";
   if(trendDirection > 0)
      ok = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "EMA_LONG_L1");
   else if(trendDirection < 0)
      ok = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "EMA_SHORT_L1");

   if(ok)
   {
      gStatus = (trendDirection > 0 ? "Initial BUY opened" : "Initial SELL opened");
      Print(gStatus, " lot=", DoubleToString(lot, 2), " reason=", reason);
   }
   else
   {
      Print("Initial entry failed. retcode=", IntegerToString(trade.ResultRetcode()),
            " msg=", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void TryOpenPyramidEntries(const int trendDirection)
{
   int buyCount = 0, sellCount = 0;
   double buyLots = 0.0, sellLots = 0.0;
   double buyAvg = 0.0, sellAvg = 0.0;
   double buyPnL = 0.0, sellPnL = 0.0;
   double buyLast = 0.0, sellLast = 0.0;
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyLastTs = 0, sellLastTs = 0;

   GetPositionStats(POSITION_TYPE_BUY, buyCount, buyLots, buyAvg, buyPnL, buyLast, buyTicket, buyLastTs);
   GetPositionStats(POSITION_TYPE_SELL, sellCount, sellLots, sellAvg, sellPnL, sellLast, sellTicket, sellLastTs);

   if(trendDirection > 0)
   {
      if(!InpAllowLong || buyCount <= 0 || buyCount >= PYRAMID_LEVELS)
         return;

      int nextLevel = buyCount + 1;
      double distPts = DistancePointsForLevel(nextLevel);
      double trigger = buyLast - (distPts * _Point);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= trigger)
      {
         double lot = LotForLevel(nextLevel);
         bool ok = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "EMA_LONG_L" + IntegerToString(nextLevel));
         if(ok)
         {
            gStatus = "BUY pyramid leg " + IntegerToString(nextLevel) + " opened";
            Print("Trade executed side=BUY level=", IntegerToString(nextLevel),
                  " lot=", DoubleToString(lot, 2),
                  " reason=trend+pyramid dist=", DoubleToString(distPts, 0),
                  " floatingPnL=", DoubleToString(buyPnL, 2));
         }
         else
         {
            Print("BUY pyramid failed level=", IntegerToString(nextLevel),
                  " retcode=", IntegerToString(trade.ResultRetcode()),
                  " msg=", trade.ResultRetcodeDescription());
         }
      }
   }
   else if(trendDirection < 0)
   {
      if(!InpAllowShort || sellCount <= 0 || sellCount >= PYRAMID_LEVELS)
         return;

      int nextLevel = sellCount + 1;
      double distPts = DistancePointsForLevel(nextLevel);
      double trigger = sellLast + (distPts * _Point);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask >= trigger)
      {
         double lot = LotForLevel(nextLevel);
         bool ok = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "EMA_SHORT_L" + IntegerToString(nextLevel));
         if(ok)
         {
            gStatus = "SELL pyramid leg " + IntegerToString(nextLevel) + " opened";
            Print("Trade executed side=SELL level=", IntegerToString(nextLevel),
                  " lot=", DoubleToString(lot, 2),
                  " reason=trend+pyramid dist=", DoubleToString(distPts, 0),
                  " floatingPnL=", DoubleToString(sellPnL, 2));
         }
         else
         {
            Print("SELL pyramid failed level=", IntegerToString(nextLevel),
                  " retcode=", IntegerToString(trade.ResultRetcode()),
                  " msg=", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
void UpdateDashboard(const int trendDirection, const bool newsBlocked, const datetime nearestNewsTs, const string nearestNewsCurrency)
{
   int buyCount = 0, sellCount = 0;
   double buyLots = 0.0, sellLots = 0.0;
   double buyAvg = 0.0, sellAvg = 0.0;
   double buyPnL = 0.0, sellPnL = 0.0;
   double buyLast = 0.0, sellLast = 0.0;
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyLastTs = 0, sellLastTs = 0;

   GetPositionStats(POSITION_TYPE_BUY, buyCount, buyLots, buyAvg, buyPnL, buyLast, buyTicket, buyLastTs);
   GetPositionStats(POSITION_TYPE_SELL, sellCount, sellLots, sellAvg, sellPnL, sellLast, sellTicket, sellLastTs);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = 0.0;
   if(bal > 0.0)
      ddPct = (bal - eq) / bal * 100.0;

   string trendTxt = "Flat";
   if(trendDirection > 0)
      trendTxt = "Bullish";
   else if(trendDirection < 0)
      trendTxt = "Bearish";

   string nextNews = "n/a";
   if(nearestNewsTs > 0)
      nextNews = TimeToString(nearestNewsTs, TIME_DATE | TIME_MINUTES) + " " + nearestNewsCurrency;

   UpdateNewsLabel(newsBlocked, nextNews);

   Comment(
      "XAUUSD M1 EMA Pyramiding EA\n",
      "Status: ", gStatus, "\n",
      "Trend (EMA", IntegerToString(InpEMAPeriod), "): ", trendTxt, "\n",
      "Buy Legs: ", IntegerToString(buyCount), " | Sell Legs: ", IntegerToString(sellCount), "\n",
      "Buy PnL: ", DoubleToString(buyPnL, 2), " | Sell PnL: ", DoubleToString(sellPnL, 2), "\n",
      "Balance: ", DoubleToString(bal, 2), " | Equity: ", DoubleToString(eq, 2), " | DD%: ", DoubleToString(ddPct, 2), "\n",
      "News Blocked: ", (newsBlocked ? "Yes" : "No"), " | Next High News: ", nextNews, "\n",
      "Daily Mode: ", IntegerToString((int)InpDailyProfitMode), " | Daily Value: ", DoubleToString(InpDailyProfitValue, 2)
   );
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   hEMA = iMA(_Symbol, InpTrendTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA == INVALID_HANDLE)
   {
      Print("Initialization failed: EMA handle creation error");
      return INIT_FAILED;
   }

   gSessionStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   gCurrentDayKey = DayKey(TimeTradeServer());
   gTradingHalted = false;
   gStatus = "Initialized";
   Print("EMA pyramiding EA initialized on ", _Symbol, " magic=", IntegerToString(InpMagicNumber));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA != INVALID_HANDLE)
      IndicatorRelease(hEMA);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   RefreshDailyBaseline();

   datetime nearestNewsTs = 0;
   string nearestNewsCurrency = "";
   bool newsBlocked = IsHighImpactNewsBlocked(nearestNewsTs, nearestNewsCurrency);

   if(IsEquityLossExceeded())
   {
      gTradingHalted = true;
      gStatus = "HALTED: Max equity loss reached";
      Print("Equity drawdown alert: max loss ", DoubleToString(InpMaxEquityLossPercent, 2), "% reached. Closing all positions.");
      CloseAllEAOrders();
   }

   if(InpDailyProfitMode != DAILY_PROFIT_OFF && IsDailyProfitReached())
   {
      gStatus = "Daily profit target reached, new entries paused";
   }

   int trendDirection = TrendDirectionByEMA();

   ManageTakeProfits();

   if(!IsNewM1Bar())
   {
      UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
      return;
   }

   if(gTradingHalted)
   {
      UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
      return;
   }

   int buyCount = 0, sellCount = 0;
   double buyLots = 0.0, sellLots = 0.0;
   double buyAvg = 0.0, sellAvg = 0.0;
   double buyPnL = 0.0, sellPnL = 0.0;
   double buyLast = 0.0, sellLast = 0.0;
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyLastTs = 0, sellLastTs = 0;

   GetPositionStats(POSITION_TYPE_BUY, buyCount, buyLots, buyAvg, buyPnL, buyLast, buyTicket, buyLastTs);
   GetPositionStats(POSITION_TYPE_SELL, sellCount, sellLots, sellAvg, sellPnL, sellLast, sellTicket, sellLastTs);

   if(InpOneDirectionAtATime)
   {
      if(buyCount > 0 && trendDirection < 0)
      {
         gStatus = "Trend flipped bearish with BUY basket open";
         UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
         return;
      }
      if(sellCount > 0 && trendDirection > 0)
      {
         gStatus = "Trend flipped bullish with SELL basket open";
         UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
         return;
      }
   }

   if(InpDailyProfitMode != DAILY_PROFIT_OFF && IsDailyProfitReached())
   {
      UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
      return;
   }

   if(newsBlocked)
   {
      gStatus = "Blocked by high-impact news window";
      if(InpDisplayNewsAlerts)
         NewsAlert("News filter active: no trading around high-impact news (" + nearestNewsCurrency + ")");
      UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
      return;
   }

   if(trendDirection == 0)
   {
      gStatus = "No trend: price around EMA";
      UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
      return;
   }

   if(buyCount == 0 && sellCount == 0)
      TryOpenInitialEntry(trendDirection);
   else
      TryOpenPyramidEntries(trendDirection);

   UpdateDashboard(trendDirection, newsBlocked, nearestNewsTs, nearestNewsCurrency);
}
//+------------------------------------------------------------------+

