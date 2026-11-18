//+------------------------------------------------------------------+
//| RHL_Journal_Sync.mq5                                             |
//| Sends closed MT5 positions to the RHL Journal app (Supabase).    |
//| It never opens, changes or closes trades. Read-only on account.  |
//+------------------------------------------------------------------+
#property copyright "RHL_FX"
#property version   "1.00"
#property description "Sends your closed trades to RHL Journal. Never trades."

//--- inputs
input string InpURL      = "https://oacxvofughgbyfzaeoiz.supabase.co"; // Supabase URL
input string InpKey      = "";   // Key (from the app's Settings)
input string InpCode     = "";   // Sync code (from the app's Settings)
input int    InpDaysBack = 90;   // Days of history to send on start
input int    InpServerGMT = 0;   // Broker server time offset from GMT (Exness = 0)
input bool   InpVerbose  = true; // Print each send in the Experts log

//--- state
ulong    g_pending[];          // position ids waiting to be sent
int      g_sentTotal = 0;
string   g_lastStatus = "Starting";
datetime g_lastOk = 0;
bool     g_blocked = false;    // true when the URL is not allowed or the code is wrong
string   g_base = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(MQLInfoInteger(MQL_TESTER))
     {
      Print("RHL Journal Sync does nothing in the Strategy Tester.");
      return(INIT_SUCCEEDED);
     }
   g_base = Trim(InpURL);
   while(StringLen(g_base) > 0 && StringGetCharacter(g_base, StringLen(g_base) - 1) == '/')
      g_base = StringSubstr(g_base, 0, StringLen(g_base) - 1);
   if(StringFind(g_base, "https://") != 0)
     {
      Alert("RHL Journal Sync: the Supabase URL must start with https://");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(StringLen(Trim(InpKey)) < 20 || StringLen(Trim(InpCode)) < 20)
     {
      Alert("RHL Journal Sync: paste the Key and the Sync code from the app's Settings > Sync from MT5.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   ArrayResize(g_pending, 0);
   QueueHistory(InpDaysBack);
   EventSetTimer(20);
   Flush();
   ShowStatus();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(ArraySize(g_pending) > 0)
      Flush();
   ShowStatus();
  }

//+------------------------------------------------------------------+
void OnTick() { }

//+------------------------------------------------------------------+
//| A deal was added: if it closed (part of) a position, queue it.   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(MQLInfoInteger(MQL_TESTER))
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;
   ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(pos == 0)
      return;
   AddPending(pos);
   g_blocked = false;   // a new trade is a good moment to try again
   Flush();
   ShowStatus();
  }

//+------------------------------------------------------------------+
//| Queue every position closed in the last `days` days.             |
//+------------------------------------------------------------------+
void QueueHistory(int days)
  {
   if(days < 1)
      days = 1;
   datetime from = TimeCurrent() - (datetime)days * 86400;
   if(!HistorySelect(from, TimeCurrent() + 86400))
     {
      Print("RHL Journal Sync: could not read account history.");
      return;
     }
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      long type = HistoryDealGetInteger(deal, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;
      ulong pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pos > 0)
         AddPending(pos);
     }
   if(InpVerbose)
      PrintFormat("RHL Journal Sync: %d closed positions from the last %d days queued.", ArraySize(g_pending), days);
  }

//+------------------------------------------------------------------+
void AddPending(ulong pos)
  {
   int n = ArraySize(g_pending);
   for(int i = 0; i < n; i++)
      if(g_pending[i] == pos)
         return;
   ArrayResize(g_pending, n + 1);
   g_pending[n] = pos;
  }

//+------------------------------------------------------------------+
void RemovePending(ulong pos)
  {
   int n = ArraySize(g_pending);
   for(int i = 0; i < n; i++)
      if(g_pending[i] == pos)
        {
         for(int j = i; j < n - 1; j++)
            g_pending[j] = g_pending[j + 1];
         ArrayResize(g_pending, n - 1);
         return;
        }
  }

//+------------------------------------------------------------------+
//| Send pending positions in batches of up to 50.                   |
//+------------------------------------------------------------------+
void Flush()
  {
   if(g_blocked)
      return;
   int guard = 0;
   while(ArraySize(g_pending) > 0 && guard < 20)
     {
      guard++;
      int n = (int)MathMin(50, ArraySize(g_pending));
      ulong batch[];
      ArrayResize(batch, n);
      for(int i = 0; i < n; i++)
         batch[i] = g_pending[i];

      string items = "";
      int count = 0;
      ulong sent[];
      ArrayResize(sent, 0);
      for(int i = 0; i < n; i++)
        {
         string js = "";
         int st = BuildPosition(batch[i], js);
         if(st == 1)
           {
            items += (count > 0 ? "," : "") + js;
            count++;
            ArrayResize(sent, count);
            sent[count - 1] = batch[i];
           }
         else
            if(st == 0)
               RemovePending(batch[i]);   // still open or not a real trade: nothing to send yet
        }
      if(count == 0)
        {
         // everything in this batch was skipped
         bool any = false;
         for(int i = 0; i < n; i++)
            for(int k = 0; k < ArraySize(g_pending); k++)
               if(g_pending[k] == batch[i])
                  any = true;
         if(!any)
            continue;
         return;
        }

      string body = "{\"p_token\":\"" + JsonEsc(Trim(InpCode)) + "\",\"p_trades\":[" + items + "]}";
      string reply = "";
      int code = Post(body, reply);
      if(code == 200)
        {
         for(int i = 0; i < count; i++)
            RemovePending(sent[i]);
         g_sentTotal += count;
         g_lastOk = TimeLocal();
         g_lastStatus = "Synced " + IntegerToString(count) + " trade" + (count == 1 ? "" : "s");
         if(InpVerbose)
            PrintFormat("RHL Journal Sync: sent %d closed trade(s) to your journal.", count);
        }
      else
        {
         ExplainFailure(code, reply);
         return;   // keep them queued; the timer retries
        }
     }
  }

//+------------------------------------------------------------------+
//| Build one position as JSON.                                      |
//| Returns 1 = ready, 0 = skip for good (still open / not a trade), |
//| -1 = could not read history right now (retry later).             |
//+------------------------------------------------------------------+
int BuildPosition(ulong pos, string &json)
  {
   if(!HistorySelectByPosition(pos))
      return(-1);
   int total = HistoryDealsTotal();
   if(total == 0)
      return(-1);

   string sym = "";
   int    dir = 0;            // 1 long, -1 short
   double volIn = 0, volOut = 0, pxIn = 0, pxOut = 0, money = 0;
   double sl = 0, tp = 0;
   datetime tOpen = 0, tClose = 0;

   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type  = HistoryDealGetInteger(d, DEAL_TYPE);
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      double vol = HistoryDealGetDouble(d, DEAL_VOLUME);
      double px  = HistoryDealGetDouble(d, DEAL_PRICE);
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      money += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
               HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      if(sym == "")
         sym = HistoryDealGetString(d, DEAL_SYMBOL);
      if(entry == DEAL_ENTRY_IN)
        {
         if(dir == 0)
            dir = (type == DEAL_TYPE_BUY) ? 1 : -1;
         pxIn += px * vol;
         volIn += vol;
         if(tOpen == 0 || t < tOpen)
            tOpen = t;
         if(sl == 0)
            sl = HistoryDealGetDouble(d, DEAL_SL);
         if(tp == 0)
            tp = HistoryDealGetDouble(d, DEAL_TP);
        }
      else
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
           {
            pxOut += px * vol;
            volOut += vol;
            if(t > tClose)
               tClose = t;
            if(sl == 0)
               sl = HistoryDealGetDouble(d, DEAL_SL);
            if(tp == 0)
               tp = HistoryDealGetDouble(d, DEAL_TP);
           }
         else
            if(entry == DEAL_ENTRY_INOUT)
              {
               // reversal deal: closes this position at this price
               pxOut += px * vol;
               volOut += vol;
               if(t > tClose)
                  tClose = t;
              }
     }

   if(dir == 0 || volIn <= 0 || volOut <= 0 || sym == "")
      return(0);
   if(volOut < volIn - 0.0000001)
      return(0);   // partly closed: it will be sent when fully closed

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(digits <= 0 || digits > 8)
      digits = 5;

   json = StringFormat("{\"ticket\":\"%I64u\",\"symbol\":\"%s\",\"dir\":\"%s\",\"lots\":\"%s\",\"open\":\"%s\",\"close\":\"%s\",\"entry\":\"%s\",\"exit\":\"%s\",\"pnl\":\"%s\",\"sl\":\"%s\",\"tp\":\"%s\"}",
                       pos,
                       JsonEsc(NormSymbol(sym)),
                       (dir > 0 ? "Long" : "Short"),
                       DoubleToString(volIn, 2),
                       IsoUtc(tOpen),
                       IsoUtc(tClose),
                       DoubleToString(pxIn / volIn, digits),
                       DoubleToString(pxOut / volOut, digits),
                       DoubleToString(money, 2),
                       (sl > 0 ? DoubleToString(sl, digits) : ""),
                       (tp > 0 ? DoubleToString(tp, digits) : ""));
   return(1);
  }

//+------------------------------------------------------------------+
//| POST to the mt5_push function. Returns the HTTP status (or -1).  |
//+------------------------------------------------------------------+
int Post(const string body, string &reply)
  {
   string key = Trim(InpKey);
   string headers = "Content-Type: application/json\r\napikey: " + key + "\r\n";
   if(StringFind(key, "eyJ") == 0)
      headers += "Authorization: Bearer " + key + "\r\n";
   char data[];
   char res[];
   string resHeaders;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1);   // drop the trailing zero
   ResetLastError();
   int code = WebRequest("POST", g_base + "/rest/v1/rpc/mt5_push", headers, 10000, data, res, resHeaders);
   reply = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
   return(code);
  }

//+------------------------------------------------------------------+
void ExplainFailure(int code, string reply)
  {
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
        {
         g_blocked = true;
         g_lastStatus = "Blocked: allow the Supabase URL in Tools > Options > Expert Advisors";
         Alert("RHL Journal Sync: MT5 is blocking the connection. Go to Tools > Options > Expert Advisors, tick 'Allow WebRequest for listed URL' and add ", g_base, " then reattach the add-on.");
        }
      else
         g_lastStatus = "No connection (error " + IntegerToString(err) + "). Retrying.";
      Print("RHL Journal Sync: ", g_lastStatus);
      return;
     }
   if(StringFind(reply, "invalid sync code") >= 0)
     {
      g_blocked = true;
      g_lastStatus = "Sync code not accepted. Copy it again from the app's Settings.";
      Alert("RHL Journal Sync: the sync code was not accepted. Copy it again from the app's Settings > Sync from MT5.");
     }
   else
      if(StringFind(reply, "mt5_push") >= 0 || code == 404)
        {
         g_blocked = true;
         g_lastStatus = "Run supabase-mt5-sync.sql in Supabase, then reattach the add-on.";
         Alert("RHL Journal Sync: the sync setup is missing in Supabase. Run supabase-mt5-sync.sql in the SQL Editor, then reattach the add-on.");
        }
      else
         if(code == 401 || code == 403)
           {
            g_blocked = true;
            g_lastStatus = "Key not accepted. Copy the Key again from the app's Settings.";
            Alert("RHL Journal Sync: Supabase did not accept the Key. Copy it again from the app's Settings > Sync from MT5.");
           }
         else
            g_lastStatus = "Server said " + IntegerToString(code) + ". Retrying.";
   Print("RHL Journal Sync: ", g_lastStatus, " | ", StringSubstr(reply, 0, 200));
  }

//+------------------------------------------------------------------+
void ShowStatus()
  {
   string s = "RHL Journal Sync\n" + g_lastStatus;
   s += "\nSent this session: " + IntegerToString(g_sentTotal);
   if(g_lastOk > 0)
      s += "\nLast sync: " + TimeToString(g_lastOk, TIME_DATE | TIME_MINUTES);
   if(ArraySize(g_pending) > 0)
      s += "\nWaiting: " + IntegerToString(ArraySize(g_pending));
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string Trim(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return(s);
  }

// "2026-11-10T19:40:02Z" from broker server time
string IsoUtc(datetime serverTime)
  {
   datetime t = serverTime - (datetime)(InpServerGMT * 3600);
   MqlDateTime m;
   TimeToStruct(t, m);
   return(StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ", m.year, m.mon, m.day, m.hour, m.min, m.sec));
  }

// XAUUSDm -> XAUUSD, US30m -> US30, USTECH -> USTEC, JPN225 -> JP225
string NormSymbol(string s)
  {
   int cut = StringFind(s, ".");
   if(cut > 0)
      s = StringSubstr(s, 0, cut);
   cut = StringFind(s, "#");
   if(cut > 0)
      s = StringSubstr(s, 0, cut);
   int n = StringLen(s);
   if(n > 4 && StringGetCharacter(s, n - 1) == 'm')
      s = StringSubstr(s, 0, n - 1);
   StringToUpper(s);
   if(s == "USTECH")
      s = "USTEC";
   if(s == "JPN225")
      s = "JP225";
   return(s);
  }

string JsonEsc(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return(s);
  }
//+------------------------------------------------------------------+
