// Extra strategy families on top of AZT_Confluence: SMC/ICT liquidity and premium/discount,
// chart patterns, more Japanese candles, price-action structure, Stochastic/ADX, tick volume
// and the volatility regime. Session, scalping and sniper (entry precision) live in StrictChecks.
// Causal: evaluating bar `shift` reads only bars >= shift (never bar 0).
// Forex has no real order flow in MT5: "volume" here is tick volume.
// Include after AZT_Confluence.mqh.
#ifndef AZT_STRATEGIES_MQH
#define AZT_STRATEGIES_MQH

void EvaluateStrategies(int shift, int side, double entry, int &score, string &factors) {
   double atr=ArrayAt(ATR,shift);
   int size=ArraySize(Rates);
   if(atr==EMPTY_VALUE || atr<=0 || shift<1 || shift+3>=size) return;

   if(UseSMCExtras) {
      // Liquidity sweep: price ran the last swing low (BUY) / high (SELL), then closed back inside.
      int k=LastPivot(shift,side!=1);
      if(k>=0) {
         double level=side==1 ? Rates[k].low : Rates[k].high;
         bool swept=false;
         for(int i=shift;i<shift+SweepBars && i<k && !swept;i++)
            swept=side==1 ? Rates[i].low<level : Rates[i].high>level;
         bool back=side==1 ? Rates[shift].close>level : Rates[shift].close<level;
         if(swept && back)
            AddFactor(factors,score,1,(side==1 ? "Sell-side" : "Buy-side")+string(" likvidlik yig'ildi (sweep ")+Price(level)+")",AZT_F_SMC);
      }
      // Premium / discount of the recent dealing range: buy cheap, sell expensive.
      int last=MathMin(size-1,shift+PDRangeBars);
      if(last>shift+5) {
         double hi=Rates[shift+1].high, lo=Rates[shift+1].low;
         for(int i=shift+1;i<=last;i++) { hi=MathMax(hi,Rates[i].high); lo=MathMin(lo,Rates[i].low); }
         if(hi>lo) {
            double position=(entry-lo)/(hi-lo);
            if(side==1 ? position<0.5 : position>0.5)
               AddFactor(factors,score,1,(side==1 ? "Discount" : "Premium")+string(" zonasi (diapazonning ")+
                  DoubleToString(position*100,0)+"%)",AZT_F_SMC);
         }
      }
   }

   if(UseChartPatterns && shift+RangeBars<size) {
      // Flag / rectangle: a tight consolidation broken in the signal direction.
      double hi=Rates[shift+1].high, lo=Rates[shift+1].low;
      for(int i=shift+1;i<=shift+RangeBars;i++) { hi=MathMax(hi,Rates[i].high); lo=MathMin(lo,Rates[i].low); }
      if(hi-lo<=atr*RangeMaxATR && (side==1 ? Rates[shift].close>hi : Rates[shift].close<lo))
         AddFactor(factors,score,1,"Konsolidatsiyadan chiqish ("+Price(lo)+"-"+Price(hi)+")",AZT_F_PATTERN);
   }

   if(UseCandlesExtra) {
      MqlRates c0=Rates[shift], c1=Rates[shift+1], c2=Rates[shift+2];
      double b0=c0.close-c0.open, b1=c1.close-c1.open, b2=c2.close-c2.open;
      bool star=side*b2<0 && MathAbs(b2)>=0.6*atr && MathAbs(b1)<=0.35*MathAbs(b2) && side*b0>0 &&
                side*(c0.close-(c2.open+c2.close)/2.0)>0;
      bool inside=c1.high<c2.high && c1.low>c2.low && (side==1 ? c0.close>c1.high : c0.close<c1.low);
      bool soldiers=side*b0>0 && side*b1>0 && side*b2>0 && side*(c0.close-c1.close)>0 && side*(c1.close-c2.close)>0 &&
                    MathAbs(b0)>=0.3*atr && MathAbs(b1)>=0.3*atr && MathAbs(b2)>=0.3*atr;
      if(star) AddFactor(factors,score,1,side==1 ? "Morning star" : "Evening star",AZT_F_CANDLE);
      else if(inside) AddFactor(factors,score,1,"Inside bar breakout",AZT_F_CANDLE);
      else if(soldiers) AddFactor(factors,score,1,side==1 ? "Three white soldiers" : "Three black crows",AZT_F_CANDLE);
   }

   if(UsePriceAction) {
      int h1=LastPivot(shift,true), h2=h1>=0 ? LastPivot(shift,true,h1+1) : -1;
      int l1=LastPivot(shift,false), l2=l1>=0 ? LastPivot(shift,false,l1+1) : -1;
      if(h1>=0 && h2>=0 && l1>=0 && l2>=0) {
         int trend=(Rates[h1].high>Rates[h2].high && Rates[l1].low>Rates[l2].low) ? 1 :
                   (Rates[h1].high<Rates[h2].high && Rates[l1].low<Rates[l2].low) ? -1 : 0;
         if(trend!=0)
            AddFactor(factors,score,trend*side,trend==1 ? "Price action: HH/HL (o'suvchi tuzilma)" : "Price action: LH/LL (tushuvchi tuzilma)",AZT_F_PA);
      }
   }

   if(UseStochastic) {
      double k=ArrayAt(StochMain,shift), d=ArrayAt(StochSignal,shift);
      if(k!=EMPTY_VALUE && d!=EMPTY_VALUE) {
         // Mirrored for SELL so one rule covers both sides.
         double kk=side==1 ? k : 100-k, dd=side==1 ? d : 100-d;
         int vote=kk>=90 ? -1 : (kk>dd && kk<80) ? 1 : 0;
         AddFactor(factors,score,vote,"Stochastic "+DoubleToString(k,1)+"/"+DoubleToString(d,1)+
            (vote<0 ? (side==1 ? " (overbought)" : " (oversold)") : ""),AZT_F_IND);
      }
   }

   if(UseADX) {
      double adx=ArrayAt(ADXMain,shift), plus=ArrayAt(ADXPlus,shift), minus=ArrayAt(ADXMinus,shift);
      if(adx!=EMPTY_VALUE && plus!=EMPTY_VALUE && minus!=EMPTY_VALUE) {
         int vote=adx<MinADX ? 0 : (plus>minus ? 1 : -1)*side;
         AddFactor(factors,score,vote,"ADX "+DoubleToString(adx,1)+" (+DI "+DoubleToString(plus,1)+" / -DI "+
            DoubleToString(minus,1)+")"+(adx<MinADX ? " — trend kuchsiz" : ""),AZT_F_IND);
      }
   }

   if(UseVolume && shift+VolumeAvgBars<size) {
      double average=0;
      for(int i=shift+1;i<=shift+VolumeAvgBars;i++) average+=(double)Rates[i].tick_volume;
      average/=VolumeAvgBars;
      if(average>0) {
         double ratio=(double)Rates[shift].tick_volume/average;
         if(ratio>=VolumeSpike)
            AddFactor(factors,score,1,"Hajm o'rtachadan "+DoubleToString(ratio,1)+"x yuqori (tick volume)",AZT_F_VOLUME);
         else if(ratio<0.5)
            AddFactor(factors,score,0,"Hajm past ("+DoubleToString(ratio,1)+"x)",AZT_F_VOLUME);
      }
   }

   if(UseVolatilityFilter) {
      // Volatility regime: news spikes and dead markets both stop out tight setups.
      int n=0; double sum=0;
      for(int i=shift+1;i<=shift+VolatilityBars && i<ArraySize(ATR);i++) {
         double a=ArrayAt(ATR,i);
         if(a==EMPTY_VALUE || a<=0) continue;
         sum+=a; n++;
      }
      if(n>=20) {
         double ratio=atr/(sum/n);
         if(ratio>2.5) AddFactor(factors,score,-1,"Volatillik juda yuqori (ATR "+DoubleToString(ratio,1)+"x): spike/yangilik xavfi",AZT_F_QUANT);
         else if(ratio<0.5) AddFactor(factors,score,-1,"Volatillik juda past (ATR "+DoubleToString(ratio,1)+"x): shovqin",AZT_F_QUANT);
         else AddInfo(factors,"Volatillik normal (ATR "+DoubleToString(ratio,1)+"x o'rtacha)",AZT_F_QUANT);
      }
   }
}

// ---- Asset classes ------------------------------------------------------------------
// The broker decides what exists; the class only changes session rules and wording.
#define AZT_ASSET_FOREX 0
#define AZT_ASSET_CRYPTO 1
#define AZT_ASSET_INDEX 2
#define AZT_ASSET_STOCK 3
#define AZT_ASSET_BOND 4
#define AZT_ASSET_COMMODITY 5
#define AZT_ASSET_OTHER 6

bool AZTHasAny(const string text, const string &words[]) {
   for(int i=0;i<ArraySize(words);i++) if(StringFind(text,words[i])>=0) return true;
   return false;
}

int AssetClass() {
   string text=SymbolInfoString(Sym,SYMBOL_PATH)+"|"+Sym;
   StringToLower(text);
   string crypto[]={"crypto","btc","eth","xrp","ltc","doge","bitcoin","usdt"};
   string commodity[]={"metal","xau","xag","xpt","xpd","gold","silver","oil","brent","wti","ngas","natgas","commod",
                       "energ","agri","copper","corn","wheat","soy","coffee","sugar","cocoa","cotton"};
   string bond[]={"bond","treasur","bund","gilt","t-note","tnote"};
   string stock[]={"stock","share","equit"};
   string index[]={"indic","index","us30","us500","us100","nas100","spx","sp500","dax","ger40","de40","uk100","ftse",
                   "jp225","nikkei","dow","stoxx","hk50","aus200","cac","fra40","vix"};
   string forex[]={"forex","fx","major","minor","exotic","cross"};
   if(AZTHasAny(text,crypto)) return AZT_ASSET_CRYPTO;
   if(AZTHasAny(text,commodity)) return AZT_ASSET_COMMODITY;
   if(AZTHasAny(text,bond)) return AZT_ASSET_BOND;
   if(AZTHasAny(text,stock)) return AZT_ASSET_STOCK;
   if(AZTHasAny(text,index)) return AZT_ASSET_INDEX;
   long mode=SymbolInfoInteger(Sym,SYMBOL_TRADE_CALC_MODE);
   if(mode==SYMBOL_CALC_MODE_FOREX || mode==SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE || AZTHasAny(text,forex)) return AZT_ASSET_FOREX;
   if(mode==SYMBOL_CALC_MODE_EXCH_STOCKS) return AZT_ASSET_STOCK;
   return AZT_ASSET_OTHER;
}

string AssetName(int asset) {
   return asset==AZT_ASSET_FOREX ? "💱 Forex" : asset==AZT_ASSET_CRYPTO ? "🪙 Kriptovalyuta" :
          asset==AZT_ASSET_INDEX ? "📈 Fond indeksi" : asset==AZT_ASSET_STOCK ? "🏢 Aksiya" :
          asset==AZT_ASSET_BOND ? "📜 Obligatsiya" : asset==AZT_ASSET_COMMODITY ? "🛢 Tovar / metall" : "📊 Boshqa aktiv";
}

// GMT hour when the candle that opened at `opened` closed. Broker offset is taken from the live clock.
int CloseHourGMT(datetime opened) {
   long offset=(long)(TimeCurrent()-TimeGMT());
   offset=(long)MathRound(offset/1800.0)*1800;
   MqlDateTime t;
   TimeToStruct((datetime)((long)opened+PeriodSeconds(TF)-offset),t);
   return t.hour;
}

// Gates applied after the classic checks (live and history replay alike):
// session for scalping timeframes, spread cost, sniper entry precision, family count.
bool StrategyGates(int shift, LocalSignal &signal, string &reason) {
   bool scalping=PeriodSeconds(TF)<=PeriodSeconds(PERIOD_M15);
   int hour=CloseHourGMT(Rates[shift].time);
   bool active=SessionStartGMT<SessionEndGMT ? (hour>=SessionStartGMT && hour<SessionEndGMT)
                                             : (hour>=SessionStartGMT || hour<SessionEndGMT);
   // London/New York liquidity matters for FX and metals; crypto trades 24/7 and exchange
   // instruments (stocks, indices, bonds) only print candles while their own market is open.
   int asset=AssetClass();
   bool sessionBound=asset==AZT_ASSET_FOREX || asset==AZT_ASSET_COMMODITY || asset==AZT_ASSET_OTHER;
   if(!sessionBound) active=true;
   if(UseSessionFilter && scalping && !active) {
      reason="Skipped "+signal.setup+": London/New York sessiyasidan tashqari (GMT "+(string)hour+":00)"; return false;
   }
   if(active) AddInfo(signal.factors,sessionBound ? "Sessiya: London/New York (GMT "+(string)hour+":00)" : "Sessiya: bozor ochiq",AZT_F_SESSION);

   double risk=MathAbs(signal.entry-signal.sl);
   double spread=(double)SymbolInfoInteger(Sym,SYMBOL_SPREAD)*SymPoint;
   if(risk>0 && spread>risk*MaxSpreadRiskPercent/100.0) {
      reason="Skipped "+signal.setup+": spread SL masofasining "+DoubleToString(100.0*spread/risk,0)+"%i (ruxsat "+
             DoubleToString(MaxSpreadRiskPercent,0)+"%)"; return false;
   }
   if(scalping && risk>0)
      AddInfo(signal.factors,"Skalping: spread SL ning "+DoubleToString(100.0*spread/risk,1)+"%i",AZT_F_SCALP);

   if(signal.zoneTop>0 && signal.zoneBottom>0 && signal.atr>0) {
      double away=signal.side==1 ? signal.entry-signal.zoneTop : signal.zoneBottom-signal.entry;
      away=MathMax(0,away);
      if(away>SniperMaxZoneATR*signal.atr) {
         reason="Skipped "+signal.setup+": narx zonadan "+DoubleToString(away/signal.atr,2)+" ATR uzoq (quvib kirilmaydi)"; return false;
      }
      AddInfo(signal.factors,"Snayper kirish: zonadan "+DoubleToString(away/signal.atr,2)+" ATR",AZT_F_SNIPER);
   }

   string names;
   signal.families=FamilyCount(names);
   signal.factors+="\n🧠 Strategiya oilalari: "+(string)signal.families+"/"+(string)AZT_FAMILIES+(names!="" ? " ("+names+")" : "");
   if(signal.families<MinFamilies) {
      reason="Skipped "+signal.setup+": faqat "+(string)signal.families+"/"+(string)AZT_FAMILIES+
             " strategiya oilasi tasdiqladi (kerak "+(string)MinFamilies+")"; return false;
   }
   return true;
}
#endif
