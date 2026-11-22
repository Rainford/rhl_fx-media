// RHL Journal: TradingView webhook relay.
// TradingView posts the RHL_FX+G grade alert here; this reads it and saves it to your
// Supabase project as a graded setup. Webhook URL (copy it from the app's Settings):
//   https://<your-site>.netlify.app/api/tv?code=<sync code>&ref=<project ref>&key=<publishable key>

const SYM = [
  [/^(XAUUSD|GOLD|XAU)/, 'XAUUSD'],
  [/^(US30|DJI|DJ30|WS30|YM|DOW)/, 'US30'],
  [/^(USTEC|USTECH|NAS100|NAS|US100|NDX|NQ)/, 'USTEC'],
  [/^(JP225|JPN225|NI225|NIKKEI|JPY225|NKY)/, 'JP225'],
  [/^(USOIL|WTI|XTIUSD|CL|USOUSD|UKOIL)/, 'USOIL'],
];
function normSym(s) {
  s = String(s || '').toUpperCase().replace(/^.*:/, '').replace(/[.!#].*$/, '');
  if (s.length > 4 && /M$/.test(s) && !/(USDM)$/.test(s)) s = s.replace(/M$/, '');
  for (const [re, v] of SYM) if (re.test(s)) return v;
  return s;
}
const ROWS = { SIG: 'signal', BRK: 'brk1h', RET: 'retest', PROT: 'prot', CONT: 'cont', EC: 'ec', HTF: 'htf', REJ: 'rej', EMA: 'ema', TREND: 'trend', SH1: 'shift1', SH15: 'shift15' };

// Turns the grade alert text into a setup. Returns null for anything else (e.g. the "Get ready" heads-up).
function parseAlert(text) {
  text = String(text || '').trim();
  if (!text) return null;
  if (text.charAt(0) === '{') { try { const j = JSON.parse(text); if (j && j.symbol) return j; } catch (e) {} }
  const m = text.match(/^RHL_FX\s+(\S+)\s+(\S+)\s+(BUY|SELL)(\s+IMPULSIVE)?/i);
  if (!m || !/\|\s*Grade\s/i.test(text)) return null;
  const num = (re) => { const x = text.match(re); return x ? x[1].replace(/,/g, '') : ''; };
  const grade = text.match(/Grade\s+(A\+|A|B|C|NO TRADE|WAIT)\s*\((\d+)%\)/i);
  const bias = text.match(/Bias\s+4H\s+(\w+)\s+1H\s+(\w+)\s+15M\s+(\w+)/i);
  const rows = (text.match(/\|\s*Rows\s+([A-Z0-9 ]+)/) || [])[1] || '';
  const checks = {};
  rows.trim().split(/\s+/).forEach((r) => { if (ROWS[r]) checks[ROWS[r]] = true; });
  return {
    symbol: normSym(m[1]),
    ticker: m[1],
    model: m[2].toUpperCase(),
    dir: m[3].toUpperCase() === 'BUY' ? 'Long' : 'Short',
    setup: m[4] ? 'Impulsive' : 'Normal',
    grade: grade ? grade[1].toUpperCase() : '',
    score: grade ? +grade[2] : 0,
    entry: num(/Entry\s+([\d.,]+)/i),
    sl: num(/SL\s+([\d.,]+)/i),
    tp: num(/TP\s+([\d.,]+)/i),
    rr: num(/R:R\s+1:([\d.]+)/i),
    session: ((text.match(/Session:\s*([^|]+)/i) || [])[1] || '').trim(),
    s4h: bias ? cap(bias[1]) : '', s1h: bias ? cap(bias[2]) : '', s15: bias ? cap(bias[3]) : '',
    checks,
    raw: text.slice(0, 600),
  };
}
function cap(s) { s = String(s || '').toLowerCase(); return s.charAt(0).toUpperCase() + s.slice(1); }

exports.parseAlert = parseAlert;
exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return { statusCode: 405, body: 'Send a POST (this is the TradingView webhook).' };
  const q = event.queryStringParameters || {};
  const code = (q.code || '').trim(), ref = (q.ref || '').trim(), key = (q.key || '').trim();
  if (!code || !/^[a-z0-9]{10,40}$/.test(ref) || key.length < 20) return { statusCode: 400, body: 'The webhook URL is missing code, ref or key. Copy it again from the app Settings.' };
  const text = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
  const alert = parseAlert(text);
  if (!alert) return { statusCode: 200, body: 'ignored (not a grade alert)' };
  const headers = { 'Content-Type': 'application/json', apikey: key };
  if (key.startsWith('eyJ')) headers.Authorization = 'Bearer ' + key;
  try {
    const r = await fetch(`https://${ref}.supabase.co/rest/v1/rpc/tv_push`, { method: 'POST', headers, body: JSON.stringify({ p_token: code, p_alert: alert }) });
    const t = await r.text();
    return { statusCode: r.ok ? 200 : 502, body: r.ok ? 'saved ' + t : 'Supabase said: ' + t.slice(0, 300) };
  } catch (e) {
    return { statusCode: 502, body: 'Could not reach Supabase' };
  }
};
