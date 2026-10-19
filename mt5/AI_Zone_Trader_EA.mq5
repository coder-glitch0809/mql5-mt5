// AI Zone Trader: everything runs inside MetaTrader 5.
// One chart scans every timeframe in ScanTimeframes (M5..D1): rule-based signals
// -> all classic checks + higher-timeframe alignment -> Claude review (it learns from
// its own record) -> only verified signals go to Telegram -> optional order with SL and 3-part TP.
#property strict
#property version "5.20"
#property description "One chart scans every Market Watch symbol on M1..W1: 11 strategy families + Claude review before Telegram. Market + limit entries, TP1 profit locked."
#include <Trade/Trade.mqh>

enum AZTTradeMode {
   AZT_SIGNALS_ONLY=0,   // Faqat signal: savdo ochilmaydi
   AZT_CONFIRM_EVERY=1,  // Har savdo Telegram tugmasi bilan tasdiqlanadi
   AZT_AI_HYBRID=2       // Claude tasdiqlasa o'zi kiradi, aks holda sizdan so'raydi
};

enum AZTEntryMode {
   AZT_ENTRY_MARKET=0,   // Faqat bozor narxida
   AZT_ENTRY_LIMIT=1,    // Faqat BUY LIMIT / SELL LIMIT (zonada kutadi)
   AZT_ENTRY_BOTH=2      // Bozor narxida + zonada limit order
};

input group "1. Savdo rejimi"
input AZTTradeMode TradeMode = AZT_SIGNALS_ONLY; // Standart: faqat tekshirilgan signal Telegram'ga, savdo yo'q
input int ApprovalTimeoutMinutes = 15;  // Javob bo'lmasa signal bekor
input bool SkipWhenAIRejects = true;    // AI rad etsa: savdo ham, tugma ham yo'q

input AZTEntryMode EntryMode = AZT_ENTRY_BOTH; // Savdo ochilganda: bozor, limit yoki ikkalasi
input double LimitOffsetATR = 0.3;      // Limit narx: zona chegarasi, kamida shuncha ATR bozor narxidan uzoqda
input int LimitExpiryBars = 12;         // Limit order shuncha sham ichida ochilmasa bekor qilinadi

input group "2. Risk (kichik hisob uchun ham)"
input double MaxRiskPercent = 1.0;       // Har savdoda balansdan risk, %
input double MinLotMaxRiskPercent = 3.0; // Kichik hisob: min lot riski shu %gacha bo'lsa min lot bilan kiradi
input double MaxDailyLossPercent = 3.0;
input double MaxDrawdownPercent = 10.0;
input int MaxConsecutiveLosses = 3;
input int MaxOpenPositions = 10;         // Hisob bo'yicha ochiq pozitsiyalar
input int MaxPendingOrders = 10;         // Shu EA'ning kutilayotgan limit orderlari
input double MaxSpreadPoints = 0;        // Broker point birligida (0 = o'chiq; spread SL ga nisbatan tekshiriladi)
input double MaxEntryDriftATR = 0.5;     // Narx signaldan shuncha ATR qochsa kirmaydi
input int SlippagePoints = 30;
input ulong MagicNumber = 260916;

input group "3. Stop loss va 3 qismli take profit"
input double StopATR = 1.5;              // SL kamida shuncha ATR
input double SLBufferATR = 0.5;          // SL swing/zona chegarasidan shuncha ATR nari (eski 0.2: wick bilan tez urilardi)
input int SwingLookback = 10;            // SL oxirgi swing ortiga qo'yiladi
input double TP1_R = 1.5;                // TP1 = asosiy TP yo'lining 50%i
input double TP1ClosePercent = 50;       // TP1 da yopiladigan qism, %
input double TP2_R = 2.25;               // TP2 = yo'lning 75%i
input double TP2ClosePercent = 25;       // TP2 da yopiladigan qism, %
input double TP3_R = 3.0;                // Asosiy TP = risk x3 (brokerga qo'yiladi)
input bool MoveSLAfterTP = true;         // TP1 dan keyin SL -> Entry, TP2 dan keyin SL -> TP1
input bool UsePartialTP = true;          // true: TP1 da 50% foyda olinadi, qolgani zararsiz; false: butun lot TP3 gacha
input double BreakevenLockR = 0.1;       // TP1 dan keyin SL = Entry + shuncha R (spread/komissiya TP1 foydasini yemaydi)

input group "4. Signal qoidalari"
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int FastEMA = 21;
input int SlowEMA = 55;
input int RSIPeriod = 14;
input int ATRPeriod = 14;
input bool EnableCrossSignals = true;
input bool EnablePullbackSignals = true;
input double RSIBuyMin = 50.0;
input double RSIBuyMax = 65.0;           // Haddan oshgan bozorda BUY yo'q
input double RSISellMin = 35.0;          // Haddan tushgan bozorda SELL yo'q
input double RSISellMax = 50.0;
input int CooldownBars = 3;
input int MaxSignalDelaySeconds = 180;   // Kechikkan sham signal bermaydi
input bool EnableStructureBreakSignals = true;
input bool EnableOrderBlockSignals = true;
input bool EnableTrendlineSignals = true;
input double TrendlineToleranceATR = 0.25;
input int StructureLookback = 500;
input int PivotBars = 3;                 // Left AND right confirmation candles
input int OBSearchBars = 20;
input double OBImpulseATR = 0.8;         // Breakout candle body / ATR
input int MaxOrderBlocks = 8;
input int OBMaxAgeBars = 200;

input group "4b. Qo'shimcha indikatorlar (konfluens)"
input int MinConfluence = 2;             // Signal uchun kamida shuncha qo'shimcha tasdiq (minus qarshi)
input bool BlockIfLevelBeforeTP1 = true; // Kuchli qarshi daraja TP1 dan oldin bo'lsa signal yo'q
input bool UseMACD = true;
input int MACDFast = 12;
input int MACDSlow = 26;
input int MACDSignalPeriod = 9;
input bool UseTrendMA = true;
input int TrendMAPeriod = 200;           // Uzoq muddatli moving average (SMA)
input bool UseFVG = true;                // Fair Value Gap
input int FVGLookback = 50;
input double FVGMinATR = 0.15;
input bool UseSNR = true;                // Support/Resistance: tarixda qayta-qayta tegilgan darajalar
input int SNRLookback = 300;
input double SNRZoneATR = 0.3;
input int SNRMinTouches = 2;
input bool UseFibonacci = true;          // 50-78.6% qaytish zonasi
input bool UsePatterns = true;           // Engulfing, pin bar, double top/bottom

input group "4c. Barcha timeframe'lar va qat'iy tekshiruv"
input string ScanTimeframes = "M1,M5,M15,M30,H1,H4,D1,W1"; // Har symbolda shu TF'lar skanerlanadi (bo'sh = faqat SignalTimeframe)
input string ScanSymbols = "";           // Bo'sh = Market Watch'dagi barcha symbollar; yoki "EURUSD,XAUUSD,BTCUSD,US30"
input int MaxSymbols = 12;               // Ko'pi bilan shuncha symbol (har biri x TF soni indikator yuklaydi)
input int MinAccuracyPercent = 50;       // Shu symbol/TF tarixida TP1 ga yetganlar shundan kam bo'lsa signal yo'q (0 = o'chiq)
input int HistoryRefreshBars = 20;       // Tarixiy statistika har shuncha yangi shamda qayta hisoblanadi
input bool MTFFilter = true;             // Yuqori TF trendi signalga qarshi bo'lsa signal yo'q
input int MTFMinAgreePercent = 67;       // Yuqori TF'larning kamida shuncha %i signal yo'nalishida bo'lsin
input bool RequireAllChecks = true;      // Konfluensda bitta ham qarshi (⚠️) omil bo'lmasin
input bool RequireAIApproval = true;     // Faqat Claude APPROVE bergan signal Telegram'ga yuboriladi
input int MinAIConfidence = 70;          // Claude ishonchi shundan past bo'lsa signal yuborilmaydi
input int HeartbeatHours = 6;            // Telegram'ga "EA ishlayapti" hisoboti har N soatda (0 = o'chiq)

input group "4d. Strategiya oilalari (SNR, SMC/ICT, pattern, sham, PA, indikator, hajm, sessiya, kvant, skalp, snayper)"
input int MinFamilies = 5;               // Kamida shuncha strategiya oilasi tasdiqlasin (11 tadan)
input bool UseSMCExtras = true;          // Likvidlik sweep, premium/discount zonasi
input int SweepBars = 3;
input int PDRangeBars = 50;
input bool UseChartPatterns = true;      // Konsolidatsiya (flag/rectangle) breakout
input int RangeBars = 10;
input double RangeMaxATR = 2.0;
input bool UseCandlesExtra = true;       // Morning/evening star, inside bar, three soldiers/crows
input bool UsePriceAction = true;        // HH/HL yoki LH/LL tuzilmasi
input bool UseStochastic = true;
input int StochK = 14;
input int StochD = 3;
input int StochSlowing = 3;
input bool UseADX = true;
input int ADXPeriod = 14;
input double MinADX = 20;                // Shundan past ADX: trend kuchsiz
input bool UseVolume = true;             // Tick volume o'sishi
input int VolumeAvgBars = 20;
input double VolumeSpike = 1.5;
input bool UseSessionFilter = true;      // M5/M15 signal faqat London/New York sessiyasida
input int SessionStartGMT = 7;
input int SessionEndGMT = 20;
input bool UseVolatilityFilter = true;   // ATR haddan tashqari yuqori/past bo'lsa signal yo'q
input int VolatilityBars = 100;
input double MaxSpreadRiskPercent = 10;  // Spread SL masofasining shu %idan oshsa signal yo'q
input double SniperMaxZoneATR = 1.0;     // Narx kirish zonasidan shuncha ATR uzoqlashgan bo'lsa quvib kirilmaydi
input int MinHistorySamples = 20;        // Shu timeframe tarixida kamida shuncha natija bo'lsa...
input double MinHistoryExpectancyR = 0.0; // ...o'rtacha natija shundan past bo'lsa jonli signal yo'q

input group "5. AI uchun kontekst"
input ENUM_TIMEFRAMES AIHigherTF1 = PERIOD_H4;
input ENUM_TIMEFRAMES AIHigherTF2 = PERIOD_D1;
input int AICandles = 40;                // AI ga yuboriladigan yopilgan shamlar

input group "6. Grafik, ogohlantirish, tarix"
input bool PopupAlerts = true;
input bool PushNotifications = false;    // MT5 Notifications sozlangan bo'lsa
input bool DrawLevels = true;
input bool DrawTrendlines = true;
input bool DrawOrderBlocks = true;
input bool DrawStructureBreaks = true;
input int StructureExtendBars = 20;
input int HistoryBars = 1000;            // Closed-bar replay; no historical orders/alerts
input int HistoryMaxHoldingBars = 100;
input double HistoryRoundTripCostPoints = 0; // Zero = gross illustrative results

CTrade Trade;
int FastHandle=INVALID_HANDLE, SlowHandle=INVALID_HANDLE;
int RSIHandle=INVALID_HANDLE, ATRHandle=INVALID_HANDLE;
int MACDHandle=INVALID_HANDLE, TrendMAHandle=INVALID_HANDLE;
int StochHandle=INVALID_HANDLE, ADXHandle=INVALID_HANDLE;
ENUM_TIMEFRAMES TF;
MqlRates Rates[];
double Fast[], Slow[], RSI[], ATR[], MACDMain[], MACDSignal[], TrendMA[];
double StochMain[], StochSignal[], ADXMain[], ADXPlus[], ADXMinus[];
datetime LastClosedBar=0, LastSignalBar=0;
bool Ready=false;
string Prefix, PosScope, Status="Starting", LastSignal="none", TradeStatus="", AITestStatus="";
int HistoricalSignals=0;

// ---- Multi-symbol, multi-timeframe state -------------------------------------
// One "slot" = one symbol x one timeframe: slot = SymIndex*TFCount + k (k = TFList index).
// Every slot has its own indicator handles and scan state. SwitchSlot() loads one slot
// into the globals that the rest of the EA (structure, confluence, journal) reads.
#define AZT_MAX_TF 9
#define AZT_MAX_SYMBOLS 30
#define AZT_MAX_SLOTS 270
int TFCount=0, TFIndex=-1, CurSlot=-1, JournalSlot=-1;
int SymCount=0, SymIndex=-1;
string SymList[AZT_MAX_SYMBOLS];
ENUM_TIMEFRAMES TFList[AZT_MAX_TF];
int TFFast[AZT_MAX_SLOTS], TFSlow[AZT_MAX_SLOTS], TFRSI[AZT_MAX_SLOTS], TFATR[AZT_MAX_SLOTS], TFMACD[AZT_MAX_SLOTS], TFTrendMA[AZT_MAX_SLOTS];
int TFStoch[AZT_MAX_SLOTS], TFADX[AZT_MAX_SLOTS];
datetime TFLastClosed[AZT_MAX_SLOTS], TFLastSignal[AZT_MAX_SLOTS];
bool TFReady[AZT_MAX_SLOTS];
string TFStatus[AZT_MAX_SLOTS], TFHistory[AZT_MAX_SLOTS];
int TFHistSignals[AZT_MAX_SLOTS], SlotHistTrades[AZT_MAX_SLOTS], SlotHistTP1[AZT_MAX_SLOTS], SlotHistAge[AZT_MAX_SLOTS];
double SlotHistExp[AZT_MAX_SLOTS];
int HTFHandles[AZT_MAX_SYMBOLS][4];    // AI context: EMA fast/slow on AIHigherTF1 and AIHigherTF2 per symbol
bool DrawEnabled=true;                 // Only the chart's own symbol and timeframe draw objects

// Slot of timeframe k for the current symbol (-1 before a symbol is selected, e.g. in unit tests).
int Slot(int k) { return SymIndex<0 || k<0 || k>=TFCount ? -1 : SymIndex*TFCount+k; }
int SetupCount=0, SentCount=0, FilteredCount=0; // Since the last heartbeat
datetime NextHeartbeat=0, NextAIWarning=0, StartedAt=0;

string TFName(ENUM_TIMEFRAMES tf) { return StringSubstr(EnumToString(tf),7); }

#include "AZT_Structure.mqh"
#include "AZT_Telegram.mqh"
#include "AZT_AI.mqh"

struct LocalSignal {
   int side; // 1 = BUY, -1 = SELL
   datetime time;
   double entry, sl, tp1, tp2, tp3, atr;
   double zoneTop, zoneBottom; // Kirish zonasi: narx shu oraliqda bo'lganda kiriladi
   string setup;
   int score;      // Confluence: agreeing minus opposing classic factors
   int against;    // Number of opposing (⚠️) factors
   string factors; // One line per factor, for Telegram and the AI
   string mtf;     // Higher-timeframe trend line
   int families;   // Strategy families that confirmed the signal
   double limit, ltp1, ltp2, ltp3; // BUY/SELL LIMIT at the zone (0 = none); targets from the limit price
   double histRate; int histSamples; // TP1 hit rate (%) of these rules on this symbol/TF, -1 unknown
};

struct PendingApproval {
   bool active;
   string id;
   LocalSignal signal;
   int tf;           // Slot (symbol x timeframe) of the signal
   datetime expires; // TimeLocal
};
PendingApproval Pending;

// Bars the indicators need; structure uses whatever history exists beyond this (W1/D1 may be short).
int IndicatorBars() {
   int indicators=MathMax(MathMax(SlowEMA*3,MACDSlow*3),MathMax(RSIPeriod,ATRPeriod)*3)+SwingLookback+3;
   indicators=MathMax(indicators,TrendMAPeriod+FVGLookback+3);
   indicators=MathMax(indicators,MathMax(MathMax(VolatilityBars,PDRangeBars),ADXPeriod*3)+ATRPeriod+3);
   return indicators;
}

int RequiredBars() { return MathMax(IndicatorBars(),StructureLookback+2*PivotBars+3); }

double TickPrice(double price, int direction=0) {
   double step=SymbolInfoDouble(Sym,SYMBOL_TRADE_TICK_SIZE);
   if(step<=0) step=SymPoint;
   double units=price/step;
   double rounded=(direction<0 ? MathFloor(units) : direction>0 ? MathCeil(units) : MathRound(units));
   return NormalizeDouble(rounded*step,SymDigits);
}

string Price(double value) { return DoubleToString(value,SymDigits); }

#include "AZT_Confluence.mqh"
#include "AZT_Strategies.mqh"

bool LoadData(int count) {
   // Series arrays: 0 = forming candle, 1 = last CLOSED candle.
   if(BarsCalculated(FastHandle)<count || BarsCalculated(SlowHandle)<count ||
      BarsCalculated(RSIHandle)<count || BarsCalculated(ATRHandle)<count ||
      BarsCalculated(MACDHandle)<count || BarsCalculated(TrendMAHandle)<count ||
      BarsCalculated(StochHandle)<count || BarsCalculated(ADXHandle)<count) return false;
   bool loaded=CopyRates(Sym,TF,0,count,Rates)==count &&
          CopyBuffer(FastHandle,0,0,count,Fast)==count &&
          CopyBuffer(SlowHandle,0,0,count,Slow)==count &&
          CopyBuffer(RSIHandle,0,0,count,RSI)==count &&
          CopyBuffer(ATRHandle,0,0,count,ATR)==count &&
          CopyBuffer(MACDHandle,0,0,count,MACDMain)==count &&
          CopyBuffer(MACDHandle,1,0,count,MACDSignal)==count &&
          CopyBuffer(TrendMAHandle,0,0,count,TrendMA)==count &&
          CopyBuffer(StochHandle,0,0,count,StochMain)==count &&
          CopyBuffer(StochHandle,1,0,count,StochSignal)==count &&
          CopyBuffer(ADXHandle,0,0,count,ADXMain)==count &&
          CopyBuffer(ADXHandle,1,0,count,ADXPlus)==count &&
          CopyBuffer(ADXHandle,2,0,count,ADXMinus)==count;
   if(loaded) InvalidateStructureCache();
   return loaded;
}

bool EvaluateSignal(int shift, LocalSignal &signal, string &reason) {
   if(shift<1 || shift+MathMax(SwingLookback,1)>=ArraySize(Rates) ||
      shift+1>=ArraySize(Fast) || shift+1>=ArraySize(Slow) ||
      shift>=ArraySize(RSI) || shift>=ArraySize(ATR)) { reason="Waiting for history"; return false; }
   if(ATR[shift]<=0 || ATR[shift]==EMPTY_VALUE || Fast[shift]==EMPTY_VALUE ||
      Slow[shift]==EMPTY_VALUE || RSI[shift]==EMPTY_VALUE ||
      Fast[shift+1]==EMPTY_VALUE || Slow[shift+1]==EMPTY_VALUE ||
      !MathIsValidNumber(ATR[shift]) || !MathIsValidNumber(Fast[shift]) ||
      !MathIsValidNumber(Slow[shift]) || !MathIsValidNumber(RSI[shift])) { reason="Indicators warming up"; return false; }
   bool up=Fast[shift]>Slow[shift] && Rates[shift].close>Fast[shift];
   bool down=Fast[shift]<Slow[shift] && Rates[shift].close<Fast[shift];
   int side=up ? 1 : down ? -1 : 0;
   if(side==0) { reason="Waiting: price and EMA trend disagree"; return false; }
   double momentum=RSI[shift];
   if((side==1 && !(momentum>RSIBuyMin && momentum<RSIBuyMax)) ||
      (side==-1 && !(momentum>RSISellMin && momentum<RSISellMax))) {
      reason="Waiting: RSI filter ("+DoubleToString(momentum,1)+")"; return false;
   }
   bool cross=side==1 ? Fast[shift+1]<=Slow[shift+1] : Fast[shift+1]>=Slow[shift+1];
   bool pullback=side==1 ? (Rates[shift].low<=Fast[shift] && Rates[shift].close>Rates[shift].open)
                        : (Rates[shift].high>=Fast[shift] && Rates[shift].close<Rates[shift].open);
   int structureSide=0;
   string structureSetup, structureReason;
   double structureStop=0;
   bool structure=EvaluateStructureSignal(shift,structureSide,structureSetup,structureStop,structureReason);
   structure=structure && structureSide==side;
   if(!structure && !(EnableCrossSignals && cross) && !(EnablePullbackSignals && pullback)) {
      reason="Waiting: OB rejection, BOS, trendline or EMA setup"; return false;
   }
   signal.side=side; signal.time=Rates[shift].time; signal.atr=ATR[shift];
   signal.setup=structure ? structureSetup : (EnableCrossSignals && cross) ? "EMA cross" : "EMA pullback";
   signal.entry=TickPrice(Rates[shift].close);
   // Entry zone: the structure zone (OB, broken level, trendline), else the EMA21 band.
   signal.zoneTop=Fast[shift]+0.25*signal.atr; signal.zoneBottom=Fast[shift]-0.25*signal.atr;
   if(structure) { signal.zoneTop=StructureSignals[shift].zoneTop; signal.zoneBottom=StructureSignals[shift].zoneBottom; }
   double extreme=(side==1 ? Rates[shift].low : Rates[shift].high);
   for(int i=shift+1;i<shift+SwingLookback;i++)
      extreme=side==1 ? MathMin(extreme,Rates[i].low) : MathMax(extreme,Rates[i].high);
   if(structure && structureStop>0)
      extreme=side==1 ? MathMin(extreme,structureStop) : MathMax(extreme,structureStop);
   double distance=MathMax(StopATR*signal.atr,MathAbs(signal.entry-extreme)+SLBufferATR*signal.atr);
   signal.sl=TickPrice(signal.entry-side*distance,-side);
   distance=MathAbs(signal.entry-signal.sl);
   signal.tp1=TickPrice(signal.entry+side*distance*TP1_R,side);
   signal.tp2=TickPrice(signal.entry+side*distance*TP2_R,side);
   signal.tp3=TickPrice(signal.entry+side*distance*TP3_R,side);
   if(signal.sl<=0 || signal.tp3<=0 || distance<=0) { reason="Invalid price levels"; return false; }
   string blocker;
   bool clear=EvaluateConfluence(shift,side,signal.entry,signal.sl,signal.score,signal.factors,blocker);
   signal.mtf=""; signal.families=0;
   if(!clear) { signal.against=ConfluenceAgainst; reason="Skipped "+signal.setup+": "+blocker; return false; }
   EvaluateStrategies(shift,side,signal.entry,signal.score,signal.factors);
   // The setup itself belongs to a family: SMC (OB/BOS/CHOCH), price action (trendline) or indicators (EMA).
   int setupFamily=!structure ? AZT_F_IND : StringFind(signal.setup,"trendline")>=0 ? AZT_F_PA : AZT_F_SMC;
   FamilyFor[setupFamily]++;
   signal.against=ConfluenceAgainst;
   // Sniper limit: wait at the zone edge (at least LimitOffsetATR better than market); targets from that price.
   signal.limit=0; signal.ltp1=0; signal.ltp2=0; signal.ltp3=0; signal.histRate=-1; signal.histSamples=0;
   double wanted=signal.entry-side*LimitOffsetATR*signal.atr;
   if(signal.zoneTop>0 && signal.zoneBottom>0)
      wanted=side==1 ? MathMin(signal.zoneTop,wanted) : MathMax(signal.zoneBottom,wanted);
   wanted=TickPrice(wanted,-side);
   double limitRisk=side*(wanted-signal.sl);
   if(limitRisk>=0.5*signal.atr) {
      signal.limit=wanted;
      signal.ltp1=TickPrice(wanted+side*limitRisk*TP1_R,side);
      signal.ltp2=TickPrice(wanted+side*limitRisk*TP2_R,side);
      signal.ltp3=TickPrice(wanted+side*limitRisk*TP3_R,side);
   }
   if(signal.score<MinConfluence) {
      reason="Skipped "+signal.setup+": confluence "+(string)signal.score+" < "+(string)MinConfluence; return false;
   }
   reason=signal.setup;
   return true;
}

bool CoolingDown(int shift) {
   if(LastSignalBar==0 || CooldownBars==0) return false;
   int previous=iBarShift(Sym,TF,LastSignalBar,true);
   return previous>=shift && previous-shift<CooldownBars;
}

// ---- Multi-timeframe alignment ----------------------------------------------
// Trend (1 UP, -1 DOWN, 0 MIXED) of TFList[k] on its last bar that was CLOSED at `at`.
// Causal: a higher-timeframe bar still forming at `at` is never used. word="n/a" if no data.
int TFTrendAt(int k, datetime at, string &word) {
   word="n/a";
   int slot=Slot(k);
   if(slot<0 || TFFast[slot]==INVALID_HANDLE || TFSlow[slot]==INVALID_HANDLE) return 0;
   ENUM_TIMEFRAMES tf=TFList[k];
   int shift=iBarShift(Sym,tf,at-1,false);
   if(shift<0) return 0;
   for(int guard=0;guard<3;guard++) {
      datetime opened=iTime(Sym,tf,shift);
      if(opened<=0) return 0;
      if(opened+PeriodSeconds(tf)<=at) break;
      shift++;
   }
   double fast[1], slow[1];
   MqlRates bar[1];
   if(CopyBuffer(TFFast[slot],0,shift,1,fast)!=1 || CopyBuffer(TFSlow[slot],0,shift,1,slow)!=1 ||
      CopyRates(Sym,tf,shift,1,bar)!=1 || fast[0]==EMPTY_VALUE || slow[0]==EMPTY_VALUE) return 0;
   int trend=(fast[0]>slow[0] && bar[0].close>fast[0]) ? 1 : (fast[0]<slow[0] && bar[0].close<fast[0]) ? -1 : 0;
   word=trend>0 ? "UP" : trend<0 ? "DOWN" : "MIXED";
   return trend;
}

string TrendArrow(string word) { return word=="UP" ? "▲" : word=="DOWN" ? "▼" : word=="MIXED" ? "◆" : "?"; }

// All scanned timeframes right now (closed bars), e.g. "M5 ▲ | M15 ▲ | H1 ◆ | H4 ▼".
string MTFMatrix() {
   string text="";
   for(int k=0;k<TFCount;k++) {
      string word; TFTrendAt(k,TimeCurrent(),word);
      text+=(k>0 ? " | " : "")+TFName(TFList[k])+" "+TrendArrow(word);
   }
   return text;
}

// Higher-timeframe check for a signal on the current TF whose candle closed at `closedAt`.
// vote = +1 when every higher timeframe with data agrees. blocker is set when the signal fails.
void MTFCheck(int side, datetime closedAt, string &line, int &vote, string &blocker) {
   line=""; vote=0; blocker="";
   int agree=0, against=0, counted=0;
   string opposite="";
   for(int k=0;k<TFCount;k++) {
      if(PeriodSeconds(TFList[k])<=PeriodSeconds(TF)) continue;
      string word; int trend=TFTrendAt(k,closedAt,word);
      line+=(line=="" ? "" : ", ")+TFName(TFList[k])+" "+TrendArrow(word)+word;
      if(word=="n/a") continue;
      counted++;
      if(trend==side) agree++;
      else if(trend==-side) { against++; opposite+=(opposite=="" ? "" : ", ")+TFName(TFList[k])+" "+word; }
   }
   if(counted==0) {
      if(line=="") { line="Yuqori TF: yo'q (eng yuqori timeframe)"; return; }
      // Higher timeframes exist but none has data yet: the filter cannot confirm, so it blocks.
      line="Yuqori TF: "+line+" (ma'lumot yo'q)";
      blocker="yuqori timeframe ma'lumoti hali yuklanmagan";
      return;
   }
   int percent=(int)MathRound(100.0*agree/counted);
   line="Yuqori TF: "+line+" ("+(string)agree+"/"+(string)counted+" mos)";
   if(agree==counted) vote=1;
   if(against>0) blocker="yuqori timeframe qarshi: "+opposite;
   else if(percent<MTFMinAgreePercent) blocker="yuqori TF'larning faqat "+(string)percent+"%i mos (kerak "+(string)MTFMinAgreePercent+"%)";
}

// Strict gate after EvaluateSignal: higher-timeframe alignment and no opposing factor.
// Used for live signals and the history replay, so statistics match what is sent.
bool StrictChecks(int shift, LocalSignal &signal, string &reason) {
   string line, blocker;
   int vote=0;
   MTFCheck(signal.side,Rates[shift].time+PeriodSeconds(TF),line,vote,blocker);
   signal.mtf=line;
   signal.score+=vote;
   signal.factors+="\n"+(vote>0 ? "✅ " : blocker!="" ? "⚠️ " : "• ")+line;
   if(MTFFilter && blocker!="") { reason="Skipped "+signal.setup+": "+blocker; return false; }
   if(vote>0) FamilyFor[AZT_F_PA]++; // all higher timeframes trend the same way
   if(RequireAllChecks && signal.against>0) {
      reason="Skipped "+signal.setup+": "+(string)signal.against+" ta qarshi omil (RequireAllChecks)"; return false;
   }
   return StrategyGates(shift,signal,reason);
}

// "200 pt = 20.0 pips" (pips only for 3/5-digit forex quotes, where the term is unambiguous).
string Distance(double priceDistance) {
   double points=MathAbs(priceDistance)/SymPoint;
   string text=DoubleToString(points,0)+" pt";
   if((SymDigits==3 || SymDigits==5) && AssetClass()==AZT_ASSET_FOREX) text+=" = "+DoubleToString(points/10.0,1)+" pips";
   return text;
}

string Money(double value) { return DoubleToString(value,2)+" "+AccountInfoString(ACCOUNT_CURRENCY); }

void Level(string suffix, double price, color colour) {
   string name=Prefix+suffix;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
   ObjectSetString(0,name,OBJPROP_TEXT,suffix);
}

void DrawSignal(const LocalSignal &signal, bool historical) {
   string side=signal.side==1 ? "BUY" : "SELL";
   LastSignal=(historical ? "History: " : "Live: ")+TFName(TF)+" "+side+" "+TimeToString(signal.time)+
              " | Entry "+Price(signal.entry)+" SL "+Price(signal.sl)+
              "\nTP1 "+Price(signal.tp1)+" TP2 "+Price(signal.tp2)+" TP3 "+Price(signal.tp3);
   if(!DrawEnabled) return;
   string name=Prefix+"S_"+(string)(long)signal.time;
   double at=signal.entry-signal.side*0.3*signal.atr;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,signal.side==1 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL,0,signal.time,at);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,(historical ? "HISTORICAL " : "LIVE ")+side+" "+
      TimeToString(signal.time)+" | "+signal.setup+" | Entry "+Price(signal.entry)+" | SL "+Price(signal.sl));
   if(DrawLevels) {
      if(signal.zoneTop>0 && !historical) {
         string zone=Prefix+"Z_"+(string)(long)signal.time;
         ObjectDelete(0,zone);
         ObjectCreate(0,zone,OBJ_RECTANGLE,0,signal.time,signal.zoneTop,signal.time+PeriodSeconds(TF)*StructureExtendBars,signal.zoneBottom);
         ObjectSetInteger(0,zone,OBJPROP_COLOR,signal.side==1 ? clrSeaGreen : clrIndianRed);
         ObjectSetInteger(0,zone,OBJPROP_FILL,true); ObjectSetInteger(0,zone,OBJPROP_BACK,true);
         ObjectSetInteger(0,zone,OBJPROP_SELECTABLE,false);
         ObjectSetString(0,zone,OBJPROP_TOOLTIP,"Kirish zonasi | "+signal.setup);
      }
      Level("Entry",signal.entry,clrGold); Level("SL",signal.sl,clrTomato);
      Level(UsePartialTP ? "TP1 "+DoubleToString(TP1ClosePercent,0)+"%" : "TP1",signal.tp1,clrLimeGreen);
      Level(UsePartialTP ? "TP2 "+DoubleToString(TP2ClosePercent,0)+"%" : "TP2",signal.tp2,clrLimeGreen);
      Level("TP3",signal.tp3,clrLimeGreen);
   }
}

#include "AZT_History.mqh"
#include "AZT_Journal.mqh"

string ModeName() {
   return TradeMode==AZT_SIGNALS_ONLY ? "FAQAT SIGNAL" :
          TradeMode==AZT_CONFIRM_EVERY ? "HAR SAVDO TASDIQ BILAN" : "AI HYBRID (Claude rozi bo'lsa o'zi, aks holda tasdiq)";
}

// UP / DOWN / MIXED on the last closed higher-timeframe candle.
string HTFTrendWord(int index, ENUM_TIMEFRAMES tf, string &details) {
   double fast[1], slow[1];
   MqlRates bar[1];
   details="";
   if(SymIndex<0 || HTFHandles[SymIndex][index*2]==INVALID_HANDLE || CopyBuffer(HTFHandles[SymIndex][index*2],0,1,1,fast)!=1 ||
      CopyBuffer(HTFHandles[SymIndex][index*2+1],0,1,1,slow)!=1 || CopyRates(Sym,tf,1,1,bar)!=1) return "n/a";
   details="close "+Price(bar[0].close)+", EMA"+(string)FastEMA+" "+Price(fast[0])+", EMA"+(string)SlowEMA+" "+Price(slow[0]);
   return (fast[0]>slow[0] && bar[0].close>fast[0]) ? "UP" : (fast[0]<slow[0] && bar[0].close<fast[0]) ? "DOWN" : "MIXED";
}

string HTFTrend(int index, ENUM_TIMEFRAMES tf) {
   string details, word=HTFTrendWord(index,tf,details);
   return StringSubstr(EnumToString(tf),7)+" "+word+(details!="" ? " ("+details+")" : "");
}

string BiasWord() { return StructureBias>0 ? "bullish" : StructureBias<0 ? "bearish" : "neutral"; }

// Compact context stored in the journal (what the AI saw).
string SignalContext() {
   string d1, d2;
   string h1=HTFTrendWord(0,AIHigherTF1,d1), h2=HTFTrendWord(1,AIHigherTF2,d2);
   return "RSI "+DoubleToString(RSI[1],1)+", "+StringSubstr(EnumToString(AIHigherTF1),7)+" "+h1+", "+
          StringSubstr(EnumToString(AIHigherTF2),7)+" "+h2+", structure "+BiasWord();
}

// Facts only; each AI also receives its own track record and lessons.
string BuildAIPrompt(const LocalSignal &signal) {
   MqlTick tick;
   double spread=SymbolInfoTick(Sym,tick) ? (tick.ask-tick.bid)/SymPoint : 0;
   double risk=MathAbs(signal.entry-signal.sl);
   string p="Symbol: "+Sym+" ("+AssetName(AssetClass())+") | Signal timeframe: "+EnumToString(TF)+" | Broker time: "+TimeToString(TimeCurrent())+
      "\nProposed: "+(signal.side==1 ? "BUY" : "SELL")+" | Setup: "+signal.setup+
      "\nEntry "+Price(signal.entry)+" | SL "+Price(signal.sl)+" | TP1 ("+DoubleToString(TP1_R,2)+"R) "+Price(signal.tp1)+
      " | TP2 ("+DoubleToString(TP2_R,2)+"R) "+Price(signal.tp2)+" | TP3 ("+DoubleToString(TP3_R,2)+"R) "+Price(signal.tp3)+
      " | Risk "+DoubleToString(risk/SymPoint,0)+" points = "+DoubleToString(risk/MathMax(signal.atr,SymPoint),2)+" ATR"+
      "\nLast closed candle: ATR("+(string)ATRPeriod+") "+Price(ATR[1])+" | EMA"+(string)FastEMA+" "+Price(Fast[1])+
      " | EMA"+(string)SlowEMA+" "+Price(Slow[1])+" | RSI("+(string)RSIPeriod+") "+DoubleToString(RSI[1],1)+
      " | Spread "+DoubleToString(spread,1)+" points"+
      "\nHigher timeframes: "+HTFTrend(0,AIHigherTF1)+"; "+HTFTrend(1,AIHigherTF2)+
      "\nMulti-timeframe check (closed bars): "+signal.mtf+
      "\nAll scanned timeframes now (▲ up, ▼ down, ◆ mixed): "+MTFMatrix()+
      "\nStructure bias: "+BiasWord()+
      " | Last swing high "+(HighPivot.time>0 ? Price(HighPivot.price)+(HighPivot.broken ? " (broken)" : "") : "n/a")+
      " | Last swing low "+(LowPivot.time>0 ? Price(LowPivot.price)+(LowPivot.broken ? " (broken)" : "") : "n/a");
   string blocks="";
   for(int i=0;i<ArraySize(Blocks);i++)
      blocks+="\n- "+(Blocks[i].side==1 ? "Bullish" : "Bearish")+" OB "+Price(Blocks[i].bottom)+"-"+Price(Blocks[i].top)+
              (Blocks[i].touched ? " (touched)" : " (fresh)");
   p+="\nOrder blocks:"+(blocks=="" ? " none" : blocks);
   p+="\nClassic confluence checks (score "+(string)signal.score+", ✅ agrees / ⚠️ against):"+signal.factors;
   p+="\nExit plan actually used (overrides the plan in your instructions): "+ExitPlanText()+
      ". Judge whether price reaches TP3 before the stop.";
   p+="\nRule backtest on this timeframe (same plan): "+HistoryStatus;
   int count=MathMin(AICandles,ArraySize(Rates)-1);
   p+="\nLast "+(string)count+" closed candles, oldest first (time,open,high,low,close):";
   for(int i=count;i>=1;i--)
      p+="\n"+TimeToString(Rates[i].time)+","+Price(Rates[i].open)+","+Price(Rates[i].high)+","+
         Price(Rates[i].low)+","+Price(Rates[i].close);
   return p;
}

// ---- Lot size and partial-close volumes ---------------------------------------
double VolumeStep() { double step=SymbolInfoDouble(Sym,SYMBOL_VOLUME_STEP); return step>0 ? step : 0.01; }
double VolumeMin() { return SymbolInfoDouble(Sym,SYMBOL_VOLUME_MIN); }
string Lots(double volume) {
   int digits=(int)MathMax(0,MathCeil(-MathLog10(VolumeStep())-1e-9));
   return DoubleToString(volume,digits);
}

// Risk-based lot. A small account may use the broker minimum lot if its risk
// stays within MinLotMaxRiskPercent; otherwise no trade.
bool PlanVolume(int side, double entry, double sl, double &volume, double &riskMoney, string &reason) {
   volume=0; riskMoney=0;
   ENUM_ORDER_TYPE type=side==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double loss=0;
   if(!OrderCalcProfit(type,Sym,1.0,entry,sl,loss) || loss>=0) { reason="SL riskini hisoblab bo'lmadi"; return false; }
   loss=-loss;
   double step=VolumeStep(), minLot=VolumeMin(), maxLot=SymbolInfoDouble(Sym,SYMBOL_VOLUME_MAX);
   if(minLot<=0 || maxLot<minLot) { reason="Broker lot cheklovlari noto'g'ri"; return false; }
   double funds=MathMin(AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY));
   if(funds<=0) { reason="Hisobda mablag' yo'q"; return false; }
   volume=MathFloor(MathMin(funds*MaxRiskPercent/100.0/loss,maxLot)/step+1e-9)*step;
   if(volume<minLot-1e-9) {
      double minRiskPct=100.0*loss*minLot/funds;
      if(minRiskPct>MinLotMaxRiskPercent) {
         reason="Hisob kichik: eng kichik lot ("+Lots(minLot)+") riski "+DoubleToString(minRiskPct,1)+
                "% > ruxsat "+DoubleToString(MinLotMaxRiskPercent,1)+"%";
         volume=0; return false;
      }
      volume=minLot;
   }
   volume=NormalizeDouble(volume,8);
   riskMoney=loss*volume;
   return true;
}

// Part to close at a target; 0 when the lot cannot be split (each piece >= min lot).
double PartVolume(double initial, double percent, double current) {
   double step=VolumeStep(), minLot=VolumeMin();
   double part=MathFloor(initial*percent/100.0/step+1e-9)*step;
   if(part<minLot-1e-9 || current-part<minLot-1e-9) return 0;
   return NormalizeDouble(part,8);
}

string SplitText(double volume) {
   if(!UsePartialTP) return "Butun lot "+Lots(volume)+" TP3 ("+DoubleToString(TP3_R,1)+"R) gacha"+
                            (MoveSLAfterTP ? ": TP1 da SL → Entry, TP2 da SL → TP1" : "");
   double p1=PartVolume(volume,TP1ClosePercent,volume);
   double p2=PartVolume(volume,TP2ClosePercent,volume-p1);
   double rest=volume-p1-p2;
   if(p1<=0) return "Lot "+Lots(volume)+" bo'linmaydi (eng kichik lot): hammasi TP3 gacha"+
                    (MoveSLAfterTP ? ", TP1 da SL Entry ga ko'chadi" : "");
   return "Bo'linish: TP1 "+Lots(p1)+" | TP2 "+(p2>0 ? Lots(p2) : "-")+" | TP3 "+Lots(rest)+" lot";
}

// What happens at TP1 (part 0) / TP2 (part 1).
string TPAction(int part) {
   string move=part==0 ? "SL → Entry+"+DoubleToString(BreakevenLockR,2)+"R (zararsiz, TP1 foydasi saqlanadi)" : "SL → TP1";
   if(!UsePartialTP) return MoveSLAfterTP ? move : "kuzatiladi";
   return DoubleToString(part==0 ? TP1ClosePercent : TP2ClosePercent,0)+"% yopiladi"+(MoveSLAfterTP ? ", "+move : "");
}

// Exit plan in English for the Claude prompt (overrides the generic plan in the system text).
string ExitPlanText() {
   string trail=MoveSLAfterTP ? "; stop moves to entry+"+DoubleToString(BreakevenLockR,2)+"R at TP1 and to TP1 at TP2" : "";
   if(!UsePartialTP) return "whole position targets TP3 = "+DoubleToString(TP3_R,2)+"R"+trail;
   return DoubleToString(TP1ClosePercent,0)+"% closed at "+DoubleToString(TP1_R,2)+"R, "+DoubleToString(TP2ClosePercent,0)+
      "% at "+DoubleToString(TP2_R,2)+"R, rest at "+DoubleToString(TP3_R,2)+"R"+trail;
}

// Accuracy estimate shown with every signal: TP1 hit rate of the same rules on this symbol/TF,
// averaged with Claude's confidence when Claude answered. -1 when nothing is known yet.
int AccuracyPercent(const LocalSignal &signal, int claudeConfidence) {
   bool history=signal.histRate>=0 && signal.histSamples>0;
   if(history && claudeConfidence>0) return (int)MathRound((signal.histRate+claudeConfidence)/2.0);
   if(history) return (int)MathRound(signal.histRate);
   return claudeConfidence>0 ? claudeConfidence : -1;
}

string AccuracyText(const LocalSignal &signal, int claudeConfidence) {
   int accuracy=AccuracyPercent(signal,claudeConfidence);
   string text="🎯 Aniqlik: "+(accuracy>=0 ? (string)accuracy+"%" : "hali noma'lum");
   string parts="";
   if(signal.histRate>=0 && signal.histSamples>0)
      parts+="tarixda TP1 ga "+DoubleToString(signal.histRate,0)+"% ("+(string)signal.histSamples+" ta)";
   if(claudeConfidence>0) parts+=(parts=="" ? "" : " • ")+"Claude "+(string)claudeConfidence+"%";
   parts+=(parts=="" ? "" : " • ")+"strategiya "+(string)signal.families+"/"+(string)AZT_FAMILIES;
   return text+" ("+parts+")";
}

string LimitText(const LocalSignal &signal) {
   if(signal.limit<=0) return "";
   double risk=MathAbs(signal.limit-signal.sl);
   return "\n⏳ "+(signal.side==1 ? "BUY LIMIT" : "SELL LIMIT")+" (kutiladigan narx): "+Price(signal.limit)+
      "\n   🛑 SL "+Price(signal.sl)+" ("+Distance(risk)+")"+
      "\n   🎯 TP1 "+Price(signal.ltp1)+" | TP2 "+Price(signal.ltp2)+" | 🏁 TP3 "+Price(signal.ltp3)+
      "\n   ⌛ "+(string)LimitExpiryBars+" sham ichida ochilmasa bekor qilinadi";
}

string SignalText(const LocalSignal &signal, bool volumeOk, double volume, double riskMoney, string volumeReason) {
   double risk=MathAbs(signal.entry-signal.sl);
   int pct3=(int)MathRound(100-TP1ClosePercent-TP2ClosePercent);
   string d1, d2;
   string h1=HTFTrendWord(0,AIHigherTF1,d1), h2=HTFTrendWord(1,AIHigherTF2,d2);
   string text="📊 SIGNAL | "+Sym+" | "+TFName(TF)+" | "+(signal.side==1 ? "🟢 BUY" : "🔴 SELL")+
      "\n"+AssetName(AssetClass())+
      "\n🧩 Setup: "+signal.setup+
      "\n🕒 Sham yopildi (broker vaqti): "+TimeToString(signal.time)+
      (signal.zoneTop>0 ? "\n🧭 Zona: "+Price(signal.zoneBottom)+" – "+Price(signal.zoneTop) : "")+
      "\n━━━━━━━━━━━━━━"+
      "\n▶️ Kirish: "+Price(signal.entry)+" (bozor narxida)"+
      "\n🛑 Stop Loss: "+Price(signal.sl)+" ("+Distance(risk)+")"+
      "\n🎯 TP1: "+Price(signal.tp1)+" ("+DoubleToString(TP1_R,2)+"R, +"+Distance(risk*TP1_R)+") → "+TPAction(0)+
      "\n🎯 TP2: "+Price(signal.tp2)+" ("+DoubleToString(TP2_R,2)+"R, +"+Distance(risk*TP2_R)+") → "+TPAction(1)+
      "\n🏁 TP3: "+Price(signal.tp3)+" ("+DoubleToString(TP3_R,2)+"R, +"+Distance(risk*TP3_R)+") → "+
         (UsePartialTP ? "qolgan "+(string)pct3+"%" : "butun lot")+
      LimitText(signal)+
      "\n━━━━━━━━━━━━━━";
   if(volumeOk) {
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      bool split=PartVolume(volume,TP1ClosePercent,volume)>0;
      text+="\n💼 Lot: "+Lots(volume)+" | Risk: -"+Money(riskMoney)+" ("+DoubleToString(100.0*riskMoney/MathMax(balance,0.01),2)+"%)"+
            "\n💰 TP1 da: +"+Money(riskMoney*TP1_R*(UsePartialTP && split ? TP1ClosePercent/100.0 : 1.0))+
            " | hammasi TP gacha: +"+Money(riskMoney*(split ? PlanFullR() : TP3_R))+
            "\n✂️ "+SplitText(volume);
   } else text+="\n⚠️ Order ochib bo'lmaydi: "+volumeReason;
   text+="\n\n✅ TASDIQLAR (konfluens "+(string)signal.score+"):"+signal.factors;
   text+="\n📈 Trend: "+StringSubstr(EnumToString(AIHigherTF1),7)+" "+h1+" | "+StringSubstr(EnumToString(AIHigherTF2),7)+" "+h2+
         " | RSI "+DoubleToString(RSI[1],1)+" | struktura "+BiasWord()+
         "\n🕒 Barcha TF: "+MTFMatrix();
   return text;
}

#include "AZT_SignalImage.mqh"

void Notify(const string key, const string text, const string markup="") {
   Print("AZT: ",text);
   AZTTelegramQueue(key,AZTTrimTo(text,4000),300,markup);
}

void Panel() {
   string connection=TerminalInfoInteger(TERMINAL_CONNECTED) ? "connected" : "DISCONNECTED";
   if(MQLInfoInteger(MQL_TESTER)) connection="Strategy Tester";
   SaveTF();
   string frames="";
   for(int s=0;s<SymCount;s++) {
      int ready=0;
      for(int k=0;k<TFCount;k++) if(TFReady[s*TFCount+k]) ready++;
      frames+=(s%4==0 ? "\n  " : " | ")+SymList[s]+" "+(string)ready+"/"+(string)TFCount;
   }
   Comment("AI Zone Trader 5 | ",(string)SymCount," symbol x ",ScanList()," | ",connection,
      "\nRejim: ",ModeName()," | Kirish: ",EntryModeName(),
      "\nRisk: ",DoubleToString(MaxRiskPercent,1),"% | Chiqish: ",ExitPlanText(),
      "\nPozitsiya ",(string)PositionsTotal(),"/",(string)MaxOpenPositions," | Limit ",(string)CountPendingOrders(),"/",(string)MaxPendingOrders,
      "\nAI: ",AZTAIStatus(),(AITestStatus!="" ? "\nAI test: "+AITestStatus : ""),
      Pending.active ? "\nTELEGRAM TASDIG'I KUTILMOQDA: "+Pending.id : "",
      "\nTayyor TF'lar:",frames,
      "\nTekshiruv: ",(RequireAllChecks ? "barcha omillar" : "ball")," + ",(MTFFilter ? "yuqori TF" : "MTF o'chiq"),
      " + ",(string)MinFamilies,"/11 strategiya oilasi + aniqlik >= ",(string)MinAccuracyPercent,"%",
      " + ",(RequireAIApproval ? "Claude APPROVE >= "+(string)MinAIConfidence+"%" : "AI ixtiyoriy"),
      "\nLast signal: ",LastSignal,
      "\nTelegram: ",AZTTelegramStatus(),
      "\n",TradeStatus);
}

string EntryModeName() {
   return EntryMode==AZT_ENTRY_MARKET ? "bozor narxida" : EntryMode==AZT_ENTRY_LIMIT ? "faqat limit" : "bozor + limit";
}

bool DailyRiskSafe(string &reason) {
   datetime start=StringToTime(TimeToString(TimeCurrent(),TIME_DATE));
   if(!HistorySelect(start,TimeCurrent())) { reason="Cannot read account history"; return false; }
   double net=0;
   int streak=0;
   bool latestStreak=true;
   for(int i=HistoryDealsTotal()-1;i>=0;i--) {
      ulong ticket=HistoryDealGetTicket(i);
      // Account-wide P/L includes entry commissions and fees.
      long type=HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      double pnl=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+
                 HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_FEE);
      net+=pnl;
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(latestStreak && (entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)) {
         if(pnl<0) streak++;
         else if(pnl>0) latestStreak=false;
      }
   }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0) { reason="Account balance is zero"; return false; }
   if(-net>=balance*MaxDailyLossPercent/100.0) { reason="Kunlik zarar limiti"; return false; }
   if(streak>=MaxConsecutiveLosses) { reason="Ketma-ket zarar limiti"; return false; }
   return true;
}

string PosKey(ulong ticket) { return "AZTP."+PosScope+"."+(string)ticket; }

void PosKeyDelete(const string key) {
   GlobalVariableDel(key+".r"); GlobalVariableDel(key+".v"); GlobalVariableDel(key+".s");
   GlobalVariableDel(key+".m"); GlobalVariableDel(key+".e");
}

// Remember the original risk so TP1/TP2 management survives EA restarts (also for a limit order that fills later).
void PosKeySet(ulong ticket, double risk, double volume, double riskMoney, datetime expires) {
   string key=PosKey(ticket);
   GlobalVariableSet(key+".r",risk);
   GlobalVariableSet(key+".v",volume);
   GlobalVariableSet(key+".s",0);
   GlobalVariableSet(key+".m",riskMoney);
   if(expires>0) GlobalVariableSet(key+".e",(double)expires);
   GlobalVariablesFlush();
}

// This EA's pending limit orders on the account (all symbols).
int CountPendingOrders() {
   int count=0;
   for(int i=OrdersTotal()-1;i>=0;i--) {
      ulong ticket=OrderGetTicket(i);
      if(ticket>0 && OrderGetInteger(ORDER_MAGIC)==(long)MagicNumber) count++;
   }
   return count;
}

bool AZTPositionSlotAvailable(int positions,int orders,int limit,bool hedging,bool sameSymbol) {
   return positions+orders<limit && (hedging || !sameSymbol);
}
bool AutoOrder(const LocalSignal &signal, string &reason) {
   // Serialize this EA's entries across charts before checking the account cap.
   string file="AZT_order_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+".lock";
   int lock=FileOpen(file,FILE_READ|FILE_WRITE|FILE_BIN);
   if(lock==INVALID_HANDLE) { reason="Boshqa chart order ochmoqda; bu signal o'tkazildi"; return false; }
   bool ok=AutoOrderLocked(signal,reason);
   FileClose(lock);
   return ok;
}

// Account-level checks, then the market order and/or the limit order (EntryMode).
bool AutoOrderLocked(const LocalSignal &signal, string &reason) {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) {
      reason="MT5 da Algo Trading tugmasi yoki EA savdo ruxsati O'CHIQ"; return false;
   }
   if(SymbolInfoInteger(Sym,SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_DISABLED) { reason=Sym+" da savdo yopiq"; return false; }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE), equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance<=0 || equity<=0) { reason="Hisobda mablag' yo'q"; return false; }
   if((balance-equity)/balance*100.0>=MaxDrawdownPercent) { reason="Drawdown limiti"; return false; }
   if(!DailyRiskSafe(reason)) return false;
   string marketReason="", limitReason="";
   bool market=false, limit=false;
   if(EntryMode!=AZT_ENTRY_LIMIT) market=MarketOrder(signal,marketReason);
   if(EntryMode!=AZT_ENTRY_MARKET) limit=LimitOrder(signal,limitReason);
   reason=(EntryMode!=AZT_ENTRY_LIMIT ? "▶️ Bozor: "+marketReason : "")+(EntryMode==AZT_ENTRY_BOTH ? "\n" : "")+
          (EntryMode!=AZT_ENTRY_MARKET ? "⏳ Limit: "+limitReason : "");
   return market || limit;
}

bool MarketOrder(const LocalSignal &signal, string &reason) {
   if(!AZTPositionSlotAvailable(PositionsTotal(),0,MaxOpenPositions,true,false)) {
      reason="Ochiq pozitsiya limiti ("+(string)MaxOpenPositions+")"; return false;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING && PositionSelect(Sym)) {
      reason="Bu symbol ochiq: alohida parallel pozitsiyalar uchun hedging hisob kerak"; return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(Sym,tick) || tick.ask<=0 || tick.bid<=0) { reason="Narx yo'q"; return false; }
   if(MaxSpreadPoints>0 && (tick.ask-tick.bid)/SymPoint>MaxSpreadPoints) { reason="Spread katta ("+DoubleToString((tick.ask-tick.bid)/SymPoint,0)+" pt)"; return false; }
   double entry=signal.side==1 ? tick.ask : tick.bid;
   if(MathAbs(entry-signal.entry)>signal.atr*MaxEntryDriftATR) { reason="Narx signaldan juda uzoqlashdi"; return false; }
   double distance=signal.side*(entry-signal.sl);
   double minStop=SymbolInfoInteger(Sym,SYMBOL_TRADE_STOPS_LEVEL)*SymPoint;
   double marketClose=signal.side==1 ? tick.bid : tick.ask;
   if(distance<=0 || signal.side*(marketClose-signal.sl)<=minStop) { reason="SL broker cheklovini buzadi"; return false; }
   // Broker TP = TP3 from the real entry; TP1/TP2 partial closes are managed by the EA.
   double tp=TickPrice(entry+signal.side*distance*TP3_R,signal.side);
   if(tp<=0 || signal.side*(tp-marketClose)<=minStop) { reason="TP broker cheklovini buzadi"; return false; }
   ENUM_ORDER_TYPE type=signal.side==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double volume, riskMoney;
   if(!PlanVolume(signal.side,entry,signal.sl,volume,riskMoney,reason)) return false;
   double margin=0;
   if(!OrderCalcMargin(type,Sym,volume,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      reason="Erkin margin yetarli emas"; return false;
   }
   Trade.SetTypeFillingBySymbol(Sym);
   string comment="AZT-"+(string)(long)signal.time;
   bool sent=signal.side==1 ? Trade.Buy(volume,Sym,entry,signal.sl,tp,comment)
                           : Trade.Sell(volume,Sym,entry,signal.sl,tp,comment);
   uint code=Trade.ResultRetcode();
   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL && code!=TRADE_RETCODE_PLACED)) {
      reason="Broker rad etdi: "+(string)code+" "+Trade.ResultRetcodeDescription(); return false;
   }
   double open=entry, filled=volume;
   ulong ticket=0, positionId=0;
   if(Trade.ResultDeal()>0 && HistoryDealSelect(Trade.ResultDeal()))
      positionId=(ulong)HistoryDealGetInteger(Trade.ResultDeal(),DEAL_POSITION_ID);
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(t>0 && (t==Trade.ResultOrder() || (positionId>0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER)==positionId)) && PositionGetString(POSITION_SYMBOL)==Sym && PositionGetInteger(POSITION_MAGIC)==(long)MagicNumber) {
         ticket=t; open=PositionGetDouble(POSITION_PRICE_OPEN); filled=PositionGetDouble(POSITION_VOLUME); break;
      }
   }
   if(ticket==0) {
      // Position list not synced yet: fall back to the trade result so TP1/TP2 management still runs.
      ticket=positionId>0 ? positionId : Trade.ResultOrder();
      if(Trade.ResultPrice()>0) open=Trade.ResultPrice();
      if(Trade.ResultVolume()>0) filled=Trade.ResultVolume();
   }
   double risk=MathAbs(open-signal.sl);
   if(ticket>0) PosKeySet(ticket,risk,filled,riskMoney,0);
   reason="Order ochildi #"+(string)ticket+" | "+(signal.side==1 ? "BUY " : "SELL ")+Lots(filled)+" lot @ "+Price(open)+
      "\nSL "+Price(signal.sl)+" | TP1 "+Price(open+signal.side*risk*TP1_R)+" | TP2 "+Price(open+signal.side*risk*TP2_R)+
      " | TP3 "+Price(tp)+"\nRisk: -"+Money(riskMoney)+"\n"+SplitText(filled);
   return true;
}

// BUY LIMIT / SELL LIMIT at the zone. Cancelled by the EA after LimitExpiryBars candles.
bool LimitOrder(const LocalSignal &signal, string &reason) {
   if(signal.limit<=0) { reason="mos zona narxi yo'q"; return false; }
   if(CountPendingOrders()>=MaxPendingOrders) { reason="Limit orderlar limiti ("+(string)MaxPendingOrders+")"; return false; }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING && PositionSelect(Sym)) {
      reason="Bu symbol ochiq: limit uchun hedging hisob kerak"; return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(Sym,tick) || tick.ask<=0 || tick.bid<=0) { reason="Narx yo'q"; return false; }
   double market=signal.side==1 ? tick.ask : tick.bid;
   double minStop=MathMax(SymbolInfoInteger(Sym,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(Sym,SYMBOL_TRADE_FREEZE_LEVEL))*SymPoint;
   if(signal.side*(market-signal.limit)<=minStop) { reason="Narx limit narxiga juda yaqin yoki o'tib ketgan"; return false; }
   double risk=signal.side*(signal.limit-signal.sl);
   if(risk<=minStop || signal.side*(signal.ltp3-signal.limit)<=minStop) { reason="SL/TP broker cheklovini buzadi"; return false; }
   double volume, riskMoney;
   if(!PlanVolume(signal.side,signal.limit,signal.sl,volume,riskMoney,reason)) return false;
   double margin=0;
   if(!OrderCalcMargin(signal.side==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,Sym,volume,signal.limit,margin) ||
      margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) { reason="Erkin margin yetarli emas"; return false; }
   Trade.SetTypeFillingBySymbol(Sym);
   string comment="AZT-L-"+(string)(long)signal.time;
   bool sent=signal.side==1 ? Trade.BuyLimit(volume,signal.limit,Sym,signal.sl,signal.ltp3,ORDER_TIME_GTC,0,comment)
                           : Trade.SellLimit(volume,signal.limit,Sym,signal.sl,signal.ltp3,ORDER_TIME_GTC,0,comment);
   uint code=Trade.ResultRetcode();
   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_PLACED)) {
      reason="Broker rad etdi: "+(string)code+" "+Trade.ResultRetcodeDescription(); return false;
   }
   ulong order=Trade.ResultOrder();
   datetime expires=TimeCurrent()+LimitExpiryBars*PeriodSeconds(TF);
   if(order>0) PosKeySet(order,risk,volume,riskMoney,expires);
   reason=(signal.side==1 ? "BUY LIMIT #" : "SELL LIMIT #")+(string)order+" | "+Lots(volume)+" lot @ "+Price(signal.limit)+
      "\nSL "+Price(signal.sl)+" | TP1 "+Price(signal.ltp1)+" | TP2 "+Price(signal.ltp2)+" | TP3 "+Price(signal.ltp3)+
      "\nRisk: -"+Money(riskMoney)+" | "+TimeToString(expires)+" gacha kutadi";
   return true;
}

// Cancels this EA's limit orders whose time ran out.
void ManagePendingOrders() {
   for(int i=OrdersTotal()-1;i>=0;i--) {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || OrderGetInteger(ORDER_MAGIC)!=(long)MagicNumber) continue;
      string key=PosKey(ticket);
      if(!GlobalVariableCheck(key+".e") || TimeCurrent()<(datetime)GlobalVariableGet(key+".e")) continue;
      string symbol=OrderGetString(ORDER_SYMBOL);
      if(Trade.OrderDelete(ticket)) {
         PosKeyDelete(key);
         Notify("lx|"+(string)ticket,"⌛ "+symbol+" limit #"+(string)ticket+": narx kelmadi, muddati tugadi va bekor qilindi.");
      }
   }
}

// TP1/TP2 partial closes and stop moves for this EA's positions on every symbol.
void ManagePositions() {
   string saved=Sym;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;
      string key=PosKey(ticket);
      if(!GlobalVariableCheck(key+".r")) continue;
      int stage=(int)GlobalVariableGet(key+".s");
      double r=GlobalVariableGet(key+".r"), initial=GlobalVariableGet(key+".v");
      if(stage>=2 || r<=0) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      MqlTick tick;
      if(!SymbolInfoTick(symbol,tick) || tick.bid<=0) continue;
      if(symbol!=Sym) AZTSelectSymbol(symbol);
      if(GlobalVariableCheck(key+".e")) GlobalVariableDel(key+".e"); // the limit order has filled
      int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1;
      double open=PositionGetDouble(POSITION_PRICE_OPEN), volume=PositionGetDouble(POSITION_VOLUME);
      double sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double price=side==1 ? tick.bid : tick.ask;
      double target=open+side*r*(stage==0 ? TP1_R : TP2_R);
      if(side*(price-target)<0) continue;
      GlobalVariableSet(key+".s",stage+1); // once per stage, even if the broker refuses
      GlobalVariablesFlush();
      string message="🎯 TP"+(string)(stage+1)+" | "+Sym+" #"+(string)ticket+" narx "+Price(price);
      if(UsePartialTP) {
         double part=PartVolume(initial,stage==0 ? TP1ClosePercent : TP2ClosePercent,volume);
         if(part>0) {
            if(Trade.PositionClosePartial(ticket,part)) message+="\n✅ "+Lots(part)+" lot yopildi (foyda olindi)";
            else message+="\n⚠️ Qisman yopilmadi: "+Trade.ResultRetcodeDescription();
         } else message+="\nℹ️ Lot kichik, qism yopilmadi";
      }
      if(MoveSLAfterTP) {
         // After TP1 the stop sits slightly beyond entry, so spread/commission never eat the TP1 profit.
         double newSL=TickPrice(stage==0 ? open+side*r*BreakevenLockR : open+side*r*TP1_R,side);
         double minStop=SymbolInfoInteger(Sym,SYMBOL_TRADE_STOPS_LEVEL)*SymPoint;
         if(side*(newSL-sl)>0 && side*(price-newSL)>minStop && PositionSelectByTicket(ticket)) {
            if(Trade.PositionModify(ticket,newSL,tp))
               message+="\n🛡 SL → "+Price(newSL)+(stage==0 ? " (zararsiz, TP1 foydasi saqlanadi)" : " (TP1, foyda himoyalandi)");
            else message+="\n⚠️ SL ko'chmadi: "+Trade.ResultRetcodeDescription();
         }
      }
      Notify("mg|"+(string)ticket+"|"+(string)stage,message);
   }
   if(Sym!=saved) AZTSelectSymbol(saved);
}

// Reports the real money result once a managed position is fully closed; forgets cancelled limit orders.
void ReportClosedPositions() {
   string prefix="AZTP."+PosScope+".";
   string names[];
   for(int i=GlobalVariablesTotal()-1;i>=0;i--) {
      string name=GlobalVariableName(i);
      if(StringFind(name,prefix)==0 && StringSubstr(name,StringLen(name)-2)==".r") {
         int n=ArraySize(names); ArrayResize(names,n+1); names[n]=StringSubstr(name,0,StringLen(name)-2);
      }
   }
   for(int i=0;i<ArraySize(names);i++) {
      ulong ticket=(ulong)StringToInteger(StringSubstr(names[i],StringLen(prefix)));
      if(ticket==0 || PositionSelectByTicket(ticket) || OrderSelect(ticket)) continue;
      if(!HistorySelectByPosition(ticket)) continue;
      double net=0;
      bool exited=false;
      string symbol="";
      for(int d=0;d<HistoryDealsTotal();d++) {
         ulong deal=HistoryDealGetTicket(d);
         net+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+
              HistoryDealGetDouble(deal,DEAL_COMMISSION)+HistoryDealGetDouble(deal,DEAL_FEE);
         long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT) exited=true;
         symbol=HistoryDealGetString(deal,DEAL_SYMBOL);
      }
      if(!exited) {
         // A limit order that was cancelled/expired/rejected never becomes a position: forget it.
         if(HistoryDealsTotal()==0 && HistoryOrderSelect(ticket)) {
            long state=HistoryOrderGetInteger(ticket,ORDER_STATE);
            if(state==ORDER_STATE_CANCELED || state==ORDER_STATE_EXPIRED || state==ORDER_STATE_REJECTED) PosKeyDelete(names[i]);
         }
         // Otherwise history is not synced yet (reconnect, fresh fill): check again later.
         continue;
      }
      double riskMoney=GlobalVariableGet(names[i]+".m");
      int stage=(int)GlobalVariableGet(names[i]+".s");
      Notify("cl|"+(string)ticket,(net>=0 ? "💰" : "🔻")+" SAVDO YOPILDI | "+symbol+" #"+(string)ticket+
         "\nNatija: "+(net>=0 ? "+" : "")+Money(net)+(riskMoney>0 ? " ("+DoubleToString(net/riskMoney,2)+"R)" : "")+
         " | olingan TP: "+(string)stage+
         "\nBalans: "+Money(AccountInfoDouble(ACCOUNT_BALANCE)));
      PosKeyDelete(names[i]);
   }
}

// Every live signal (sent or filtered) is appended to MQL5/Files/AZT_signals_v5.csv, so other tools (Ali) can read it.
// ai = APPROVE / REJECT / NONE, sent = 1 when it reached Telegram as a verified signal.
string CsvClean(string value) { StringReplace(value,","," "); StringReplace(value,"\n"," "); StringReplace(value,"\r"," "); return value; }

void ExportSignal(const LocalSignal &signal, string ai, int confidence, bool sent) {
   int h=FileOpen("AZT_signals_v5.csv",FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ,'\t',CP_UTF8);
   if(h==INVALID_HANDLE) { Print("AZT: signal CSV ochilmadi: ",GetLastError()); return; }
   if(FileSize(h)==0) FileWriteString(h,"time,symbol,timeframe,side,setup,entry,sl,tp1,tp2,tp3,zone_low,zone_high,score,atr,ai,ai_conf,sent,mtf\r\n");
   FileSeek(h,0,SEEK_END);
   FileWriteString(h,TimeToString(signal.time,TIME_DATE|TIME_MINUTES)+","+Sym+","+TFName(TF)+","+
      (signal.side==1 ? "BUY" : "SELL")+","+CsvClean(signal.setup)+","+Price(signal.entry)+","+Price(signal.sl)+","+
      Price(signal.tp1)+","+Price(signal.tp2)+","+Price(signal.tp3)+","+Price(signal.zoneBottom)+","+
      Price(signal.zoneTop)+","+(string)signal.score+","+DoubleToString(signal.atr,SymDigits)+","+ai+","+
      (string)confidence+","+(sent ? "1" : "0")+","+CsvClean(signal.mtf)+"\r\n");
   FileClose(h);
}

int InitBudget=0; // Slots allowed to load history in the current Scan (first load + replay is slow)

void Scan() {
   InitBudget=4;
   // Per symbol, highest timeframe first: Claude calls block, so lower timeframes are the ones that may run late.
   for(int s=0;s<SymCount;s++)
      for(int k=TFCount-1;k>=0;k--) { SwitchSlot(s*TFCount+k); ScanTF(); }
   Panel();
}

// One symbol x timeframe slot (already loaded by SwitchSlot).
void ScanTF() {
   if(!Ready) {
      int count=RequiredBars()+HistoryBars;
      int available=Bars(Sym,TF);
      if(available<IndicatorBars()) {
         CopyRates(Sym,TF,0,RequiredBars(),Rates);
         Status="Waiting for price history"; return;
      }
      count=MathMin(count,available);
      if(InitBudget<=0) { Status="Navbatda: tarix yuklanadi"; return; }
      InitBudget--;
      if(!LoadData(count)) { Status="Waiting for indicator data"; return; }
      RebuildStructure();
      RunHistoricalAnalysis();
      SlotHistAge[CurSlot]=0;
      ResolveJournal();
      LastClosedBar=Rates[1].time;
      Ready=true;
      Status="Ready: waiting for the next candle close";
      Print("AZT ready: ",Sym," ",EnumToString(TF),"; historical signals=",HistoricalSignals,
            "; mode=",ModeName(),". Historical signals never trigger orders/alerts.");
      return;
   }
   datetime closed=iTime(Sym,TF,1);
   if(closed<=0 || closed==LastClosedBar) { return; }
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_CONNECTED)) {
      Status="Waiting: broker disconnected"; return;
   }
   int count=MathMin(Bars(Sym,TF),RequiredBars()+HistoryBars);
   if(count<IndicatorBars() || !LoadData(count)) { Status="Waiting for indicator data; will retry"; return; }
   RebuildStructure();
   // Only mark processed after all data is ready; shared OnTick/OnTimer guard.
   LastClosedBar=Rates[1].time;
   // The rule replay is the slowest step: refresh it every HistoryRefreshBars candles per slot.
   if(SlotHistAge[CurSlot]>=HistoryRefreshBars) { RunHistoricalAnalysis(false); SlotHistAge[CurSlot]=0; }
   else SlotHistAge[CurSlot]++;
   ResolveJournal();
   // Higher timeframes get a longer window (a D1/H4 bar's first tick can come minutes after its open).
   int maxDelay=MathMax(MaxSignalDelaySeconds,PeriodSeconds(TF)/12);
   if(!MQLInfoInteger(MQL_TESTER) && TimeCurrent()-Rates[0].time>maxDelay) {
      Status="Late candle skipped: waiting for a fresh close"; return;
   }
   LocalSignal signal; string reason;
   if(!EvaluateSignal(1,signal,reason) || !StrictChecks(1,signal,reason)) { Status=reason; Print("AZT ",Sym," ",TFName(TF),": ",Status); return; }
   if(CoolingDown(1)) { Status="Waiting: signal cooldown"; return; }
   // Quant gate: these exact rules lost money on this timeframe's recent history -> no live signal.
   if(MinHistorySamples>0 && HistoryTrades>=MinHistorySamples && HistoryExpectancyR<MinHistoryExpectancyR) {
      Status="Skipped "+signal.setup+": "+TFName(TF)+" tarixida o'rtacha "+DoubleToString(HistoryExpectancyR,2)+"R ("+
             (string)HistoryTrades+" ta) < "+DoubleToString(MinHistoryExpectancyR,2)+"R";
      Print("AZT ",Sym," ",TFName(TF),": ",Status); return;
   }
   // Accuracy gate: how often these rules reached TP1 on this symbol/TF before the stop.
   signal.histSamples=HistoryTrades;
   signal.histRate=HistoryTrades>0 ? 100.0*HistoryTP1/HistoryTrades : -1;
   if(MinAccuracyPercent>0 && HistoryTrades>=MinHistorySamples && signal.histRate<MinAccuracyPercent) {
      Status="Skipped "+signal.setup+": tarixiy aniqlik "+DoubleToString(signal.histRate,0)+"% < "+(string)MinAccuracyPercent+"%";
      Print("AZT ",Sym," ",TFName(TF),": ",Status); return;
   }
   if(HistoryTrades>0)
      signal.factors+="\n"+(HistoryExpectancyR>0 ? "✅ " : "• ")+"Tarix ("+TFName(TF)+", "+(string)HistoryTrades+" ta): o'rtacha "+
                      DoubleToString(HistoryExpectancyR,2)+"R";
   LastSignalBar=signal.time;
   SetupCount++;
   DrawSignal(signal,false);
   Status=(signal.side==1 ? "BUY" : "SELL")+string(" setup: ")+signal.setup;
   Print("AZT ",Sym," ",TFName(TF)," ",Status," | Entry ",Price(signal.entry)," SL ",Price(signal.sl),
         " TP1 ",Price(signal.tp1)," TP2 ",Price(signal.tp2)," TP3 ",Price(signal.tp3));
   HandleSignal(signal);
   if(DrawEnabled) ChartRedraw();
}

// Scores earlier signals on new closed candles and reports each AI's accuracy.
void ResolveJournal() {
   if(MQLInfoInteger(MQL_TESTER)) return;
   int resolved[];
   if(JournalResolve(resolved)==0) return;
   for(int i=0;i<ArraySize(resolved);i++) {
      string action=Journal[resolved[i]].action;
      // Signals Claude did not pass were never sent: their results only feed Claude's memory.
      if(action=="AI_REJECT" || action=="AI_LOW_CONF" || action=="AI_ERROR" || action=="NO_AI") continue;
      if(Journal[resolved[i]].outcome==1 || Journal[resolved[i]].outcome==-1)
         Notify("jr|"+Journal[resolved[i]].id,JournalResultText(resolved[i]));
   }
}

// AI review first. Only a signal that passed every check AND Claude's review reaches Telegram
// (RequireAIApproval); then: signal only / trade alone / ask for the Telegram button.
void HandleSignal(const LocalSignal &signal) {
   string id=AZTTelegramHash(Sym+"|"+EnumToString(TF)+"|"+(string)(long)signal.time+"|"+(string)MagicNumber);
   string key=Sym+"|"+EnumToString(TF)+"|"+(string)(long)signal.time;
   string reason, volumeReason;
   double volume=0, riskMoney=0;
   bool volumeOk=PlanVolume(signal.side,signal.entry,signal.sl,volume,riskMoney,volumeReason);
   if(MQLInfoInteger(MQL_TESTER)) {
      // No Telegram/AI in the tester: modes 1-2 trade the rules so they can be measured.
      TradeStatus="Signals only: orders are OFF";
      if(TradeMode!=AZT_SIGNALS_ONLY) TradeStatus=(AutoOrder(signal,reason) ? "" : "Order skipped: ")+reason;
      return;
   }
   string text=SignalText(signal,volumeOk,volume,riskMoney,volumeReason);
   AZTAIVerdict verdicts[AZT_AI_COUNT];
   for(int p=0;p<AZT_AI_COUNT;p++) ZeroMemory(verdicts[p]);
   int providers=AZTAIProviders(), approvals=0, rejections=0, minConfidence=100;
   string trustNote="", aiError="";
   if(InpAIEnabled && providers>0) {
      Status="Claude tekshirmoqda..."; Panel();
      string prompt=BuildAIPrompt(signal);
      text+="\n\n🤖 CLAUDE TEKSHIRUVI:";
      for(int p=0;p<AZT_AI_COUNT;p++) {
         if(!AZTAIHasKey(p)) continue;
         AZTAIReview(p,prompt+JournalMemory(p),verdicts[p]);
         text+="\n"+AZTAIVerdictText(AZTAIName(p),verdicts[p]);
         if(!verdicts[p].ok) { aiError=verdicts[p].error; continue; }
         if(verdicts[p].decision==1) {
            approvals++; minConfidence=MathMin(minConfidence,verdicts[p].confidence);
            int samples; double precision=JournalApprovePrecision(p,samples);
            if(samples>=8 && precision<InpAIMinPrecision)
               trustNote+="\n⚠️ "+AZTAIName(p)+" so'nggi APPROVE aniqligi "+DoubleToString(precision,0)+"% ("+
                          (string)samples+" ta): o'zi savdo ocholmaydi";
         } else rejections++;
      }
      text+=trustNote;
   } else text+="\n\n🤖 AI: o'chiq (AZT_Config.ini da API kalit yo'q)";
   bool aiAgrees=providers>0 && approvals==providers && minConfidence>=InpAIAutoConfidence && trustNote=="";
   bool aiRejects=rejections>0 && approvals==0;
   bool aiVerified=InpAIEnabled && providers>0 && approvals==providers && minConfidence>=MinAIConfidence;
   string aiWord=approvals>0 ? "APPROVE" : rejections>0 ? "REJECT" : "NONE";
   int aiConfidence=verdicts[AZT_AI_CLAUDE].ok ? verdicts[AZT_AI_CLAUDE].confidence : 0;
   string context=SignalContext();
   Status=(signal.side==1 ? "BUY" : "SELL")+string(" setup: ")+signal.setup+
          " | Claude "+aiWord+(aiConfidence>0 ? " "+(string)aiConfidence+"%" : "");

   // Gate: an unverified signal is journaled (Claude still learns from its outcome) but never sent.
   if(RequireAIApproval && !aiVerified) {
      string action=!InpAIEnabled || providers==0 ? "NO_AI" : aiRejects ? "AI_REJECT" :
                    approvals>0 ? "AI_LOW_CONF" : "AI_ERROR";
      FilteredCount++;
      TradeStatus="Yuborilmadi: "+(action=="AI_LOW_CONF" ? "Claude ishonchi "+(string)minConfidence+"% < "+
                  (string)MinAIConfidence+"%" : action=="AI_REJECT" ? "Claude rad etdi" : "Claude tekshira olmadi");
      JournalAdd(id,signal,context,verdicts,action);
      ExportSignal(signal,aiWord,aiConfidence,false);
      if((action=="AI_ERROR" || action=="NO_AI") && TimeLocal()>=NextAIWarning) {
         NextAIWarning=TimeLocal()+3600;
         Notify("aiwarn|"+(string)(long)TimeLocal(),"⚠️ "+Sym+" "+TFName(TF)+": Claude signalni tekshira olmadi ("+
            (aiError!="" ? aiError : "API kalit yo'q")+").\nTekshirilmagan signal yuborilmaydi. Chartdagi AI TEST tugmasini bosing.");
      }
      return;
   }
   SentCount++;
   ExportSignal(signal,aiWord,aiConfidence,true);
   string headline="AZT "+Sym+" "+TFName(TF)+" "+(signal.side==1 ? "BUY" : "SELL")+" "+signal.setup+
      " | Entry "+Price(signal.entry)+" SL "+Price(signal.sl)+" TP3 "+Price(signal.tp3);
   if(PopupAlerts) Alert(headline);
   if(PushNotifications && !SendNotification(headline)) Print("Push notification failed: ",GetLastError());
   string accuracy=AccuracyText(signal,aiConfidence);
   QueueSignalImage(signal,key,accuracy);
   text=(aiVerified ? "✅ TEKSHIRUVDAN O'TDI: barcha omillar + yuqori TF + Claude "+(string)minConfidence+"%"
                    : "ℹ️ Qoidalar tekshiruvidan o'tdi, Claude TASDIQLAMAGAN (RequireAIApproval=false)")+"\n"+accuracy+"\n\n"+text;

   if(TradeMode==AZT_SIGNALS_ONLY) {
      TradeStatus="Faqat signal rejimi";
      JournalAdd(id,signal,context,verdicts,"SIGNAL_ONLY");
      Notify(key,text+"\n\nℹ️ Faqat signal rejimi: savdo ochilmaydi. Natija keyinroq 📘 xabarda keladi.");
      return;
   }
   if(aiRejects && SkipWhenAIRejects) {
      TradeStatus="AI rad etdi: savdo yo'q";
      JournalAdd(id,signal,context,verdicts,"AI_REJECT");
      Notify(key,text+"\n\n⛔ AI rad etdi: savdoga kirilmaydi. Natijasi baribir kuzatiladi va AI'ga ko'rsatiladi.");
      return;
   }
   if(!volumeOk) {
      TradeStatus="No trade: "+volumeReason;
      JournalAdd(id,signal,context,verdicts,"NO_VOLUME");
      Notify(key,text+"\n\n⚠️ Savdo ochilmaydi: "+volumeReason);
      return;
   }
   if(TradeMode==AZT_AI_HYBRID && aiAgrees) {
      bool ok=AutoOrder(signal,reason);
      TradeStatus=(ok ? "AI auto: " : "AI auto skipped: ")+reason;
      JournalAdd(id,signal,context,verdicts,ok ? "AUTO" : "AUTO_FAILED");
      Notify(key,text+"\n\n"+(ok ? "✅ Claude tasdiqladi → " : "⚠️ AI tasdiqladi, lekin order ochilmadi: ")+reason);
      return;
   }
   if(!AZTTelegramReady()) {
      TradeStatus="Tasdiq kerak, lekin Telegram ulanmagan: savdo yo'q";
      JournalAdd(id,signal,context,verdicts,"NO_TELEGRAM");
      return;
   }
   if(Pending.active) {
      int current=CurSlot;
      SwitchSlot(Pending.tf);
      JournalSetAction(Pending.id,"SUPERSEDED"); // loads that slot's journal
      SwitchSlot(current);
      Notify("sup|"+Pending.id,"Avvalgi tasdiq so'rovi yangi signal bilan almashtirildi: "+Pending.id);
   }
   Pending.active=true; Pending.id=id; Pending.signal=signal; Pending.tf=CurSlot;
   Pending.expires=TimeLocal()+ApprovalTimeoutMinutes*60;
   TradeStatus="Telegram tasdig'i kutilmoqda ("+(string)ApprovalTimeoutMinutes+" daqiqa)";
   JournalAdd(id,signal,context,verdicts,"WAITING");
   Notify(key,text+"\n\n❓ SAVDOGA KIRAMIZMI? "+(string)ApprovalTimeoutMinutes+" daqiqa ichida tugmani bosing."+
      "\nNarx signaldan "+DoubleToString(MaxEntryDriftATR,2)+" ATR dan ko'p qochsa, order ochilmaydi.",AZTApprovalMarkup(id));
}

// Called from OnTimer: executes or drops the trade once you press a button.
void ProcessPending() {
   if(!Pending.active) return;
   SwitchSlot(Pending.tf); // symbol, journal and messages belong to the signal's slot
   int decision=AZTDecision(Pending.id);
   if(decision==0) { AZTTelegramPollDecisions(); decision=AZTDecision(Pending.id); }
   if(decision==0) {
      if(TimeLocal()<Pending.expires) return;
      Pending.active=false;
      TradeStatus="Tasdiq muddati tugadi: savdo yo'q";
      JournalSetAction(Pending.id,"EXPIRED");
      Notify("exp|"+Pending.id,"⌛ "+Sym+" "+TFName(TF)+": tasdiq muddati tugadi, savdo ochilmadi.");
      return;
   }
   Pending.active=false;
   if(decision<0) {
      TradeStatus="Siz bekor qildingiz";
      JournalSetAction(Pending.id,"USER_REJECT");
      Notify("res|"+Pending.id,"❌ "+Sym+": siz bekor qildingiz, savdo ochilmadi.");
      return;
   }
   string reason;
   bool ok=AutoOrder(Pending.signal,reason);
   TradeStatus=(ok ? "Tasdiqlandi: " : "Tasdiqlandi, lekin ochilmadi: ")+reason;
   JournalSetAction(Pending.id,ok ? "APPROVED" : "APPROVED_FAILED");
   Notify("res|"+Pending.id,(ok ? "✅ "+Sym+": tasdiqingiz bilan order ochildi.\n" :
                                  "⚠️ "+Sym+": tasdiqlandi, lekin order ochilmadi.\n")+reason);
}

// Telegram test: a sample signal from the current price with working buttons.
// Pressing a button only gets a reply; no order is ever placed.
string TestId="";
datetime TestExpires=0, TestSentAt=0;

void RequestTelegramTest() {
   if(!AZTTelegramReady()) { TradeStatus="Telegram ulanmagan: "+AZTTelegramStatus(); return; }
   if(TimeLocal()-TestSentAt<30) return;
   SwitchSlot(0); // the chart's own symbol
   MqlTick tick;
   double atrBuffer[1], atr=0;
   if(CopyBuffer(ATRHandle,0,1,1,atrBuffer)==1) atr=atrBuffer[0];
   if(!SymbolInfoTick(Sym,tick) || tick.ask<=0 || atr<=0) { TradeStatus="Test: narx/ATR hali tayyor emas"; return; }
   LocalSignal sample; ZeroMemory(sample);
   sample.side=1; sample.time=TimeCurrent(); sample.atr=atr; sample.setup="TEST (namuna)";
   sample.entry=TickPrice(tick.ask); sample.sl=TickPrice(sample.entry-StopATR*atr,-1);
   double risk=sample.entry-sample.sl;
   sample.tp1=TickPrice(sample.entry+risk*TP1_R,1); sample.tp2=TickPrice(sample.entry+risk*TP2_R,1);
   sample.tp3=TickPrice(sample.entry+risk*TP3_R,1);
   sample.factors="\n• Bu namuna: haqiqiy signalda MACD, MA200, FVG, S/R, Fibonacci va patternlar shu yerda bo'ladi";
   double volume=0, riskMoney=0; string reason;
   bool ok=PlanVolume(1,sample.entry,sample.sl,volume,riskMoney,reason);
   TestId="T"+StringSubstr(AZTTelegramHash(Sym+(string)(long)TimeLocal()),0,12);
   TestExpires=TimeLocal()+15*60; TestSentAt=TimeLocal();
   Notify("test|"+TestId,"🧪 TELEGRAM TEST — savdo OCHILMAYDI\n"+SignalText(sample,ok,volume,riskMoney,reason)+
      "\n\nTugmalarni sinang: bosganingizga EA javob beradi.",AZTApprovalMarkup(TestId));
   TradeStatus="Telegram test yuborildi: tugmani bosing";
}

void ProcessTelegramTest() {
   if(TestId=="") return;
   int decision=AZTDecision(TestId);
   if(decision==0) { AZTTelegramPollDecisions(); decision=AZTDecision(TestId); }
   if(decision==0) { if(TimeLocal()>=TestExpires) TestId=""; return; }
   Notify("testres|"+TestId,decision>0 ? "✅ TEST: siz TASDIQLADINGIZ. Haqiqiy signalda EA hozir savdoga kirardi."
                                       : "❌ TEST: siz RAD ETDINGIZ. Haqiqiy signalda savdo ochilmasdi.");
   TradeStatus=decision>0 ? "Telegram test: tasdiqlash tugmasi ishlaydi" : "Telegram test: rad etish tugmasi ishlaydi";
   TestId="";
}

void RunAITest() {
   AITestStatus="tekshirilmoqda...";
   Panel();
   AZTAIInit();
   string claude=AZTAIPing(AZT_AI_CLAUDE);
   AITestStatus=claude;
   Notify("aitest|"+(string)(long)TimeLocal(),"🧪 AI TEST | "+Sym+"\n"+claude+
      "\nBu savdo signali emas.");
}

// ---- Timeframe switching -------------------------------------------------------
string ScanList() {
   string text="";
   for(int k=0;k<TFCount;k++) text+=(k>0 ? "," : "")+TFName(TFList[k]);
   return text;
}

bool ParseTimeframe(string name, ENUM_TIMEFRAMES &tf) {
   StringTrimLeft(name); StringTrimRight(name); StringToUpper(name);
   string names[]={"M1","M2","M3","M5","M10","M15","M20","M30","H1","H2","H3","H4","H6","H8","H12","D1","W1","MN1"};
   ENUM_TIMEFRAMES values[]={PERIOD_M1,PERIOD_M2,PERIOD_M3,PERIOD_M5,PERIOD_M10,PERIOD_M15,PERIOD_M20,PERIOD_M30,
      PERIOD_H1,PERIOD_H2,PERIOD_H3,PERIOD_H4,PERIOD_H6,PERIOD_H8,PERIOD_H12,PERIOD_D1,PERIOD_W1,PERIOD_MN1};
   for(int i=0;i<ArraySize(names);i++) if(names[i]==name) { tf=values[i]; return true; }
   return false;
}

// ScanTimeframes -> TFList, ascending, without duplicates. Empty -> SignalTimeframe / chart timeframe.
bool BuildTimeframeList() {
   TFCount=0;
   string parts[];
   int n=StringSplit(ScanTimeframes,',',parts);
   for(int i=0;i<n;i++) {
      string part=parts[i];
      StringTrimLeft(part); StringTrimRight(part);
      if(part=="") continue;
      ENUM_TIMEFRAMES tf;
      if(!ParseTimeframe(part,tf)) { Print("AZT: noma'lum timeframe '",part,"' (masalan: M5,M15,H1,H4,D1)"); return false; }
      bool seen=false;
      for(int k=0;k<TFCount;k++) if(TFList[k]==tf) seen=true;
      if(seen) continue;
      if(TFCount>=AZT_MAX_TF) { Print("AZT: ko'pi bilan ",AZT_MAX_TF," ta timeframe"); return false; }
      int at=TFCount;
      while(at>0 && PeriodSeconds(TFList[at-1])>PeriodSeconds(tf)) { TFList[at]=TFList[at-1]; at--; }
      TFList[at]=tf; TFCount++;
   }
   if(TFCount==0) { TFList[0]=SignalTimeframe==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : SignalTimeframe; TFCount=1; }
   return true;
}

void SaveTF() {
   if(CurSlot<0) return;
   TFLastClosed[CurSlot]=LastClosedBar; TFLastSignal[CurSlot]=LastSignalBar; TFReady[CurSlot]=Ready;
   TFStatus[CurSlot]=Status; TFHistory[CurSlot]=HistoryStatus; TFHistSignals[CurSlot]=HistoricalSignals;
   SlotHistTrades[CurSlot]=HistoryTrades; SlotHistTP1[CurSlot]=HistoryTP1; SlotHistExp[CurSlot]=HistoryExpectancyR;
}

// Loads one symbol x timeframe slot into the globals (symbol, handles, scan state, history stats).
// Rates[] etc. are reloaded by LoadData; the journal is loaded lazily by EnsureJournal().
void SwitchSlot(int slot) {
   if(TFCount<=0 || slot<0 || slot>=SymCount*TFCount || slot==CurSlot) return;
   SaveTF();
   CurSlot=slot;
   int s=slot/TFCount, k=slot%TFCount;
   if(s!=SymIndex || Sym!=SymList[s]) { SymIndex=s; AZTSelectSymbol(SymList[s]); }
   TFIndex=k; TF=TFList[k];
   FastHandle=TFFast[slot]; SlowHandle=TFSlow[slot]; RSIHandle=TFRSI[slot]; ATRHandle=TFATR[slot];
   MACDHandle=TFMACD[slot]; TrendMAHandle=TFTrendMA[slot]; StochHandle=TFStoch[slot]; ADXHandle=TFADX[slot];
   LastClosedBar=TFLastClosed[slot]; LastSignalBar=TFLastSignal[slot]; Ready=TFReady[slot];
   Status=TFStatus[slot]; HistoryStatus=TFHistory[slot]; HistoricalSignals=TFHistSignals[slot];
   HistoryTrades=SlotHistTrades[slot]; HistoryTP1=SlotHistTP1[slot]; HistoryExpectancyR=SlotHistExp[slot];
   DrawEnabled=Sym==_Symbol && TF==(ENUM_TIMEFRAMES)_Period;
   InvalidateStructureCache();
}

// ScanSymbols (or every Market Watch symbol) -> SymList. The chart's own symbol always comes first.
bool BuildSymbolList() {
   SymCount=0;
   string names[];
   string wanted=ScanSymbols;
   StringTrimLeft(wanted); StringTrimRight(wanted);
   int n=0;
   if(wanted!="") n=StringSplit(wanted,',',names);
   else {
      n=SymbolsTotal(true);
      ArrayResize(names,n);
      for(int i=0;i<n;i++) names[i]=SymbolName(i,true);
   }
   int limit=MathMin(MaxSymbols,AZT_MAX_SYMBOLS);
   for(int i=-1;i<n && SymCount<limit;i++) {
      string name=i<0 ? _Symbol : names[i];
      StringTrimLeft(name); StringTrimRight(name);
      if(name=="") continue;
      bool seen=false;
      for(int j=0;j<SymCount;j++) if(SymList[j]==name) seen=true;
      if(seen) continue;
      if(!SymbolSelect(name,true)) { Print("AZT: symbol topilmadi: ",name); continue; }
      SymList[SymCount++]=name;
   }
   if(SymCount*TFCount>AZT_MAX_SLOTS) SymCount=AZT_MAX_SLOTS/TFCount;
   return SymCount>0;
}

// Lessons from wrong calls: one slot per call, at most every 30 seconds.
void ReflectNext() {
   static int next=-1;
   static datetime nextTry=0;
   int slots=SymCount*TFCount;
   if(Pending.active || slots==0 || !InpAILearnFromMistakes || MQLInfoInteger(MQL_TESTER) || TimeLocal()<nextTry) return;
   nextTry=TimeLocal()+30;
   next=(next+1)%slots;
   SwitchSlot(next);
   if(Ready) JournalReflectOne();
}

// ---- "EA ishlayapti" report and start message -----------------------------------
void Heartbeat() {
   if(HeartbeatHours<=0 || MQLInfoInteger(MQL_TESTER) || !AZTTelegramReady() || TimeLocal()<NextHeartbeat) return;
   bool first=NextHeartbeat==0;
   SaveTF();
   int slots=SymCount*TFCount, ready=0;
   for(int i=0;i<slots;i++) if(TFReady[i]) ready++;
   // Start message once every slot has loaded (or after 3 minutes).
   if(first && ready<slots && TimeLocal()-StartedAt<180) return;
   NextHeartbeat=TimeLocal()+HeartbeatHours*3600;
   string guard="AZTHB."+PosScope;
   // Re-attaching the EA (inputs changed) must not spam start messages.
   if(first && GlobalVariableCheck(guard) && TimeLocal()-(datetime)GlobalVariableGet(guard)<1800) return;
   GlobalVariableSet(guard,(double)TimeLocal());
   string frames="";
   for(int s=0;s<SymCount;s++) {
      int symbolReady=0;
      for(int k=0;k<TFCount;k++) if(TFReady[s*TFCount+k]) symbolReady++;
      frames+="\n"+(symbolReady==TFCount ? "✅ " : "⏳ ")+SymList[s]+": "+(string)symbolReady+"/"+(string)TFCount+" TF";
   }
   string text=(first ? "🟢 EA ISHGA TUSHDI" : "🫀 EA ISHLAYAPTI")+
      "\n📋 Rejim: "+ModeName()+" | kirish: "+EntryModeName()+
      "\n🕒 Timeframe'lar: "+ScanList()+
      "\n💱 Symbollar ("+(string)SymCount+"), tayyor "+(string)ready+"/"+(string)slots+":"+frames+
      "\n🔍 Tekshiruv: "+(RequireAllChecks ? "barcha omillar" : "konfluens bali")+(MTFFilter ? " + yuqori TF" : "")+
      " + kamida "+(string)MinFamilies+"/11 strategiya oilasi + aniqlik >= "+(string)MinAccuracyPercent+"%"+
      (RequireAIApproval ? " + Claude APPROVE >= "+(string)MinAIConfidence+"%" : "")+
      "\n💼 Pozitsiya "+(string)PositionsTotal()+"/"+(string)MaxOpenPositions+" | limit "+(string)CountPendingOrders()+"/"+(string)MaxPendingOrders+
      "\n🤖 AI: "+AZTAIStatus();
   if(!first) text+="\n📊 Oxirgi "+(string)HeartbeatHours+" soatda: setup "+(string)SetupCount+", yuborilgan signal "+
      (string)SentCount+", Claude o'tkazmagan "+(string)FilteredCount;
   text+="\n🧪 Sinash: chartdagi \"Telegram TEST\" tugmasi namunaviy signal yuboradi, \"AI TEST\" Claude'ni tekshiradi.";
   SetupCount=0; SentCount=0; FilteredCount=0;
   Notify("hb|"+PosScope+"|"+(string)(long)TimeLocal(),text);
}

void Button(string name, int y, string text) {
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,180);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,165);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,26);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void ReleaseHandles() {
   for(int i=0;i<AZT_MAX_SLOTS;i++) {
      if(TFFast[i]!=INVALID_HANDLE) IndicatorRelease(TFFast[i]);
      if(TFSlow[i]!=INVALID_HANDLE) IndicatorRelease(TFSlow[i]);
      if(TFRSI[i]!=INVALID_HANDLE) IndicatorRelease(TFRSI[i]);
      if(TFATR[i]!=INVALID_HANDLE) IndicatorRelease(TFATR[i]);
      if(TFMACD[i]!=INVALID_HANDLE) IndicatorRelease(TFMACD[i]);
      if(TFTrendMA[i]!=INVALID_HANDLE) IndicatorRelease(TFTrendMA[i]);
      if(TFStoch[i]!=INVALID_HANDLE) IndicatorRelease(TFStoch[i]);
      if(TFADX[i]!=INVALID_HANDLE) IndicatorRelease(TFADX[i]);
      TFFast[i]=INVALID_HANDLE; TFSlow[i]=INVALID_HANDLE; TFRSI[i]=INVALID_HANDLE; TFATR[i]=INVALID_HANDLE;
      TFMACD[i]=INVALID_HANDLE; TFTrendMA[i]=INVALID_HANDLE; TFStoch[i]=INVALID_HANDLE; TFADX[i]=INVALID_HANDLE;
   }
   for(int s=0;s<AZT_MAX_SYMBOLS;s++)
      for(int i=0;i<4;i++) {
         if(HTFHandles[s][i]!=INVALID_HANDLE) IndicatorRelease(HTFHandles[s][i]);
         HTFHandles[s][i]=INVALID_HANDLE;
      }
}

int OnInit() {
   if(FastEMA<2 || SlowEMA<=FastEMA || SlowEMA>1000 || RSIPeriod<2 || RSIPeriod>1000 ||
      ATRPeriod<2 || ATRPeriod>1000 || SwingLookback<1 || SwingLookback>500 ||
      SLBufferATR<0 || HistoryBars<0 || HistoryBars>5000 || HistoryMaxHoldingBars<1 || HistoryMaxHoldingBars>2000 ||
      HistoryRoundTripCostPoints<0 || CooldownBars<0 || MaxSignalDelaySeconds<1 || StopATR<=0 ||
      StructureLookback<50 || StructureLookback>2000 || PivotBars<1 || PivotBars>20 ||
      OBSearchBars<1 || OBSearchBars>100 || OBImpulseATR<=0 || MaxOrderBlocks<1 || MaxOrderBlocks>30 ||
      OBMaxAgeBars<1 || OBMaxAgeBars>2000 || StructureExtendBars<1 || StructureExtendBars>100 ||
      TrendlineToleranceATR<=0 || TrendlineToleranceATR>3 ||
      TP1_R<=0 || TP2_R<=TP1_R || TP3_R<=TP2_R ||
      TP1ClosePercent<=0 || TP2ClosePercent<0 || TP1ClosePercent+TP2ClosePercent>=100 ||
      RSIBuyMin<0 || RSIBuyMax>100 || RSIBuyMin>=RSIBuyMax ||
      RSISellMin<0 || RSISellMax>100 || RSISellMin>=RSISellMax ||
      (!EnableCrossSignals && !EnablePullbackSignals && !EnableStructureBreakSignals &&
       !EnableOrderBlockSignals && !EnableTrendlineSignals) || MaxRiskPercent<=0 || MaxRiskPercent>100 ||
      MinLotMaxRiskPercent<MaxRiskPercent || MaxDailyLossPercent<=0 || MaxDrawdownPercent<=0 || MaxConsecutiveLosses<1 ||
      MaxOpenPositions<1 || MaxSpreadPoints<0 || MaxEntryDriftATR<=0 || SlippagePoints<0 ||
      ApprovalTimeoutMinutes<1 || ApprovalTimeoutMinutes>1440 || AICandles<5 || AICandles>200 ||
      MACDFast<2 || MACDSlow<=MACDFast || MACDSignalPeriod<2 || TrendMAPeriod<10 || TrendMAPeriod>1000 ||
      FVGLookback<3 || FVGLookback>500 || FVGMinATR<0 || SNRLookback<20 || SNRLookback>2000 ||
      SNRZoneATR<=0 || SNRMinTouches<2 || MinConfluence<-10 || MinConfluence>10) {
      Print("AZT: Invalid input parameters"); return INIT_PARAMETERS_INCORRECT;
   }
   if(MinFamilies<0 || MinFamilies>11 || SweepBars<1 || SweepBars>20 || PDRangeBars<10 || PDRangeBars>1000 ||
      RangeBars<3 || RangeBars>100 || RangeMaxATR<=0 || StochK<2 || StochD<1 || StochSlowing<1 ||
      ADXPeriod<2 || ADXPeriod>200 || MinADX<0 || VolumeAvgBars<3 || VolumeAvgBars>500 || VolumeSpike<=1 ||
      SessionStartGMT<0 || SessionStartGMT>23 || SessionEndGMT<0 || SessionEndGMT>24 || SessionStartGMT==SessionEndGMT ||
      VolatilityBars<20 || VolatilityBars>1000 || MaxSpreadRiskPercent<=0 || SniperMaxZoneATR<=0 || MinHistorySamples<0 ||
      MaxPendingOrders<0 || MaxPendingOrders>100 || LimitOffsetATR<0 || LimitExpiryBars<1 || BreakevenLockR<0 ||
      BreakevenLockR>=TP1_R || MaxSymbols<1 || MinAccuracyPercent<0 || MinAccuracyPercent>100 || HistoryRefreshBars<1) {
      Print("AZT: Invalid input parameters (strategiya oilalari)"); return INIT_PARAMETERS_INCORRECT;
   }
   if(MTFMinAgreePercent<0 || MTFMinAgreePercent>100 || MinAIConfidence<0 || MinAIConfidence>100 ||
      HeartbeatHours<0 || HeartbeatHours>168 || !BuildTimeframeList()) {
      Print("AZT: Invalid input parameters (ScanTimeframes / MTF / AI / Heartbeat)"); return INIT_PARAMETERS_INCORRECT;
   }
   if(!BuildSymbolList()) { Print("AZT: ScanSymbols da birorta ham symbol topilmadi"); return INIT_PARAMETERS_INCORRECT; }
   Prefix="AZT_LOCAL_"+(string)MagicNumber+"_";
   // One EA manages every symbol, so trade records are scoped by magic number only.
   PosScope=StringSubstr(AZTTelegramHash("ALL|"+(string)MagicNumber),0,8);
   ArraySetAsSeries(Rates,true); ArraySetAsSeries(Fast,true); ArraySetAsSeries(Slow,true);
   ArraySetAsSeries(RSI,true); ArraySetAsSeries(ATR,true);
   ArraySetAsSeries(MACDMain,true); ArraySetAsSeries(MACDSignal,true); ArraySetAsSeries(TrendMA,true);
   ArraySetAsSeries(StochMain,true); ArraySetAsSeries(StochSignal,true);
   ArraySetAsSeries(ADXMain,true); ArraySetAsSeries(ADXPlus,true); ArraySetAsSeries(ADXMinus,true);
   // Every slot starts without handles, so a failed init never releases stale ones.
   for(int i=0;i<AZT_MAX_SLOTS;i++) {
      TFFast[i]=INVALID_HANDLE; TFSlow[i]=INVALID_HANDLE; TFRSI[i]=INVALID_HANDLE; TFATR[i]=INVALID_HANDLE;
      TFMACD[i]=INVALID_HANDLE; TFTrendMA[i]=INVALID_HANDLE; TFStoch[i]=INVALID_HANDLE; TFADX[i]=INVALID_HANDLE;
   }
   for(int sx=0;sx<AZT_MAX_SYMBOLS;sx++) for(int i=0;i<4;i++) HTFHandles[sx][i]=INVALID_HANDLE;
   for(int sx=0;sx<SymCount;sx++) {
      string symbol=SymList[sx];
      for(int k=0;k<TFCount;k++) {
         int slot=sx*TFCount+k;
         ENUM_TIMEFRAMES tf=TFList[k];
         TFFast[slot]=iMA(symbol,tf,FastEMA,0,MODE_EMA,PRICE_CLOSE);
         TFSlow[slot]=iMA(symbol,tf,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
         TFRSI[slot]=iRSI(symbol,tf,RSIPeriod,PRICE_CLOSE); TFATR[slot]=iATR(symbol,tf,ATRPeriod);
         TFMACD[slot]=iMACD(symbol,tf,MACDFast,MACDSlow,MACDSignalPeriod,PRICE_CLOSE);
         TFTrendMA[slot]=iMA(symbol,tf,TrendMAPeriod,0,MODE_SMA,PRICE_CLOSE);
         TFStoch[slot]=iStochastic(symbol,tf,StochK,StochD,StochSlowing,MODE_SMA,STO_LOWHIGH);
         TFADX[slot]=iADX(symbol,tf,ADXPeriod);
         TFLastClosed[slot]=0; TFLastSignal[slot]=0; TFReady[slot]=false;
         TFStatus[slot]="Starting"; TFHistory[slot]="History analysis pending"; TFHistSignals[slot]=0;
         SlotHistTrades[slot]=0; SlotHistTP1[slot]=0; SlotHistExp[slot]=0; SlotHistAge[slot]=0;
         if(TFFast[slot]==INVALID_HANDLE || TFSlow[slot]==INVALID_HANDLE || TFRSI[slot]==INVALID_HANDLE || TFATR[slot]==INVALID_HANDLE ||
            TFMACD[slot]==INVALID_HANDLE || TFTrendMA[slot]==INVALID_HANDLE || TFStoch[slot]==INVALID_HANDLE || TFADX[slot]==INVALID_HANDLE) {
            Print("AZT: Cannot create indicators for ",symbol," ",TFName(tf),": ",GetLastError()); return INIT_FAILED;
         }
      }
      if(!MQLInfoInteger(MQL_TESTER)) {
         ENUM_TIMEFRAMES htf[2]={AIHigherTF1,AIHigherTF2};
         for(int i=0;i<2;i++) {
            HTFHandles[sx][i*2]=iMA(symbol,htf[i],FastEMA,0,MODE_EMA,PRICE_CLOSE);
            HTFHandles[sx][i*2+1]=iMA(symbol,htf[i],SlowEMA,0,MODE_EMA,PRICE_CLOSE);
         }
      }
   }
   Print("AZT: ",SymCount," symbol x ",TFCount," timeframe skanerlanadi: ",ScanList());
   TFIndex=-1; CurSlot=-1; SymIndex=-1; JournalSlot=-1; StartedAt=TimeLocal(); NextHeartbeat=0;
   SwitchSlot(0);
   Trade.SetExpertMagicNumber(MagicNumber); Trade.SetDeviationInPoints(SlippagePoints);
   Trade.SetAsyncMode(false);
   AZTTelegramInit();
   AZTAIInit();
   if(!MQLInfoInteger(MQL_TESTER)) {
      Button(Prefix+"TELEGRAM_TEST",25,"Telegram TEST (tugmali)");
      Button(Prefix+"AI_TEST",55,"AI TEST (Claude)");
      if(TradeMode!=AZT_SIGNALS_ONLY && !AZTTelegramReady())
         Print("AZT: WARNING - Telegram is not ready, so trades needing your approval cannot open.");
   }
   if(!EventSetTimer(2)) { Print("AZT: Cannot start timer"); return INIT_FAILED; }
   TradeStatus=TradeMode==AZT_SIGNALS_ONLY ? "Faqat signal: savdo o'chiq" : "Savdo: AI kelishuvi yoki sizning tasdig'ingiz bilan";
   Panel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ReleaseHandles();
   TFCount=0; SymCount=0; CurSlot=-1; SymIndex=-1;
   if(Prefix!="") ObjectsDeleteAll(0,Prefix);
   Comment("");
}

void OnTimer() {
   Scan();
   ProcessPending();
   ProcessTelegramTest();
   ManagePositions();
   ManagePendingOrders();
   ReportClosedPositions();
   ReflectNext();
   Heartbeat();
   AZTTelegramPump();
   Panel();
}

void OnTick() { Scan(); ManagePositions(); }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam) {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(sparam==Prefix+"TELEGRAM_TEST") {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RequestTelegramTest();
      Panel();
   }
   if(sparam==Prefix+"AI_TEST") {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RunAITest();
      Panel();
   }
}
