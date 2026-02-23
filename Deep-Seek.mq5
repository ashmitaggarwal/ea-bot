//+------------------------------------------------------------------+
//|                                                  DeepSeek EA.mq5 |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "DeepSeek EA"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>

CTrade         trade;
CPositionInfo  posinfo;
COrderInfo     ordinfo;

// ============== ENUMS ==============

enum ENUM_RESTRICTION_REASON {
    NO_RESTRICTION,
    TIME_RESTRICTION,
    DAY_RESTRICTION,
    NEWS_RESTRICTION,
    TIME_DAY_RESTRICTION,
    TIME_NEWS_RESTRICTION,
    DAY_NEWS_RESTRICTION,
    ALL_RESTRICTIONS
};

enum ENUM_TIMEFRAME_SELECTION {
    GMT_TIME,        // GMT Time
    BROKER_TIME      // Broker Server Time
};

enum ENUM_SEPARATOR {
    COMMA=0,         // Comma (,)
    SEMICOLON=1      // Semicolon (;)
};

enum ENUM_LOT_SIZE_MODE {
    FIXED_LOTS,                // Fixed Lots
    PCT_ACCOUNT_BALANCE,       // % of Account Balance
    PCT_EQUITY,                // % of Equity
    PCT_FREE_MARGIN,           // % of Free Margin
    FIXED_RISK_PER_TRADE       // Fixed $ Risk per Trade
};

//=================================================

ENUM_RESTRICTION_REASON LastRestrictionReason = NO_RESTRICTION;

input group "Trading Time Settings"
input ENUM_TIMEFRAMES       Timeframe           = PERIOD_M5;     // Timeframe for the EA
input bool                  TradingTime         = false;        // Enable Trading Time Restriction
input ENUM_TIMEFRAME_SELECTION TimeSelection    = BROKER_TIME;  // Time Reference
input int                   TradingStartHour    = 7;            // Start Hour (00-23)
input int                   TradingEndHour      = 21;           // End Hour (00-23)

bool EnableTradingTime = TradingTime;

input group "Lot Size Management"
input ENUM_LOT_SIZE_MODE    LotSizeMode         = FIXED_LOTS;    // Lot Size Calculation
input double                RiskPercentage      = 1.0;           // Risk Percentage (%)
input double                FixedRiskAmount     = 50.0;         // Fixed Risk Amount ($)
input double                FixedLotSize        = 0.01;         // Fixed Lot Size (for Fixed Lots)

input group "other stuff"
input double                Sar_period          = 0.5;          // Sar Period
input int                   Step                = 25;          // Sar Buffer (in Points)
input int                   MinTimeLapse        = 9;           // Minimum Time Lapse
input int                   PriceMvmtThreshold  = 70;           // Price Movement Threshold
input int                   StopActivationPoints = 60;         // Points in Loss when Stoploss is Activated
input int                   StopActivationBuffer = 25;         // StopLoss Activation Buffer
input bool                  UseHardSLOnEntry    = true;        // Always set SL on order (cap loss; stops curve going down)
input int                   HardSLPoints        = 170;         // Hard SL (points) from entry if UseHardSLOnEntry (0 = use same as risk)
input double                ProfitTargetMult   = 1.5;         // Close when profit >= (risk × this). 1.0=breakeven, 1.5=let winners run
input int                   Magic               = 1111111;    // EA Magic Number

int                         StopLoss            = (StopActivationPoints + StopActivationBuffer)*2;

input group "News Filter Settings"
input bool                  NewsFilterOn        = false;       // Enable News Filter
input string                NewsCurrencies      = "USD";       // Affected Currencies (comma separated)
input string                KeyNews             = "NFP,JOLTS,Nonfarm,PMI,Interest Rate"; // High Impact News Keywords
input int                   StopBeforeMin       = 30;          // Minutes Before News to Stop Trading
input int                   StartTradingMin     = 60;          // Minutes After News to Resume Trading
input int                   DaysNewsLookup      = 100;         // Days Ahead to Check News
input ENUM_SEPARATOR        separator           = COMMA;       // List Separator
bool                        TrDisabledNews      = false;
datetime                    LastNewsAvoided     = 0;
string                      TradingEnabledComm  = "";
string                      Newstoavoid[];

input group "Trading Day Settings"
input bool                  EnableDayFilter     = false;       // Enable Day of Week Filter
input bool                  TradeMonday         = true;        // Allow Trading on Monday
input bool                  TradeTuesday        = true;        // Allow Trading on Tuesday
input bool                  TradeWednesday      = true;        // Allow Trading on Wednesday
input bool                  TradeThursday       = true;        // Allow Trading on Thursday
input bool                  TradeFriday         = true;        // Allow Trading on Friday
input bool                  TradeSaturday       = true;        // Allow Trading on Saturday
input bool                  TradeSunday         = true;        // Allow Trading on Sunday

double      Current_Spread;
double      Average_Spread;
int         MinimumProfitLockIn     = 33;
int         Spread_Array_Size       = 100;
double      profit_target_threshold = 0;
int         Time_Difference;
int         Sell_Order_Time;
double      Price_Movement;
int         Max_Concurrent_Orders   = 1;
double      SAR_Buy_Level;
int         Order_Slippage          = 10;
double      SAR_Sell_Level;
string      EA_Comment              = "MrCapFree";
int         Buy_Order_Time;
double      Step_Points;
double      Trailing_Distance_Sell;
double      Trailing_Distance_Buy;
double      StopPoints;
double      Spread_History_Array[];
double      Price_History_Array[];
int         Time_History_Array[];

int         sar_handle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);

   ChartSetInteger(0, CHART_SHOW_GRID, false);

   sar_handle = iSAR(_Symbol, Timeframe, Sar_period, 0.2);
   if(sar_handle == INVALID_HANDLE)
   {
      Print("Failed to create SAR indicator handle");
      return INIT_FAILED;
   }

   //--- Initialize history arrays (avoid use of uninitialized data)
   ArrayResize(Spread_History_Array, Spread_Array_Size);
   ArrayResize(Price_History_Array, Spread_Array_Size);
   ArrayResize(Time_History_Array, Spread_Array_Size);
   double initBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double initAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    initTime = (int)TimeCurrent();
   double initSpread = NormalizeDouble(initAsk - initBid, _Digits);
   ArrayFill(Price_History_Array, 0, Spread_Array_Size, initBid);
   ArrayFill(Time_History_Array, 0, Spread_Array_Size, initTime);
   ArrayFill(Spread_History_Array, 0, Spread_Array_Size, initSpread);
   Average_Spread = initSpread;

   //--- Time validation
   if(TradingTime)
   {
      if(TradingStartHour < 0 || TradingStartHour > 23 || TradingEndHour < 0 || TradingEndHour > 23)
      {
         ShowAlert("?? INVALID HOURS! Must be between 00-23. Trading time disabled.");
         EnableTradingTime = false;
      }
      else if(TradingStartHour == TradingEndHour)
      {
         ShowAlert("?? START HOUR = END HOUR! Trading time disabled.");
         EnableTradingTime = false;
      }
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(sar_handle);
   ObjectDelete(0, "LOT_SIZE_ALERT");
   ObjectDelete(0, "Trading_Hour_Alert");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   int buy_stop_orders_count = 0;
   int sell_stop_orders_count = 0;
   int Order_Count = 0;
   double total_current_profit = 0;
   double lowest_open_price = 1000000;
   double highest_open_price = 0;

   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Current_Spread = NormalizeDouble((Ask - Bid), _Digits);

   //--- Update price/spread history (do not wipe arrays every tick)
   update_price_movement_data(Ask, Bid);

   //--- Loop through pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!ordinfo.SelectByIndex(i)) continue;
      if(ordinfo.Symbol() != _Symbol || ordinfo.Magic() != Magic) continue;

      Order_Count++;
      int CurrTime = (int)TimeCurrent();

      if(ordinfo.OrderType() == ORDER_TYPE_BUY_STOP)
      {
         Time_Difference = CurrTime - Buy_Order_Time;
         if(Time_Difference > MinTimeLapse && (Price_Movement < (_Point * PriceMvmtThreshold)))
            trade.OrderDelete(ordinfo.Ticket());
         buy_stop_orders_count++;
      }
      if(ordinfo.OrderType() == ORDER_TYPE_SELL_STOP)
      {
         Time_Difference = CurrTime - Sell_Order_Time;
         if(Time_Difference > MinTimeLapse && (Price_Movement > (_Point * -PriceMvmtThreshold)))
            trade.OrderDelete(ordinfo.Ticket());
         sell_stop_orders_count++;
      }
   }

   //--- Loop through positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posinfo.SelectByIndex(i)) continue;
      if(posinfo.Symbol() != _Symbol || posinfo.Magic() != Magic) continue;
      Order_Count++;

      if(posinfo.PositionType() == POSITION_TYPE_BUY)
      {
         if(Price_Movement < (_Point * -PriceMvmtThreshold) && (Bid < posinfo.PriceOpen() - (_Point * StopActivationPoints)))
         {
            if(posinfo.StopLoss() == 0)
            {
               StopPoints = (StopActivationBuffer * _Point);
               trade.PositionModify(posinfo.Ticket(), Bid - StopPoints, posinfo.TakeProfit());
            }
         }
      }
      if(posinfo.PositionType() == POSITION_TYPE_SELL)
      {
         if((Price_Movement > (_Point * PriceMvmtThreshold)) && (Ask > ((_Point * StopActivationPoints) + posinfo.PriceOpen())))
         {
            if(posinfo.StopLoss() == 0)
            {
               StopPoints = (StopActivationBuffer * _Point);
               trade.PositionModify(posinfo.Ticket(), Ask + StopPoints, posinfo.TakeProfit());
            }
         }
      }

      total_current_profit += posinfo.Profit() + posinfo.Swap() + posinfo.Commission();
      if(posinfo.PriceOpen() < lowest_open_price)
         lowest_open_price = posinfo.PriceOpen();
      if(posinfo.PriceOpen() > highest_open_price)
         highest_open_price = posinfo.PriceOpen();
   }

   double closeThreshold = profit_target_threshold * MathMax(0.01, ProfitTargetMult);
   if(total_current_profit > closeThreshold)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!posinfo.SelectByIndex(i)) continue;
         if(posinfo.Symbol() != _Symbol || posinfo.Magic() != Magic) continue;
         trade.PositionClose(posinfo.Ticket());
      }
   }

   //------------------------------------------
   // Check Trading Restrictions
   //------------------------------------------
   static bool alertShown = false;
   bool timeOK = !EnableTradingTime || IsWithinTradingHours();
   bool dayOK = !EnableDayFilter || IsTradingDayAllowed();
   bool newsOK = !NewsFilterOn || !IsUpcomingNews();

   ENUM_RESTRICTION_REASON currentReason = NO_RESTRICTION;

   if(!timeOK && !dayOK && !newsOK) currentReason = ALL_RESTRICTIONS;
   else if(!timeOK && !dayOK) currentReason = TIME_DAY_RESTRICTION;
   else if(!timeOK && !newsOK) currentReason = TIME_NEWS_RESTRICTION;
   else if(!dayOK && !newsOK) currentReason = DAY_NEWS_RESTRICTION;
   else if(!timeOK) currentReason = TIME_RESTRICTION;
   else if(!dayOK) currentReason = DAY_RESTRICTION;
   else if(!newsOK) currentReason = NEWS_RESTRICTION;

   if(currentReason != NO_RESTRICTION)
   {
      if(currentReason != LastRestrictionReason || !alertShown)
      {
         string alertMsg = GetRestrictionMessage(currentReason);
         ShowTradingHourAlert(alertMsg);
         alertShown = true;
         LastRestrictionReason = currentReason;
      }
      return;
   }
   else
   {
      if(LastRestrictionReason != NO_RESTRICTION || alertShown)
      {
         ShowTradingHourAlert("");
         alertShown = false;
         LastRestrictionReason = NO_RESTRICTION;
      }
   }

   //--- Check for new entry signals
   if(Order_Count < Max_Concurrent_Orders)
   {
      if((Price_Movement > (_Point * StopActivationPoints)))
      {
         double sar_values[1];
         if(CopyBuffer(sar_handle, 0, 1, 1, sar_values) != 1) return;
         SAR_Buy_Level = (Step * _Point);
         SAR_Buy_Level = (sar_values[0] - SAR_Buy_Level);
         if(SAR_Buy_Level > Ask && (((Step * _Point) + Ask) < lowest_open_price))
         {
            Step_Points = (Step * _Point);
            double entryBuy = NormalizeDouble(Ask + Step_Points, _Digits);
            int slPts = (UseHardSLOnEntry && HardSLPoints > 0) ? HardSLPoints : 0;
            double slBuy = (slPts > 0) ? NormalizeDouble(entryBuy - slPts * _Point, _Digits) : 0;
            double lot = CalculateLotSize();
            if(lot > 0)
               trade.BuyStop(lot, entryBuy, _Symbol, slBuy, 0, ORDER_TIME_GTC, 0, EA_Comment);
            Buy_Order_Time = (int)TimeCurrent();
         }
      }

      if((Price_Movement < (_Point * -StopActivationPoints)))
      {
         double sar_values[1];
         if(CopyBuffer(sar_handle, 0, 1, 1, sar_values) != 1) return;
         SAR_Sell_Level = (Step * _Point);
         SAR_Sell_Level = (sar_values[0] + SAR_Sell_Level);
         if(SAR_Sell_Level < Bid)
         {
            SAR_Sell_Level = (Step * _Point);
            if((Bid - SAR_Sell_Level) > highest_open_price)
            {
               Step_Points = (Step * _Point);
               double entrySell = NormalizeDouble(Bid - Step_Points, _Digits);
               int slPts = (UseHardSLOnEntry && HardSLPoints > 0) ? HardSLPoints : 0;
               double slSell = (slPts > 0) ? NormalizeDouble(entrySell + slPts * _Point, _Digits) : 0;
               double lot = CalculateLotSize();
               if(lot > 0)
                  trade.SellStop(lot, entrySell, _Symbol, slSell, 0, ORDER_TIME_GTC, 0, EA_Comment);
               Sell_Order_Time = (int)TimeCurrent();
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update price movement tracking data                              |
//+------------------------------------------------------------------+
void update_price_movement_data(double Ask, double Bid)
{
   int     currentTimestamp;
   double  currentBidPrice;
   double  historicalBidPrice = 0;
   int     historyIndex;

   //--- Shift spread array left and add new at end
   for(int i = 0; i < Spread_Array_Size - 1; i++)
      Spread_History_Array[i] = Spread_History_Array[i + 1];
   Spread_History_Array[Spread_Array_Size - 1] = NormalizeDouble(Ask - Bid, _Digits);

   double sum = 0.0;
   for(int i = 0; i < Spread_Array_Size; i++)
      sum += Spread_History_Array[i];
   Average_Spread = sum / Spread_Array_Size;

   //--- Shift price and time arrays
   double tempPriceArray[];
   double tempTimeArray[];
   ArrayResize(tempPriceArray, Spread_Array_Size - 1);
   ArrayResize(tempTimeArray, Spread_Array_Size - 1);
   ArrayCopy(tempPriceArray, Price_History_Array, 0, 1, Spread_Array_Size - 1);
   ArrayCopy(tempTimeArray, Time_History_Array, 0, 1, Spread_Array_Size - 1);
   ArrayResize(tempPriceArray, Spread_Array_Size);
   ArrayResize(tempTimeArray, Spread_Array_Size);
   tempPriceArray[Spread_Array_Size - 1] = Bid;
   tempTimeArray[Spread_Array_Size - 1] = (int)TimeCurrent();
   ArrayCopy(Price_History_Array, tempPriceArray);
   ArrayCopy(Time_History_Array, tempTimeArray);

   currentTimestamp = (int)Time_History_Array[Spread_Array_Size - 1];
   currentBidPrice  = Price_History_Array[Spread_Array_Size - 1];

   for(historyIndex = Spread_Array_Size - 1; historyIndex >= 0; historyIndex--)
   {
      int secondsElapsed = currentTimestamp - Time_History_Array[historyIndex];
      if(secondsElapsed > MinTimeLapse)
      {
         historicalBidPrice = Price_History_Array[historyIndex];
         break;
      }
   }

   Price_Movement = currentBidPrice - historicalBidPrice;

   if(Price_Movement / _Point > 1000)
      Price_Movement = 0;

   ArrayFree(tempPriceArray);
   ArrayFree(tempTimeArray);
}

//+------------------------------------------------------------------+
//| Calculate Lot Size (risk = StopLoss in points; correct $ formula) |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double lotSize = FixedLotSize;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;

   //--- Risk per 1 lot = (StopLoss in price) * (tickValue/tickSize) = (StopLoss*_Point/tickSize)*tickValue
   double riskPerLot = 0;
   if(StopLoss > 0 && tickSize > 0 && tickValue > 0)
      riskPerLot = (StopLoss * _Point / tickSize) * tickValue;

   if(StopLoss <= 0)
   {
      ShowAlert("?? INVALID STOPLOSS! Using fixed lots");
      profit_target_threshold = 0;
      return MathMax(minLot, MathMin(maxLot, NormalizeDouble(FixedLotSize, 2)));
   }

   if(tickValue <= 0 || tickSize <= 0)
   {
      ShowAlert("?? BROKER DATA ERROR! Using fixed lots");
      profit_target_threshold = 0;
      return MathMax(minLot, MathMin(maxLot, NormalizeDouble(FixedLotSize, 2)));
   }

   switch(LotSizeMode)
   {
      case FIXED_LOTS:
         lotSize = FixedLotSize;
         break;

      case PCT_ACCOUNT_BALANCE:
         if(riskPerLot > 0)
            lotSize = (AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercentage / 100.0) / riskPerLot;
         break;

      case PCT_EQUITY:
         if(riskPerLot > 0)
            lotSize = (AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercentage / 100.0) / riskPerLot;
         break;

      case PCT_FREE_MARGIN:
         if(riskPerLot > 0)
            lotSize = (AccountInfoDouble(ACCOUNT_MARGIN_FREE) * RiskPercentage / 100.0) / riskPerLot;
         break;

      case FIXED_RISK_PER_TRADE:
         if(riskPerLot > 0)
            lotSize = FixedRiskAmount / riskPerLot;
         break;
   }

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   lotSize = NormalizeDouble(lotSize, 2);

   //--- Margin check
   double marginRequired;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize, ask, marginRequired))
   {
      ShowAlert("?? MARGIN CALCULATION FAILED! Using min lot");
      lotSize = minLot;
   }
   else if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      while(lotSize > minLot)
      {
         lotSize = MathMax(minLot, lotSize - lotStep);
         if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize, ask, marginRequired) &&
            marginRequired <= AccountInfoDouble(ACCOUNT_MARGIN_FREE))
            break;
      }
      lotSize = NormalizeDouble(lotSize, 2);
   }

   profit_target_threshold = lotSize * riskPerLot;

   return lotSize;
}

//+------------------------------------------------------------------+
//| ShowAlert (no Sleep to avoid blocking EA)                         |
//+------------------------------------------------------------------+
void ShowAlert(string message)
{
   ObjectDelete(0, "LOT_SIZE_ALERT");
   if(message == "") return;

   if(!ObjectCreate(0, "LOT_SIZE_ALERT", OBJ_LABEL, 0, 0, 0))
   {
      Print("Failed to create alert object! Error: ", GetLastError());
      return;
   }

   ObjectSetString(0, "LOT_SIZE_ALERT", OBJPROP_TEXT, "• " + message + " •");
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_FONTSIZE, 12);
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_COLOR, (StringFind(message, "??", 0) >= 0) ? clrRed : clrGold);
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_BGCOLOR, clrNavy);
   ObjectSetString(0, "LOT_SIZE_ALERT", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_YDISTANCE, 25);
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "LOT_SIZE_ALERT", OBJPROP_BACK, false);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Show Trading Hour Alert (no Sleep)                                |
//+------------------------------------------------------------------+
void ShowTradingHourAlert(string message)
{
   ObjectDelete(0, "Trading_Hour_Alert");
   if(message == "") return;

   if(!ObjectCreate(0, "Trading_Hour_Alert", OBJ_LABEL, 0, 0, 0))
   {
      Print("Failed to create alert object! Error: ", GetLastError());
      return;
   }

   ObjectSetString(0, "Trading_Hour_Alert", OBJPROP_TEXT, "• " + message + " •");
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_FONTSIZE, 14);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_COLOR, (StringFind(message, "??", 0) >= 0) ? clrRed : clrGold);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_BGCOLOR, clrNavy);
   ObjectSetString(0, "Trading_Hour_Alert", OBJPROP_FONT, "Arial Black");
   int xPos = (int)(ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) / 2);
   int yPos = (int)(ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS) / 2);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_XDISTANCE, xPos);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_YDISTANCE, yPos);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "Trading_Hour_Alert", OBJPROP_BACK, false);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Check if within trading hours                                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!EnableTradingTime) return true;

   datetime currentTime = (TimeSelection == GMT_TIME) ? TimeGMT() : TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);

   if(TradingStartHour > TradingEndHour)
      return (timeStruct.hour >= TradingStartHour) || (timeStruct.hour < TradingEndHour);
   return (timeStruct.hour >= TradingStartHour) && (timeStruct.hour < TradingEndHour);
}

//+------------------------------------------------------------------+
//| Check if trading day is allowed                                   |
//+------------------------------------------------------------------+
bool IsTradingDayAllowed()
{
   if(!EnableDayFilter) return true;

   datetime currentTime = (TimeSelection == GMT_TIME) ? TimeGMT() : TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);

   switch(timeStruct.day_of_week)
   {
      case 0: return TradeSunday;
      case 1: return TradeMonday;
      case 2: return TradeTuesday;
      case 3: return TradeWednesday;
      case 4: return TradeThursday;
      case 5: return TradeFriday;
      case 6: return TradeSaturday;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if upcoming news (only future news)                          |
//+------------------------------------------------------------------+
bool IsUpcomingNews()
{
   if(!NewsFilterOn) return false;

   if(TrDisabledNews && TimeCurrent() - LastNewsAvoided < StartTradingMin * 60)
   {
      TradingEnabledComm = "Waiting " + IntegerToString(StartTradingMin) + "min after news before trading";
      return true;
   }

   TrDisabledNews = false;
   string sep = (separator == COMMA) ? "," : ";";
   ushort sep_code = StringGetCharacter(sep, 0);

   int k = StringSplit(KeyNews, sep_code, Newstoavoid);
   if(k <= 0) return false;

   MqlCalendarValue values[];
   datetime starttime = TimeCurrent();
   datetime endtime   = starttime + 86400 * DaysNewsLookup;

   if(!CalendarValueHistory(values, starttime, endtime)) return false;

   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;

      if(StringFind(NewsCurrencies, country.currency) < 0) continue;

      for(int j = 0; j < k; j++)
      {
         if(StringFind(event.name, Newstoavoid[j]) >= 0)
         {
            datetime newsTime = values[i].time;
            int secondsBefore = StopBeforeMin * 60;
            // Only avoid future news, not past
            if(newsTime > TimeCurrent() && (newsTime - TimeCurrent()) < secondsBefore)
            {
               LastNewsAvoided = newsTime;
               TrDisabledNews = true;
               TradingEnabledComm = "Trading disabled: " + country.currency + " " + event.name + " at " + TimeToString(newsTime, TIME_MINUTES);
               return true;
            }
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Get Restriction Message                                           |
//+------------------------------------------------------------------+
string GetRestrictionMessage(ENUM_RESTRICTION_REASON reason)
{
   switch(reason)
   {
      case TIME_RESTRICTION:       return "Outside Trading Hours - EA Paused";
      case DAY_RESTRICTION:        return "Trading Day Restricted - EA Paused";
      case NEWS_RESTRICTION:       return TradingEnabledComm;
      case TIME_DAY_RESTRICTION:   return "Outside Hours & Day Restricted - EA Paused";
      case TIME_NEWS_RESTRICTION:  return "Outside Hours & News Event - EA Paused";
      case DAY_NEWS_RESTRICTION:   return "Day Restricted & News Event - EA Paused";
      case ALL_RESTRICTIONS:       return "Outside Hours, Day Restricted & News - EA Paused";
   }
   return "";
}
