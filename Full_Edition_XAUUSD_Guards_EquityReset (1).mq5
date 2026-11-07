//+------------------------------------------------------------------+
//| Full_Edition_XAUUSD.mq5                            |
//| Full Edition: cent balance, random/alternating, recovery. |
//| Risk warning: recovery progression can exhaust any account.    |
//+------------------------------------------------------------------+
#property strict
#property version "5.10"
#property description "Full Edition 5.10: original recovery + entry guards + configurable equity DD reset."
#property description "WARNING: martingale-like recovery can lose the entire balance. DEMO only until verified."
#include <Trade/Trade.mqh>

enum ENUM_DIRECTION_MODE
{
   RANDOM_BUY_SELL = 0,       // Случайно BUY или SELL
   ALTERNATE_BUY_SELL = 1     // Строго BUY, SELL, BUY, SELL
};

input group "1. Торговая логика"
input double GoldMoveUSD = 10.0;                    // Движение золота ($), SL = TP
input ENUM_DIRECTION_MODE DirectionMode = RANDOM_BUY_SELL; // Рандом / строго BUY-SELL
input double BalancePer001Lot = 100000.0;           // Баланс на каждые 0.01 лота

input group "2. Время (сохранено из предыдущей версии)"
input bool UseKyrgyzSession = true;                 // Входы 16:00-00:00 КР; сервер LiteFinance

input group "3. Детектор аномальных движений"
input bool UseAnomalyFilter = true;                 // Включить детектор размаха цены
input double MaxRange10SecUSD = 6.0;                // Блок при размахе за 10 секунд от ($)
input double MaxRange60SecUSD = 12.0;               // Блок при размахе за 60 секунд от ($)

input group "4. Лимит частоты новых входов"
input bool LimitOneEntryPer60Seconds = true;        // Не более одной новой группы за 60 секунд

input group "5. Фильтр расширения спреда"
input bool UseSpreadFilter = true;                  // Запрет входа при дорогом спреде
input double MaxSpreadUSD = 0.30;                   // Максимум Ask-Bid ($ движения золота)

input group "6. Важные новости USD и подписи на графике"
input bool UseHighImpactNewsFilter = true;          // Только HIGH: -30 минут / +3 часа
input string NewsCsvFile = "FullEdition_USD_High.csv"; // Файл новостей для тестера, Common\\Files

input group "7. Сброс при просадке equity"
input double EquityResetDDPercent = 10.0;           // Просадка от максимума equity (%), 0 = выкл

const ulong MAGIC=2026103106;
const double LOT_PER_STEP=0.01;
CTrade trade;
datetime last_attempt_time=0;
datetime last_warning_time=0;
bool cached_ready=false;
double cached_debt=0.0;
double cached_cost_per_lot=0.0;
bool cached_is_buy=true;
int cached_finished=0;
ulong group_sequence=0;
string key_group="";

// Equity reset is completely separate from the existing entry filters and recovery.
// All values must survive a regular MT5 restart (terminal Global Variables).
string fe_reset_key_peak="",fe_reset_key_pending="",fe_reset_key_time="";
string fe_reset_key_deal="",fe_reset_key_first="";
double fe_reset_equity_peak=0.0;
bool fe_reset_pending=false;
bool fe_reset_first_lot=false;
long fe_reset_cutoff_msc=0;
ulong fe_reset_cutoff_deal=0;

// Treat displayed account balance as CENTS, without changing broker account type.
// 100,000 -> 0.01; 200,000 -> 0.02; 1,000,000 -> 0.10.
// BALANCE is used, not equity. Never use rounding-to-nearest for tiers.
double CentBaseLot(const double balance)
{
   if(!MathIsValidNumber(balance) || balance<=0.0 || BalancePer001Lot<=0.0)
      return 0.0;
   double raw=MathFloor(balance/BalancePer001Lot+1e-10);
   if(raw<1.0) raw=1.0;
   return NormalizeDouble(LOT_PER_STEP*raw,8);
}

void WarningOnce(const string message)
{
   datetime t=TimeCurrent();
   if(last_warning_time!=0 && t-last_warning_time<60) return;
   last_warning_time=t;
   Print(message);
}

double RoundVolumeUp(const double x)
{
   const double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   const double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0 || vmin<=0.0 || !MathIsValidNumber(x)) return 0.0;
   double steps=MathCeil((MathMax(x,vmin)-vmin)/step-1e-9);
   return NormalizeDouble(vmin+steps*step,8);
}

double MaxOrderVolume()
{
   const double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   const double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   const double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0 || vmax<vmin || step<=0) return 0.0;
   double steps=MathFloor((vmax-vmin)/step+1e-9);
   return NormalizeDouble(vmin+steps*step,8);
}

double RoundPrice(const double price)
{
   const double ticksize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ticksize<=0) return NormalizeDouble(price,_Digits);
   return NormalizeDouble(MathRound(price/ticksize)*ticksize,_Digits);
}

bool IsSymbolBusy()
{
   const bool netting=(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(netting || (ulong)PositionGetInteger(POSITION_MAGIC)==MAGIC) return true;
   }
   for(int i=OrdersTotal()-1;i>=0;--i)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC)==MAGIC) return true;
   }
   return false;
}

struct PositionRecord
{
   ulong id;
   string group_tag;
   double volume_in;
   double volume_out;
   double net;
   double fees;
   long close_msc;
};
struct GroupRecord
{
   string tag;
   double net;
   double fees;
   double volume;
   long close_msc;
   bool complete;
};

int FindPosition(PositionRecord &data[],const ulong id)
{
   int lo=0,hi=ArraySize(data)-1;
   while(lo<=hi)
   {
      int m=lo+(hi-lo)/2;
      if(data[m].id==id) return m;
      if(data[m].id<id) lo=m+1; else hi=m-1;
   }
   return -1;
}

// All parts of a split order carry the same "FE<group-sequence>" entry comment.
// The tag is obtained from the ENTRY deal (or its history order), not the exit
// deal, whose comment can be overwritten by the broker with SL/TP text.
string GroupTag(const ulong deal)
{
   string s=HistoryDealGetString(deal,DEAL_COMMENT);
   if(StringFind(s,"FE")==0) return s;
   ulong order_id=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
   if(order_id!=0)
   {
      s=HistoryOrderGetString(order_id,ORDER_COMMENT);
      if(StringFind(s,"FE")==0) return s;
   }
   return "";
}

void SortPositionsByGroup(PositionRecord &a[],PositionRecord &tmp[],int left,int right)
{
   if(right-left<=1) return;
   int mid=left+(right-left)/2;
   SortPositionsByGroup(a,tmp,left,mid);
   SortPositionsByGroup(a,tmp,mid,right);
   int i=left,j=mid;
   for(int k=left;k<right;++k)
   {
      if(j>=right || (i<mid && StringCompare(a[i].group_tag,a[j].group_tag)<=0))
         tmp[k]=a[i++];
      else tmp[k]=a[j++];
   }
   for(int k=left;k<right;++k) a[k]=tmp[k];
}
void SortGroupsByClose(GroupRecord &a[],GroupRecord &tmp[],int left,int right)
{
   if(right-left<=1) return;
   int mid=left+(right-left)/2;
   SortGroupsByClose(a,tmp,left,mid);
   SortGroupsByClose(a,tmp,mid,right);
   int i=left,j=mid;
   for(int k=left;k<right;++k)
   {
      if(j>=right || (i<mid &&
          (a[i].close_msc<a[j].close_msc ||
          (a[i].close_msc==a[j].close_msc && StringCompare(a[i].tag,a[j].tag)<=0))))
         tmp[k]=a[i++];
      else tmp[k]=a[j++];
   }
   for(int k=left;k<right;++k) a[k]=tmp[k];
}

// Reconstruct only FINISHED batches; a 250-lot batch = 100+100+50 is
// mathematically ONE trade. Net P/L must be summed BEFORE clipping debt to 0.
bool ReadDebt(double &debt,double &cost_per_lot,int &finished_batches)
{
   debt=0.0;
   cost_per_lot=0.0;
   finished_batches=0;
   if(!HistorySelect(0,TimeCurrent()+1))
   {
      Print("ERROR HistorySelect: ",GetLastError());
      return false;
   }

   // Gather this EA's entry position IDs, then deduplicate by sorted ID.
   ulong ids[];
   int deal_count=HistoryDealsTotal();
   for(int i=0;i<deal_count;++i)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=MAGIC) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) continue;
      if(fe_reset_cutoff_msc>0)
      {
         long opened_msc=HistoryDealGetInteger(d,DEAL_TIME_MSC);
         if(opened_msc<=0) opened_msc=HistoryDealGetInteger(d,DEAL_TIME)*1000;
         if(opened_msc<fe_reset_cutoff_msc ||
            (opened_msc==fe_reset_cutoff_msc && d<=fe_reset_cutoff_deal))
            continue; // A position opened before last equity-reset is no longer recovery debt.
      }
      ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      if(id==0) continue;
      int n=ArraySize(ids);
      if(ArrayResize(ids,n+1,128)!=n+1) return false;
      ids[n]=id;
   }
   ArraySort(ids);

   PositionRecord pos[];
   for(int i=0;i<ArraySize(ids);++i)
   {
      if(i>0 && ids[i]==ids[i-1]) continue;
      int n=ArraySize(pos);
      if(ArrayResize(pos,n+1,128)!=n+1) return false;
      pos[n].id=ids[i];
      pos[n].group_tag="";
      pos[n].volume_in=0;
      pos[n].volume_out=0;
      pos[n].net=0;
      pos[n].fees=0;
      pos[n].close_msc=0;
   }

   for(int i=0;i<deal_count;++i)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_TYPE dt=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
      if(dt!=DEAL_TYPE_BUY && dt!=DEAL_TYPE_SELL) continue;
      int p=FindPosition(pos,(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID));
      if(p<0) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      double vol=HistoryDealGetDouble(d,DEAL_VOLUME);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
      {
         pos[p].volume_in+=vol;
         if(pos[p].group_tag=="")
            pos[p].group_tag=GroupTag(d);
      }
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
      {
         pos[p].volume_out+=vol;
         long t=HistoryDealGetInteger(d,DEAL_TIME_MSC);
         if(t==0) t=HistoryDealGetInteger(d,DEAL_TIME)*1000;
         if(t>pos[p].close_msc) pos[p].close_msc=t;
      }
      pos[p].net+=HistoryDealGetDouble(d,DEAL_PROFIT)
                 +HistoryDealGetDouble(d,DEAL_SWAP)
                 +HistoryDealGetDouble(d,DEAL_COMMISSION)
                 +HistoryDealGetDouble(d,DEAL_FEE);
      pos[p].fees-=HistoryDealGetDouble(d,DEAL_COMMISSION)
                  +HistoryDealGetDouble(d,DEAL_FEE);
   }
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   int npos=ArraySize(pos);
   for(int i=0;i<npos;++i)
      if(pos[i].group_tag=="")
         pos[i].group_tag="P"+(string)pos[i].id; // safe fallback if broker stripped comment
   if(npos>1)
   {
      PositionRecord work[];
      if(ArrayResize(work,npos)!=npos) return false;
      SortPositionsByGroup(pos,work,0,npos);
   }
   GroupRecord groups[];
   for(int i=0;i<npos;)
   {
      int j=i;
      GroupRecord g;
      g.tag=pos[i].group_tag;
      g.net=0;g.fees=0;g.volume=0;g.close_msc=0;g.complete=true;
      while(j<npos && pos[j].group_tag==g.tag)
      {
         if(pos[j].volume_in<=0 || pos[j].close_msc==0 ||
            pos[j].volume_out+step*0.0001<pos[j].volume_in)
            g.complete=false;
         g.net+=pos[j].net;
         g.fees+=pos[j].fees;
         g.volume+=pos[j].volume_in;
         if(pos[j].close_msc>g.close_msc) g.close_msc=pos[j].close_msc;
         ++j;
      }
      int ng=ArraySize(groups);
      if(ArrayResize(groups,ng+1,128)!=ng+1) return false;
      groups[ng]=g;
      i=j;
   }
   int ng=ArraySize(groups);
   if(ng>1)
   {
      GroupRecord work[];
      if(ArrayResize(work,ng)!=ng) return false;
      SortGroupsByClose(groups,work,0,ng);
   }
   double fee_sum=0.0,vol_sum=0.0;
   for(int i=0;i<ng;++i)
   {
      // Called only while flat: an unfinished position in history means
      // its exit transaction has not arrived yet. Do not reuse stale debt.
      if(!groups[i].complete || groups[i].close_msc<=0) return false;
      debt=MathMax(0.0,debt-groups[i].net);
      fee_sum+=MathMax(0.0,groups[i].fees);
      vol_sum+=groups[i].volume;
      ++finished_batches;
   }
   if(vol_sum>0.0) cost_per_lot=fee_sum/vol_sum;
   return true;
}

bool NextDirectionIsBuy(bool &is_buy)
{
   if(DirectionMode==RANDOM_BUY_SELL)
   {
      is_buy=(MathRand()%2==0);
      return true;
   }
   // HistorySelect was executed by ReadDebt. Multi-leg orders all have
   // the SAME direction, so the next batch always takes the opposite side.
   bool found=false;
   long last_time=-1;
   ulong last_ticket=0;
   ENUM_DEAL_TYPE last_type=DEAL_TYPE_SELL;
   int n=HistoryDealsTotal();
   for(int i=0;i<n;++i)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0 || (ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=MAGIC ||
         HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_IN && e!=DEAL_ENTRY_INOUT) continue;
      ENUM_DEAL_TYPE t=(ENUM_DEAL_TYPE)HistoryDealGetInteger(d,DEAL_TYPE);
      if(t!=DEAL_TYPE_BUY && t!=DEAL_TYPE_SELL) continue;
      long tm=HistoryDealGetInteger(d,DEAL_TIME_MSC);
      if(tm==0) tm=HistoryDealGetInteger(d,DEAL_TIME)*1000;
      if(!found || tm>last_time || (tm==last_time && d>last_ticket))
      {
         found=true;last_time=tm;last_ticket=d;last_type=t;
      }
   }
   is_buy=(!found || last_type==DEAL_TYPE_SELL);
   return true;
}

// Broker's max-lot applies PER ORDER. Use the largest step-aligned chunk,
// then a legal remainder. SYMBOL_VOLUME_LIMIT may additionally constrain
// combined volume in one direction; split orders cannot override that.
bool BatchMargin(const ENUM_ORDER_TYPE side,const double volume,
                 const double quote,double &margin,int &parts)
{
   margin=0.0;parts=0;
   const double chunk=MaxOrderVolume();
   const double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(chunk<=0 || step<=0 || volume<=0) return false;
   // Volume is already step-aligned. Avoid thousands of redundant margin calls.
   long full=(long)MathFloor(volume/chunk+1e-10);
   double rest=NormalizeDouble(volume-(double)full*chunk,8);
   if(rest>0 && rest<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)-1e-8)
   {
      if(full==0) return false;
      full--;
      rest=NormalizeDouble(rest+chunk,8);
      // In this exceptional volume-step case, we cannot form a legal remainder.
      if(rest>chunk+1e-8) return false;
   }
   double each=0.0;
   if(full>0)
   {
      if(!OrderCalcMargin(side,_Symbol,chunk,quote,each)) return false;
      margin+=(double)full*each;
   }
   if(rest>1e-8)
   {
      if(!OrderCalcMargin(side,_Symbol,rest,quote,each)) return false;
      margin+=each;
   }
   parts=(int)full+(rest>1e-8 ? 1 : 0);
   return parts>0;
}

// ==================== ENTRY GUARDS v5.00 ==========================
// All guards restrict NEW exposure only. Broker SL/TP and fallback exits
// continue regardless of session, spread, volatility, or news.
// One split batch is one trading decision; its component orders are not
// separate signals. No loss-counter reset, no SL cooldown, no hedge.
const int ENTRY_INTERVAL_SECONDS=60;
const int NEWS_BEFORE_SECONDS=30*60;
const int NEWS_AFTER_SECONDS=3*60*60;
const int NEWS_REFRESH_SECONDS=60;
const int NEWS_MAX_STALE_SECONDS=5*60;

struct FENews
{
   datetime when;
   ulong event_id;
   int time_mode;
   string title;
};
FENews fe_news[];
bool fe_seen_open=false;
bool fe_tester=false;
bool fe_visual=false;
bool fe_news_ready=false;
datetime fe_news_from=0,fe_news_to=0,fe_news_ok_at=0;
datetime fe_news_try_at=0,fe_draw_at=0,fe_panel_at=0;
string fe_news_status="Новости ещё не загружены";
string fe_entry_status="Инициализация";
string fe_entry_key="";
string fe_news_prefix="";
long fe_last_entry_msc=0;
double fe_range10=0.0,fe_range60=0.0;
MqlTick fe_recent_ticks[];

int FELastSunday(const int year,const int month)
{
   MqlDateTime d; ZeroMemory(d);
   d.year=year; d.mon=month; d.day=31;
   MqlDateTime w;
   TimeToStruct(StructToTime(d),w);
   return 31-w.day_of_week;
}

// LiteFinance: last Sunday March -> last Sunday October, UTC+3;
// otherwise UTC+2. Europe switches at 01:00 UTC. No TimeGMT() in tester.
int FEOffsetAtUTC(const datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d);
   MqlDateTime b; ZeroMemory(b);
   b.year=d.year; b.mon=3; b.day=FELastSunday(d.year,3); b.hour=1;
   datetime start=StructToTime(b);
   b.mon=10; b.day=FELastSunday(d.year,10);
   datetime finish=StructToTime(b);
   return (utc>=start && utc<finish)?3:2;
}

int FEOffsetAtServer(const datetime server_time)
{
   // The repeated autumn hour occurs during the market weekend. Choose
   // winter in its ambiguous part; the entry window is 16:00-00:00 KG.
   datetime utc=server_time-2*3600;
   if(FEOffsetAtUTC(utc)==3) return 3;
   return 2;
}

bool FESessionAllows(const datetime server_time)
{
   if(!UseKyrgyzSession) return true;
   datetime local=server_time+(6-FEOffsetAtServer(server_time))*3600;
   MqlDateTime d; TimeToStruct(local,d);
   return d.hour>=16; // 16:00 inclusive; next midnight exclusive.
}

long FETickMsc(const MqlTick &t)
{
   return t.time_msc>0?t.time_msc:(long)t.time*1000;
}

bool FEValidQuote(const MqlTick &t)
{
   return MathIsValidNumber(t.bid) && MathIsValidNumber(t.ask) &&
          t.bid>0.0 && t.ask>=t.bid && FETickMsc(t)>0;
}

// FE_AUDIT_BEGIN
// Diagnostics only; no signal, order, price, lot or filter state is changed.
ulong fe_audit_session=0,fe_audit_news=0,fe_audit_spread=0,fe_audit_frequency=0,fe_audit_anomaly=0,fe_audit_data=0;
void FEAuditReject(const string kind,const string why,ulong &counter)
{
   counter++;
   if(counter==1) Print("FE_GUARD_FIRST kind=",kind," time=",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)," reason=",why);
}

// FE_AUDIT_END
void FESetStatus(const string s)
{
// FE_AUDIT_BEGIN
   if(fe_tester)
   {
      if(StringFind(s,"Вне окна")==0) FEAuditReject("session",s,fe_audit_session);
      else if(StringFind(s,"НОВОСТИ:")==0) FEAuditReject("news",s,fe_audit_news);
      else if(StringFind(s,"СПРЕД")==0) FEAuditReject("spread",s,fe_audit_spread);
      else if(StringFind(s,"ЛИМИТ ВХОДОВ")==0) FEAuditReject("frequency",s,fe_audit_frequency);
      else if(StringFind(s,"АНОМАЛИЯ:")==0) FEAuditReject("anomaly",s,fe_audit_anomaly);
      else if(StringFind(s,"Нет надёжных данных")==0 || StringFind(s,"Нет полного ответа тиков")==0 || StringFind(s,"Некорректный Bid/Ask")==0) FEAuditReject("data",s,fe_audit_data);
   }

// FE_AUDIT_END
   fe_entry_status=s;
}

void FEPanel(const bool force=false)
{
   if(!fe_visual) return;
   datetime now=TimeCurrent();
   if(!force && now==fe_panel_at) return;
   fe_panel_at=now;
   MqlTick q; double spread=0.0;
   if(SymbolInfoTick(_Symbol,q) && FEValidQuote(q)) spread=q.ask-q.bid;
   Comment("FULL EDITION 5.00\nНовые входы: ",fe_entry_status,
           "\nСпред $",DoubleToString(spread,2),
           " | Размах 10с $",DoubleToString(fe_range10,2),
           " / 60с $",DoubleToString(fe_range60,2),
           "\nНовости USD HIGH: ",fe_news_status,
           "\nОкно новостей: -30 минут / +3 часа. SL/TP сопровождаются всегда.",
           "\nВходы: ",UseKyrgyzSession?"16:00-00:00 Кыргызстан (LiteFinance)":"без часового фильтра",
           " | Recovery без лимита стопов; долг не сбрасывается.");
}

void FESortNews(FENews &a[])
{
   // A few hundred high-impact releases/year; insertion sort also allows
   // deterministic ordering of simultaneous events.
   for(int i=1;i<ArraySize(a);++i)
   {
      FENews v=a[i]; int j=i-1;
      while(j>=0 && (a[j].when>v.when ||
            (a[j].when==v.when && a[j].event_id>v.event_id)))
      { a[j+1]=a[j]; --j; }
      a[j+1]=v;
   }
   int out=0;
   for(int i=0;i<ArraySize(a);++i)
   {
      if(out>0 && a[i].when==a[out-1].when && a[i].event_id==a[out-1].event_id)
         continue; // revisions of one release are NOT several news events
      a[out++]=a[i];
   }
   ArrayResize(a,out);
}

bool FEAppendNews(FENews &a[],const datetime t,const ulong id,
                  const int mode,const string title)
{
   int n=ArraySize(a);
   if(ArrayResize(a,n+1,128)!=n+1) return false;
   a[n].when=t; a[n].event_id=id; a[n].time_mode=mode; a[n].title=title;
   return true;
}

bool FENewsError(const string reason)
{
   // Fail CLOSED, never silently trade as though a missing calendar meant
   // there were no important news. Existing positions still get exits.
   fe_news_ready=false;
   fe_news_status=reason;
   Print("FULL EDITION NEWS: ",reason,
         UseHighImpactNewsFilter?". Новые входы заблокированы.":". Фильтр выключен, входы не блокируются.");
   return false;
}

bool FEParseDate(const string text,datetime &out)
{
   if(StringLen(text)!=19) return false;
   out=StringToTime(text);
   return out>0 && TimeToString(out,TIME_DATE|TIME_SECONDS)==text;
}

bool FELoadNewsFile()
{
   ResetLastError();
   int h=FileOpen(NewsCsvFile,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,0,CP_UTF8);
   if(h==INVALID_HANDLE)
      return FENewsError("НЕТ CSV "+NewsCsvFile+" в Common\\Files; запусти Export_FullEdition_News");
   FENews temp[];
   datetime from=0,to=0;
   string server="",basis="";
   bool signature=false,complete=false,bad=false;
   int expected=-1,rows=0,line_no=0;
   while(!FileIsEnding(h))
   {
      string line=FileReadString(h); ++line_no;
      StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line)>0 && StringGetCharacter(line,0)==0xFEFF)
         line=StringSubstr(line,1);
      if(line=="") continue;
      string f[]; int n=StringSplit(line,';',f);
      if(n<=0) continue;
      if(f[0]=="#FE_NEWS_V1") { signature=true; continue; }
      if(f[0]=="#server" && n==2) { server=f[1]; continue; }
      if(f[0]=="#basis" && n==2) { basis=f[1]; continue; }
      if(f[0]=="#coverage_from" && n==2)
      { if(!FEParseDate(f[1],from)) bad=true; continue; }
      if(f[0]=="#coverage_to" && n==2)
      { if(!FEParseDate(f[1],to)) bad=true; continue; }
      if(f[0]=="#count" && n==2) { expected=(int)StringToInteger(f[1]); continue; }
      if(f[0]=="#complete" && n==2) { complete=(f[1]=="1"); continue; }
      if(StringFind(f[0],"#")==0 || f[0]=="time") continue;
      if(n!=6) { bad=true; break; }
      datetime when=0;
      if(!FEParseDate(f[0],when)) { bad=true; break; }
      // Format: time;currency;importance;event_id;time_mode;name
      if(f[1]!="USD" || f[2]!="3" || f[5]=="") { bad=true; break; }
      long eid=StringToInteger(f[3]);
      int tm=(int)StringToInteger(f[4]);
      if(eid<=0 || tm<0 || tm>3) { bad=true; break; }
      if(!FEAppendNews(temp,when,(ulong)eid,tm,f[5])) { bad=true; break; }
      ++rows;
   }
   FileClose(h);
   if(bad || !signature || !complete || expected<0 || rows!=expected ||
      from<=0 || to<=from || basis!="LITE_EU_SERVER")
      return FENewsError("CSV повреждён/неполон (строка "+(string)line_no+"); повтори экспорт");
   if(server!=AccountInfoString(ACCOUNT_SERVER))
      return FENewsError("CSV от другого сервера: "+server+"; нужен экспорт на текущем счёте");
   for(int i=0;i<ArraySize(temp);++i)
      if(temp[i].when<from || temp[i].when>to)
         return FENewsError("CSV содержит событие вне заявленного периода");
   FESortNews(temp);
   int total=ArraySize(temp);
   if(ArrayResize(fe_news,total)!=total) return FENewsError("Недостаточно памяти для календаря");
   for(int i=0;i<total;++i) fe_news[i]=temp[i];
   fe_news_from=from; fe_news_to=to;
   fe_news_ready=true; fe_news_ok_at=TimeCurrent();
   fe_news_status="CSV, событий "+(string)total+"; "+TimeToString(from,TIME_DATE)+" - "+TimeToString(to,TIME_DATE);
   fe_draw_at=0;
   Print("FULL EDITION NEWS: ",fe_news_status,"; ",server);
   return true;
}

bool FELoadLiveNews()
{
   datetime now=TimeTradeServer();
   if(now<=0) now=TimeCurrent();
   MqlCalendarValue values[];
   // Live query already uses SERVER time. In the tester this API is NEVER called.
   datetime left=now-7*86400,right=now+7*86400;
   ResetLastError();
   int n=CalendarValueHistory(values,left,right,"","USD");
   int err=GetLastError();
   if(n<0 || err!=0)
      return FENewsError("Календарь MT5 недоступен, ошибка "+(string)err);
   // A whole fortnight with zero USD records is suspicious: do not accept
   // a disabled/empty provider as a reliable calendar.
   if(n==0) return FENewsError("Пустой календарь USD за 14 дней; проверь календарь MT5");
   FENews temp[];
   for(int i=0;i<n;++i)
   {
      MqlCalendarEvent e;
      ResetLastError();
      if(!CalendarEventById(values[i].event_id,e))
         return FENewsError("Нет описания события "+(string)values[i].event_id);
      if(e.importance!=CALENDAR_IMPORTANCE_HIGH) continue;
      if(values[i].time<=0 || e.name=="")
         return FENewsError("Неполная дата/название важного события USD");
      if(!FEAppendNews(temp,values[i].time,e.id,(int)e.time_mode,e.name))
         return FENewsError("Недостаточно памяти для календаря");
   }
   FESortNews(temp);
   int size=ArraySize(temp);
   if(ArrayResize(fe_news,size)!=size) return FENewsError("Недостаточно памяти");
   for(int i=0;i<size;++i) fe_news[i]=temp[i];
   fe_news_from=left; fe_news_to=right;
   fe_news_ready=true; fe_news_ok_at=now;
   fe_news_status="Календарь MT5, важных событий "+(string)size;
   fe_draw_at=0;
   return true;
}

void FERefreshNews(const bool force=false)
{
   datetime now=TimeCurrent();
   if(!force && fe_news_try_at>0 && now>=fe_news_try_at &&
      now-fe_news_try_at<NEWS_REFRESH_SECONDS) return;
   // A valid historical file is static throughout a test. Missing files
   // are retried, so copying an exported file resolves a blocked start.
   if(fe_tester && fe_news_ready && !force) return;
   fe_news_try_at=now;
   if(fe_tester) FELoadNewsFile(); else FELoadLiveNews();
}

void FENewsWindow(const FENews &e,datetime &from,datetime &until)
{
   if(e.time_mode==(int)CALENDAR_TIMEMODE_DATETIME)
   {
      from=e.when-NEWS_BEFORE_SECONDS;
      until=e.when+NEWS_AFTER_SECONDS;
      return;
   }
   // Important event with an unspecified time: cannot promise a 30-minute
   // warning. Conservatively block its calendar day and +3h afterwards.
   MqlDateTime d; TimeToStruct(e.when,d); d.hour=0; d.min=0; d.sec=0;
   datetime day=StructToTime(d);
   from=day-NEWS_BEFORE_SECONDS;
   until=day+86400+NEWS_AFTER_SECONDS;
}

bool FENewsAllows(const datetime now,string &why)
{
   if(!UseHighImpactNewsFilter) return true;
   if(!fe_news_ready) { why="Нет надёжных данных новостей: "+fe_news_status; return false; }
   if(now-NEWS_AFTER_SECONDS<fe_news_from || now+NEWS_BEFORE_SECONDS>fe_news_to)
   { why="Дата вне покрытия CSV/календаря; нужен экспорт за этот период"; return false; }
   if(!fe_tester && (now<fe_news_ok_at-60 || now-fe_news_ok_at>NEWS_MAX_STALE_SECONDS))
   { why="Данные календаря устарели; новые входы закрыты"; return false; }
   datetime blocked_until=0;
   string names="";
   for(int i=0;i<ArraySize(fe_news);++i)
   {
      datetime begin,end;
      FENewsWindow(fe_news[i],begin,end);
      if(now>=begin && now<end)
      {
         if(end>blocked_until) blocked_until=end;
         if(names!="") names+=" | ";
         names+=fe_news[i].title;
      }
   }
   if(blocked_until>0)
   {
      why="НОВОСТИ: "+names+"; запрет до "+TimeToString(blocked_until,TIME_DATE|TIME_MINUTES)+" серв.";
      return false;
   }
   return true;
}

void FEDrawNews(const bool force=false)
{
   if(!fe_visual || fe_news_prefix=="") return;
   datetime now=TimeCurrent();
   if(!force && fe_draw_at>0 && now>=fe_draw_at && now-fe_draw_at<60) return;
   fe_draw_at=now;
   double low=ChartGetDouble(0,CHART_PRICE_MIN,0);
   double high=ChartGetDouble(0,CHART_PRICE_MAX,0);
   if(high<=low) return;
   long first=ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR,0);
   long count=ChartGetInteger(0,CHART_VISIBLE_BARS,0);
   datetime left=iTime(_Symbol,_Period,(int)first);
   int r=(int)MathMax(0,first-count+1);
   datetime right=iTime(_Symbol,_Period,r);
   int seconds=PeriodSeconds(_Period); if(seconds<=0) seconds=60;
   if(left<=0) left=now-7*86400;
   if(right<=0) right=now;
   if(r==0) right+=seconds*(int)MathMax(8,count/3);
   ObjectsDeleteAll(0,fe_news_prefix,0,-1);
   int visible_label_row=0;
   for(int i=0;i<ArraySize(fe_news);++i)
   {
      FENews e=fe_news[i];
      if(e.when<left || e.when>right) continue;
      string name=fe_news_prefix+(string)e.event_id+"_"+(string)(long)e.when;
      string label=TimeToString(e.when,TIME_MINUTES)+" USD: "+e.title;
      if(e.time_mode!=(int)CALENDAR_TIMEMODE_DATETIME) label+=" [время не уточнено]";
      if(ObjectCreate(0,name,OBJ_VLINE,0,e.when,0.0))
      {
         ObjectSetInteger(0,name,OBJPROP_COLOR,clrCrimson);
         ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASH);
         ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
         ObjectSetInteger(0,name,OBJPROP_BACK,false);
         ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
         ObjectSetString(0,name,OBJPROP_TEXT,label);
         ObjectSetString(0,name,OBJPROP_TOOLTIP,label);
      }
      // Titles are horizontal at the chart top. Native text objects truncate
      // long strings, so preserve the full event name in separate short rows.
      string remaining=label;
      int line_index=0;
      while(StringLen(remaining)>0)
      {
         int length=StringLen(remaining),take=length;
         if(length>60)
         {
            int target=(int)MathMin(60,(length+1)/2);
            take=target;
            for(int k=target;k>0;--k)
               if(StringGetCharacter(remaining,k)==' ') { take=k; break; }
         }
         string piece=StringSubstr(remaining,0,take);
         remaining=StringSubstr(remaining,take);StringTrimLeft(remaining);
         datetime text_time=e.when;
         double y=high-(high-low)*(0.06+visible_label_row*0.025);
         int anchor_x=0,anchor_y=0;
         if(ChartTimePriceToXY(0,0,e.when,high,anchor_x,anchor_y))
         {
            int chart_width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
            int estimated_width=(int)MathCeil(StringLen(piece)*7.5)+20;
            int indent=(line_index==0?8:22);
            int label_x=(int)MathMax(8,MathMin(anchor_x+indent,chart_width-estimated_width-8));
            int label_y=28+visible_label_row*20;
            int subwindow=0; datetime placed_time=0; double placed_price=0;
            if(ChartXYToTimePrice(0,label_x,label_y,subwindow,placed_time,placed_price) && subwindow==0)
            { text_time=placed_time; y=placed_price; }
         }
         string text_name=name+"_TXT"+(string)line_index;
         if(ObjectCreate(0,text_name,OBJ_TEXT,0,text_time,y))
         {
            ObjectSetString(0,text_name,OBJPROP_TEXT,piece);
            ObjectSetString(0,text_name,OBJPROP_TOOLTIP,label);
            ObjectSetString(0,text_name,OBJPROP_FONT,"Arial");
            ObjectSetInteger(0,text_name,OBJPROP_FONTSIZE,10);
            ObjectSetInteger(0,text_name,OBJPROP_COLOR,clrCrimson);
            ObjectSetDouble(0,text_name,OBJPROP_ANGLE,0.0);
            ObjectSetInteger(0,text_name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
            ObjectSetInteger(0,text_name,OBJPROP_BACK,false);
            ObjectSetInteger(0,text_name,OBJPROP_SELECTABLE,false);
         }
         ++visible_label_row;++line_index;
      }
   }
   ChartRedraw(0);
}

bool FEAnomalyAllows(const MqlTick &tick,string &why)
{
   if(!UseAnomalyFilter) return true;
   long end=FETickMsc(tick);
   ResetLastError();
   int n=CopyTicksRange(_Symbol,fe_recent_ticks,COPY_TICKS_ALL,
                       (ulong)MathMax(0,end-60000),(ulong)end);
   int err=GetLastError();
   if(n<=0 || err!=0)
   {
      why="Нет полного ответа тиков для детектора, код "+(string)err;
      return false;
   }
   double mid=(tick.bid+tick.ask)*0.5;
   double lo10=mid,hi10=mid,lo60=mid,hi60=mid;
   for(int i=0;i<n;++i)
   {
      long t=FETickMsc(fe_recent_ticks[i]);
      if(t>end || t<end-60000) continue; // strictly NO future ticks
      if(!FEValidQuote(fe_recent_ticks[i]))
      {
         why="Некорректный Bid/Ask в последних 60с; вход запрещён";
         return false;
      }
      double p=(fe_recent_ticks[i].bid+fe_recent_ticks[i].ask)*0.5;
      lo60=MathMin(lo60,p); hi60=MathMax(hi60,p);
      if(t>=end-10000) { lo10=MathMin(lo10,p); hi10=MathMax(hi10,p); }
   }
   fe_range10=hi10-lo10; fe_range60=hi60-lo60;
   // High-low range, NOT start-to-end difference: detects out-and-back spikes.
   if(fe_range10>=MaxRange10SecUSD-1e-9 || fe_range60>=MaxRange60SecUSD-1e-9)
   {
      why="АНОМАЛИЯ: размах 10с $"+DoubleToString(fe_range10,2)+
          "; 60с $"+DoubleToString(fe_range60,2);
      return false;
   }
   return true;
}

void FERecordEntry(const long when)
{
   if(when>fe_last_entry_msc)
   {
      fe_last_entry_msc=when;
      if(!fe_tester) GlobalVariableSet(fe_entry_key,(double)when);
   }
}

bool FERestoreEntryState()
{
   fe_last_entry_msc=0;
   double saved=0.0;
   if(!fe_tester && GlobalVariableGet(fe_entry_key,saved) && saved>0)
      fe_last_entry_msc=(long)saved;
   if(!HistorySelect(0,TimeCurrent()+1)) return false;
   for(int i=0;i<HistoryDealsTotal();++i)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MAGIC) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_IN && e!=DEAL_ENTRY_INOUT) continue;
      long t=HistoryDealGetInteger(deal,DEAL_TIME_MSC);
      if(t<=0) t=HistoryDealGetInteger(deal,DEAL_TIME)*1000;
      if(t>fe_last_entry_msc) fe_last_entry_msc=t;
      string tag=GroupTag(deal);
      if(StringFind(tag,"FE")==0)
      {
         long seq=StringToInteger(StringSubstr(tag,2));
         if(seq>0 && (ulong)seq>group_sequence) group_sequence=(ulong)seq;
      }
   }
   GlobalVariableSet(key_group,(double)group_sequence);
   return true;
}

bool FEEntryAllows(const MqlTick &tick,const bool first_part,string &why)
{
   why="";
   if(!FEValidQuote(tick)) { why="Нет корректной котировки Bid/Ask"; return false; }
   datetime now=tick.time;
   if(!FESessionAllows(now)) { why="Вне окна 16:00-00:00 по Кыргызстану"; return false; }
   if(!FENewsAllows(now,why)) return false;
   if(UseSpreadFilter && tick.ask-tick.bid>MaxSpreadUSD+1e-9)
   { why="СПРЕД $"+DoubleToString(tick.ask-tick.bid,2)+" > $"+DoubleToString(MaxSpreadUSD,2); return false; }
   if(first_part && LimitOneEntryPer60Seconds && fe_last_entry_msc>0)
   {
      long elapsed=FETickMsc(tick)-fe_last_entry_msc;
      if(elapsed<ENTRY_INTERVAL_SECONDS*1000)
      {
         why="ЛИМИТ ВХОДОВ: после последнего входа ещё не прошло 60 секунд";
         return false;
      }
   }
   if(!FEAnomalyAllows(tick,why)) return false;
   return true;
}

bool FEInitGuards()
{
   if((UseAnomalyFilter && (!MathIsValidNumber(MaxRange10SecUSD) ||
       !MathIsValidNumber(MaxRange60SecUSD) || MaxRange10SecUSD<=0 || MaxRange60SecUSD<=0)) ||
      (UseSpreadFilter && (!MathIsValidNumber(MaxSpreadUSD) || MaxSpreadUSD<=0)))
   { Print("FULL EDITION: пороги фильтров должны быть положительными"); return false; }
   fe_tester=(bool)MQLInfoInteger(MQL_TESTER);
   fe_visual=!fe_tester || (bool)MQLInfoInteger(MQL_VISUAL_MODE);
   fe_entry_key=key_group+"_ENTRY";
   if(StringLen(fe_entry_key)>63) return false;
   fe_news_prefix="FE5_NEWS_"+(string)MAGIC+"_";
   if(fe_visual) ObjectsDeleteAll(0,fe_news_prefix,0,-1);
   if(!FERestoreEntryState())
   { Print("FULL EDITION: не удалось восстановить историю входов"); return false; }
   FERefreshNews(true);
   if(!fe_tester && !EventSetTimer(15))
   { Print("FULL EDITION: EventSetTimer failed ",GetLastError()); return false; }
   FESetStatus("Ожидание котировки / проверки фильтров");
   FEDrawNews(true); FEPanel(true);
   Print("FULL EDITION 5.00: no loss-count cap, no debt reset, no SL pause. ",
         "Entry guards: anomaly=",UseAnomalyFilter,"; 60sec=",LimitOneEntryPer60Seconds,
         "; spread=",UseSpreadFilter,"; USD HIGH news=",UseHighImpactNewsFilter,
         "; session KG 16-00=",UseKyrgyzSession);
   return true;
}

void OnTimer()
{
   // No new orders from the timer. Server-side exits are never paused.
   FERefreshNews(); FEDrawNews(); FEPanel();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_CHART_CHANGE) FEDrawNews(true);
}

void OnDeinit(const int reason)
{
// FE_AUDIT_BEGIN
   if(fe_tester) PrintFormat("FE_GUARD_COUNTS session=%I64u news=%I64u spread=%I64u frequency=%I64u anomaly=%I64u data=%I64u",fe_audit_session,fe_audit_news,fe_audit_spread,fe_audit_frequency,fe_audit_anomaly,fe_audit_data);

// FE_AUDIT_END
   EventKillTimer();
   // Leave historical markers visible in a finished visual test.
   if(!fe_tester && fe_visual && fe_news_prefix!="")
   { ObjectsDeleteAll(0,fe_news_prefix,0,-1); Comment(""); }
}
// ================== END ENTRY GUARDS ==============================

// ================== EQUITY RESET (one added mechanism) ==================
void FEResetStore()
{
   if(EquityResetDDPercent<=0.0) return;
   GlobalVariableSet(fe_reset_key_peak,fe_reset_equity_peak);
   GlobalVariableSet(fe_reset_key_pending,fe_reset_pending?1.0:0.0);
   GlobalVariableSet(fe_reset_key_time,(double)fe_reset_cutoff_msc);
   GlobalVariableSet(fe_reset_key_deal,(double)fe_reset_cutoff_deal);
   GlobalVariableSet(fe_reset_key_first,fe_reset_first_lot?1.0:0.0);
}

bool FEResetHasPositions()
{
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MAGIC) return true;
   }
   return false;
}

void FEResetInit()
{
   string prefix="FEq_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"_"+_Symbol+"_"+(string)MAGIC;
   fe_reset_key_peak=prefix+"_P";
   fe_reset_key_pending=prefix+"_C";
   fe_reset_key_time=prefix+"_T";
   fe_reset_key_deal=prefix+"_D";
   fe_reset_key_first=prefix+"_F";
   if(MQLInfoInteger(MQL_TESTER))
   {
      // Tests start with fresh virtual capital, unlike live account restarts.
      GlobalVariableDel(fe_reset_key_peak);
      GlobalVariableDel(fe_reset_key_pending);
      GlobalVariableDel(fe_reset_key_time);
      GlobalVariableDel(fe_reset_key_deal);
      GlobalVariableDel(fe_reset_key_first);
   }
   double v=0.0;
   if(GlobalVariableGet(fe_reset_key_peak,v) && v>0.0)
      fe_reset_equity_peak=v;
   else
      fe_reset_equity_peak=MathMax(AccountInfoDouble(ACCOUNT_BALANCE),
                                  AccountInfoDouble(ACCOUNT_EQUITY));
   if(GlobalVariableGet(fe_reset_key_pending,v)) fe_reset_pending=(v>0.5);
   if(EquityResetDDPercent>0.0)
   {
      if(GlobalVariableGet(fe_reset_key_time,v) && v>0) fe_reset_cutoff_msc=(long)v;
      if(GlobalVariableGet(fe_reset_key_deal,v) && v>0) fe_reset_cutoff_deal=(ulong)v;
      if(GlobalVariableGet(fe_reset_key_first,v)) fe_reset_first_lot=(v>0.5);
   }
   else fe_reset_pending=false;
   if(EquityResetDDPercent>0.0) FEResetStore();
   PrintFormat("EQUITY RESET: %.2f%%, cycle peak %.2f, pending %s, next 0.01 %s, cutoff %I64d",
               EquityResetDDPercent,fe_reset_equity_peak,
               fe_reset_pending?"YES":"NO",fe_reset_first_lot?"YES":"NO",fe_reset_cutoff_msc);
}

// Executed on every tick BEFORE the old session/spread/news/entry guards.
// Return TRUE while a reset is processing, preventing fresh entries until FLAT.
bool FEResetProcess()
{
   if(EquityResetDDPercent<=0.0) return false;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(!MathIsValidNumber(equity)) return true;
   if(!fe_reset_pending)
   {
      if(equity>fe_reset_equity_peak)
      {
         fe_reset_equity_peak=equity;
         GlobalVariableSet(fe_reset_key_peak,equity);
      }
      if(fe_reset_equity_peak<=0.0) return true;
      double dd=(fe_reset_equity_peak-equity)*100.0/fe_reset_equity_peak;
      if(dd+1e-8<EquityResetDDPercent) return false;
      fe_reset_pending=true;
      FEResetStore(); // Save the intent before closing anything.
      PrintFormat("EQUITY RESET TRIGGER: equity %.2f, cycle peak %.2f, DD %.2f%% >= %.2f%%; closing EA positions",
                  equity,fe_reset_equity_peak,dd,EquityResetDDPercent);
   }

   // Close own legs (including split batches), never other experts' positions.
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MAGIC) continue;
      bool ok=trade.PositionClose(ticket);
      uint rc=trade.ResultRetcode();
      if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_DONE_PARTIAL))
         PrintFormat("EQUITY RESET: unable to close position %I64u; rc=%u %s",
                     ticket,rc,trade.ResultRetcodeDescription());
   }
   if(FEResetHasPositions())
   {
      FESetStatus("EQUITY RESET: закрываем позиции; новые входы заблокированы");
      return true;
   }

   // Only after ALL positions are closed: forget previous recovery P/L.
   // Persist millisecond time plus last deal ticket to allow fresh entries
   // even if they are executed within the same millisecond in the tester.
   long cutoff=TimeCurrent()*1000;
   MqlTick t;
   if(SymbolInfoTick(_Symbol,t) && t.time_msc>cutoff) cutoff=t.time_msc;
   ulong ticket_at_cutoff=0;
   if(!HistorySelect(0,TimeCurrent()+1))
   {
      Print("EQUITY RESET: waiting for history before marking completed reset: ",GetLastError());
      return true;
   }
   for(int i=0;i<HistoryDealsTotal();++i)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MAGIC) continue;
      long tm=HistoryDealGetInteger(deal,DEAL_TIME_MSC);
      if(tm<=0) tm=HistoryDealGetInteger(deal,DEAL_TIME)*1000;
      if(tm>cutoff) { cutoff=tm; ticket_at_cutoff=deal; }
      else if(tm==cutoff && deal>ticket_at_cutoff) ticket_at_cutoff=deal;
   }
   fe_reset_cutoff_msc=cutoff;
   fe_reset_cutoff_deal=ticket_at_cutoff;
   fe_reset_equity_peak=AccountInfoDouble(ACCOUNT_EQUITY);
   fe_reset_first_lot=true;  // NEXT successful batch starts with exactly 0.01.
   cached_debt=0.0;
   cached_cost_per_lot=0.0;
   cached_ready=false;
   fe_reset_pending=false;
   FEResetStore();
   PrintFormat("EQUITY RESET COMPLETE: new cycle equity %.2f; previous debt ignored; next batch 0.01 lot; cutoff %I64d/%I64u",
               fe_reset_equity_peak,fe_reset_cutoff_msc,fe_reset_cutoff_deal);
   FESetStatus("EQUITY RESET: новый цикл, следующая группа 0.01 лота");
   return true; // New entries only on subsequent tick and through old guards.
}
// ================== END EQUITY RESET ==============================

int OnInit()
{
   if(GoldMoveUSD<=0.0 || !MathIsValidNumber(GoldMoveUSD) ||
      BalancePer001Lot<=0.0 || !MathIsValidNumber(BalancePer001Lot) ||
      (DirectionMode!=RANDOM_BUY_SELL && DirectionMode!=ALTERNATE_BUY_SELL) ||
      !MathIsValidNumber(EquityResetDDPercent) || EquityResetDDPercent<0.0 ||
      EquityResetDDPercent>=100.0)
      return INIT_PARAMETERS_INCORRECT;

   const double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   const double vstep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vmin>0.01+1e-8 || vstep<=0.0 || vstep>0.01+1e-8 ||
      MathAbs(RoundVolumeUp(0.01)-0.01)>1e-8 ||
      MathAbs(RoundVolumeUp(0.02)-0.02)>1e-8)
   {
      PrintFormat("ERROR: %s cannot support exact 0.01 lot increments (min %.4f, step %.4f).",
                  _Symbol,vmin,vstep);
      return INIT_PARAMETERS_INCORRECT;
   }
   key_group="FullEd_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"_"+_Symbol+"_"+(string)MAGIC;
   if(StringLen(key_group)>63) return INIT_FAILED;
   if(MQLInfoInteger(MQL_TESTER))
   {
      GlobalVariableDel(key_group);
      MathSrand(20261031);  // Reproducible tests of Random mode
   }
   else MathSrand((int)(TimeLocal()+(datetime)GetTickCount()));
   double last=0.0;
   if(GlobalVariableGet(key_group,last) && last>0.0)
      group_sequence=(ulong)(long)last;
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetAsyncMode(false);
   trade.SetTypeFillingBySymbol(_Symbol);
   FEResetInit();
   PrintFormat("FULL EDITION: displayed balance %.2f %s treated as CENTS, per-0.01 tier %.2f, base %.2f, mode %s. No hedge. Optional equity drawdown reset. Entry guards v5.00 unchanged. Broker contract size is unchanged.",
              AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoString(ACCOUNT_CURRENCY),
              BalancePer001Lot,CentBaseLot(AccountInfoDouble(ACCOUNT_BALANCE)),
              DirectionMode==RANDOM_BUY_SELL?"RANDOM":"ALTERNATING");
   if(!FEInitGuards()) return INIT_FAILED;
   return INIT_SUCCEEDED;
}

// Fallback: a broker-side SL/TP remains primary. If quote is already beyond
// a visible stop/take and the broker position is still open, request closing.
// SELL uses ASK and BUY uses BID. No profit guarantee under gaps/slippage.
void CheckAndCloseCrossedStops()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t) || t.bid<=0 || t.ask<=0) return;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MAGIC) continue;
      ENUM_POSITION_TYPE kind=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double close_quote=(kind==POSITION_TYPE_BUY?t.bid:t.ask);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(sl<=0 || tp<=0)
      {
         double entry=PositionGetDouble(POSITION_PRICE_OPEN);
         double new_sl=RoundPrice(kind==POSITION_TYPE_BUY?entry-GoldMoveUSD:entry+GoldMoveUSD);
         double new_tp=RoundPrice(kind==POSITION_TYPE_BUY?entry+GoldMoveUSD:entry-GoldMoveUSD);
         bool sent=trade.PositionModify(ticket,new_sl,new_tp);
         uint rc=trade.ResultRetcode();
         if(!sent || rc!=TRADE_RETCODE_DONE)
            WarningOnce("FULL EDITION: NO broker SL/TP; repair failed; ticket "+(string)ticket+
                        ", code "+(string)rc);
         continue;
      }
      bool crossed=(kind==POSITION_TYPE_BUY && (close_quote<=sl || close_quote>=tp)) ||
                   (kind==POSITION_TYPE_SELL && (close_quote>=sl || close_quote<=tp));
      if(!crossed) continue;
      bool ok=trade.PositionClose(ticket);
      uint rc=trade.ResultRetcode();
      if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_DONE_PARTIAL))
         WarningOnce("FULL EDITION CLOSE RETRY: ticket "+(string)ticket+", code "+(string)rc+" "+trade.ResultRetcodeDescription());
      else
         PrintFormat("FULL EDITION FALLBACK CLOSE: ticket %I64u, quote %.*f, SL %.*f, TP %.*f",
                     ticket,_Digits,close_quote,_Digits,sl,_Digits,tp);
   }
}

// Attach SL/TP at exactly GoldMoveUSD from real execution price for each
// split leg. Initial protective SL/TP were already sent with the market order.
void CorrectStopsForFilledLeg(const ulong deal_id,const bool buy)
{
   if(deal_id==0 || !HistoryDealSelect(deal_id))
   {
      WarningOnce("FULL EDITION: no history entry for filled deal "+(string)deal_id);
      return;
   }
   ulong identifier=(ulong)HistoryDealGetInteger(deal_id,DEAL_POSITION_ID);
   if(identifier==0) return;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=identifier) continue;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=RoundPrice(buy?entry-GoldMoveUSD:entry+GoldMoveUSD);
      double tp=RoundPrice(buy?entry+GoldMoveUSD:entry-GoldMoveUSD);
      double old_sl=PositionGetDouble(POSITION_SL);
      double old_tp=PositionGetDouble(POSITION_TP);
      if(MathAbs(old_sl-sl)<=_Point*0.01 && MathAbs(old_tp-tp)<=_Point*0.01) return;
      bool sent=trade.PositionModify(ticket,sl,tp);
      uint rc=trade.ResultRetcode();
      if(!sent || rc!=TRADE_RETCODE_DONE)
         PrintFormat("FULL EDITION WARNING: cannot align stops for position %I64u, requested SL %.*f TP %.*f, rc=%u (%s). Initial broker SL/TP remain.",
                     ticket,_Digits,sl,_Digits,tp,rc,trade.ResultRetcodeDescription());
      return;
   }
   WarningOnce("FULL EDITION WARNING: filled leg not found in positions (already closed?) "+(string)identifier);
}

// Invalidate history cache only when deals change. This prevents rescanning
// thousands of historical trades on every real tick during a margin rejection.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.symbol!=_Symbol) return;
   cached_ready=false;
   if(!HistoryDealSelect(trans.deal)) return;
   if((ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=MAGIC) return;
   ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(e!=DEAL_ENTRY_IN && e!=DEAL_ENTRY_INOUT) return;
   long when=HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
   if(when<=0) when=HistoryDealGetInteger(trans.deal,DEAL_TIME)*1000;
   FERecordEntry(when);
}

void OnTick()
{
   CheckAndCloseCrossedStops(); // Exits BEFORE every entry guard.
   if(FEResetProcess()) return; // Equity threshold: flat first, then forget old debt.
   FERefreshNews();
   FEDrawNews();
   if(IsSymbolBusy())
   {
      fe_seen_open=true;
      FESetStatus("Есть открытая позиция/группа; SL/TP сопровождаются");
      FEPanel();
      return;
   }
   if(fe_seen_open) { cached_ready=false; fe_seen_open=false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return;
   datetime now=TimeCurrent();
   if(now==last_attempt_time) return;
   last_attempt_time=now;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   string guard_reason;
   if(!FEEntryAllows(tick,true,guard_reason))
   { FESetStatus(guard_reason); FEPanel(); return; }
   FESetStatus("Фильтры разрешают вход; расчёт лота и маржи"); FEPanel();
   double base=fe_reset_first_lot?0.01:CentBaseLot(AccountInfoDouble(ACCOUNT_BALANCE));
   if(base<=0 || !MathIsValidNumber(base)) return;
   double debt=0.0,cost_per_lot=0.0;
   int completed=0;
   // Original debt recovery is unchanged, except when equity-reset explicitly marks a new cycle.
   bool buy=true;
   if(!cached_ready)
   {
      if(!ReadDebt(cached_debt,cached_cost_per_lot,cached_finished)) return;
      if(!NextDirectionIsBuy(cached_is_buy)) return;
      cached_ready=true;
   }
   debt=cached_debt;
   cost_per_lot=cached_cost_per_lot;
   completed=cached_finished;
   buy=cached_is_buy;
   ENUM_ORDER_TYPE side=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double quote=buy?tick.ask:tick.bid;
   double sl=RoundPrice(buy?quote-GoldMoveUSD:quote+GoldMoveUSD);
   double tp=RoundPrice(buy?quote+GoldMoveUSD:quote-GoldMoveUSD);
   if(sl<=0 || tp<=0 || sl==quote || tp==quote)
   { WarningOnce("ERROR: invalid SL/TP prices."); return; }
   double min_distance=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(MathAbs(sl-quote)+1e-8<min_distance || MathAbs(tp-quote)+1e-8<min_distance)
   { WarningOnce("ERROR: stop distance below broker minimum."); return; }

   double gross=0.0;
   if(!OrderCalcProfit(side,_Symbol,base,quote,tp,gross) || gross<=0.0)
   { WarningOnce("ERROR: OrderCalcProfit failed."); return; }
   double lots=base;
   if(debt>1e-8)
   {
      double per_lot=gross/base-cost_per_lot;
      if(per_lot<=0.0) { WarningOnce("ERROR: costs exceed TP proceeds per lot."); return; }
      lots=MathMax(base,(debt+gross)/per_lot);
   }
   if(!MathIsValidNumber(lots) || lots<=0.0 || lots>100000000.0)
   { WarningOnce("ERROR: recovery volume cannot be represented safely."); return; }
   lots=RoundVolumeUp(lots);
   if(lots<=0.0) return;

   double directional_limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   if(directional_limit>0.0 && lots>directional_limit+1e-8)
   {
      WarningOnce("FULL EDITION: recovery volume "+DoubleToString(lots,2)+" exceeds broker TOTAL directional limit "+DoubleToString(directional_limit,2)+". No debt reset.");
      return;
   }
   bool hedging=(AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!hedging && lots>MaxOrderVolume()+1e-8)
   {
      WarningOnce("FULL EDITION: multi-order split requires HEDGING account; no order sent, debt retained.");
      return;
   }

   double need_margin=0.0;
   int chunks=0;
   if(!BatchMargin(side,lots,quote,need_margin,chunks))
   { WarningOnce("ERROR: cannot calculate margin for recovery batch."); return; }
   double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(need_margin>free_margin+1e-6)
   {
      WarningOnce("FULL EDITION: insufficient margin: need "+DoubleToString(need_margin,2)+
                  ", available "+DoubleToString(free_margin,2)+
                  ", desired lot "+DoubleToString(lots,2)+
                  ", debt "+DoubleToString(debt,2)+". NO reset or pause.");
      return;
   }

   group_sequence++;
   GlobalVariableSet(key_group,(double)group_sequence);
   string comment="FE"+(string)group_sequence;
   double remaining=lots;
   double chunk=MaxOrderVolume();
   int opened=0;
   double filled_total=0.0;
   while(remaining>1e-8)
   {
      if(IsStopped()) break;
      if(opened>0 && !IsSymbolBusy())
      {
         Print("FULL EDITION: filled batch parts already closed; remaining volume not reopened");
         break;
      }
      double part=MathMin(chunk,remaining);
      part=NormalizeDouble(part,8);
      if(part<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)-1e-8)
      { PrintFormat("FULL EDITION ERROR: invalid split remainder %.8f",part); break; }
      MqlTick fresh;
      if(!SymbolInfoTick(_Symbol,fresh) || !FEEntryAllows(fresh,opened==0,guard_reason))
      {
         FESetStatus("Группа остановлена: "+guard_reason);
         Print("FULL EDITION GUARD: прекращён добор группы ",comment,
               "; уже открыто частей ",opened,"; причина: ",guard_reason);
         break;
      }
      double part_quote=buy?fresh.ask:fresh.bid;
      double part_sl=RoundPrice(buy?part_quote-GoldMoveUSD:part_quote+GoldMoveUSD);
      double part_tp=RoundPrice(buy?part_quote+GoldMoveUSD:part_quote-GoldMoveUSD);
      // Broker distance is measured against the close side (Bid for BUY,
      // Ask for SELL), NOT solely against the opening quote.
      double close_quote=buy?fresh.bid:fresh.ask;
      if(part_sl<=0 || part_tp<=0 ||
         (buy && (close_quote-part_sl<min_distance-1e-8 || part_tp-close_quote<min_distance-1e-8)) ||
         (!buy && (part_sl-close_quote<min_distance-1e-8 || close_quote-part_tp<min_distance-1e-8)))
      {
         WarningOnce("FULL EDITION: current spread/stops-level does not permit requested SL/TP; no new part");
         break;
      }
      bool sent=buy?trade.Buy(part,_Symbol,0.0,part_sl,part_tp,comment)
                   :trade.Sell(part,_Symbol,0.0,part_sl,part_tp,comment);
      uint rc=trade.ResultRetcode();
      bool filled=sent && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_DONE_PARTIAL) && trade.ResultDeal()>0;
      if(!filled)
      {
         PrintFormat("FULL EDITION ORDER FAILED: %s %.2f lots; filled legs %d; rc %u (%s). Debt not reset.",
                     buy?"BUY":"SELL",part,opened,rc,trade.ResultRetcodeDescription());
         break;
      }
      double fill_lots=trade.ResultVolume();
      if(fill_lots<=0.0 || fill_lots>part+1e-8) fill_lots=part;
      ulong deal=trade.ResultDeal();
      long entry_time=FETickMsc(fresh);
      if(HistoryDealSelect(deal))
      {
         long confirmed=HistoryDealGetInteger(deal,DEAL_TIME_MSC);
         if(confirmed>entry_time) entry_time=confirmed;
      }
      FERecordEntry(entry_time); // persisted after fill, never after a stop
      opened++;
      filled_total+=fill_lots;
      remaining=NormalizeDouble(remaining-fill_lots,8);
      // PositionModify changes the trade object result, therefore save deal first.
      if(hedging) CorrectStopsForFilledLeg(deal,buy);
   }
   if(opened>0)
   {
      if(fe_reset_first_lot)
      {
         fe_reset_first_lot=false;  // First successful batch used 0.01, then usual balance tiers.
         GlobalVariableSet(fe_reset_key_first,0.0);
      }
      last_attempt_time=0;
      cached_ready=false;
      PrintFormat("FULL EDITION: batch %s %s, volume filled %.2f / intended %.2f, legs %d; balance-tier lot %.2f, debt %.2f.",
                  comment,buy?"BUY":"SELL",filled_total,lots,opened,base,debt);
   }
   // No next batch while any of these legs remains open.
}
//+------------------------------------------------------------------+
