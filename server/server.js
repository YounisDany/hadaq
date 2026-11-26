// Hadaq backend: app config (settings, force update), API keys, users, and the AI proxy.
// Admin dashboard lives in ./public and is served at /admin.
import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { execFile } from 'node:child_process';
import { searchPlaces, walkingRoute } from './maps.js';
import { mountSurvey } from './survey.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
if (fs.existsSync(path.join(__dirname, '.env'))) process.loadEnvFile(path.join(__dirname, '.env'));

const PORT = Number(process.env.PORT || 8787);
const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const SESSION_SECRET = process.env.SESSION_SECRET;
const SECRETS_KEY = Buffer.from(process.env.SECRETS_KEY || '', 'hex');
if (!ADMIN_PASSWORD || !SESSION_SECRET || SECRETS_KEY.length !== 32) {
  console.error('Missing ADMIN_PASSWORD / SESSION_SECRET / SECRETS_KEY (32 bytes hex) in .env');
  process.exit(1);
}

// ---------------------------------------------------------------- database
fs.mkdirSync(path.join(__dirname, 'data'), { recursive: true });
const db = new DatabaseSync(path.join(__dirname, 'data', 'hadaq.db'));
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS secrets (
    name TEXT PRIMARY KEY, value_enc TEXT NOT NULL, note TEXT, updated_at TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, platform TEXT, app_version TEXT, build INTEGER, os_version TEXT,
    device_model TEXT, locale TEXT, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
    opens INTEGER NOT NULL DEFAULT 0, ai_requests INTEGER NOT NULL DEFAULT 0,
    vision_requests INTEGER NOT NULL DEFAULT 0, blocked INTEGER NOT NULL DEFAULT 0, note TEXT);
  CREATE TABLE IF NOT EXISTS conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, at TEXT NOT NULL,
    user_text TEXT, intent TEXT, reply TEXT);
  CREATE INDEX IF NOT EXISTS conv_device ON conversations(device_id, at);
  CREATE TABLE IF NOT EXISTS locations (
    id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, at TEXT NOT NULL,
    lat REAL NOT NULL, lon REAL NOT NULL, accuracy REAL);
  CREATE INDEX IF NOT EXISTS loc_device ON locations(device_id, at);
  CREATE TABLE IF NOT EXISTS testers (
    id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, name TEXT, device TEXT,
    created_at TEXT NOT NULL, ip TEXT, note TEXT);
  CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, action TEXT NOT NULL, detail TEXT);
`);

for (const col of ['profile TEXT', 'consent INTEGER NOT NULL DEFAULT 0', 'consent_at TEXT',
  'last_lat REAL', 'last_lon REAL', 'last_accuracy REAL', 'last_location_at TEXT']) {
  try { db.exec(`ALTER TABLE users ADD COLUMN ${col}`); } catch { /* already there */ }
}

const DEFAULT_SETTINGS = {
  // Force update
  min_build: 1, // builds below this are blocked until they update
  latest_build: 1, // builds below this get a soft "update available" notice
  latest_version: '1.0.0',
  update_url_android: '',
  update_url_ios: '',
  update_message: 'يتوفر إصدار جديد من حدق فيه تحسينات مهمة. حدّث التطبيق للمتابعة.',
  // Maintenance / announcement
  maintenance: false,
  maintenance_message: 'حدق في صيانة قصيرة. الذاكرة والطوارئ تعمل دون إنترنت.',
  announcement: '',
  // Features
  feature_assistant: true,
  feature_vision: true,
  feature_navigation: true,
  feature_sos: true,
  // Assistant
  ai_provider: 'gemini', // 'gemini' | 'openai' — switchable from the dashboard
  ai_model: 'gemini-2.5-flash',
  ai_model_openai: 'gpt-4.1',
  // Speech-to-text: 'openai' (recorded audio transcribed on the server — much better with
  // Arabic dialects) or 'device' (the phone's own recogniser).
  stt_engine: 'openai',
  stt_model: 'gpt-4o-transcribe',
  // Text-to-speech: 'openai' (GPT voice, generated on the server) or 'device' (the phone's voice).
  tts_engine: 'openai',
  tts_model: 'gpt-4o-mini-tts',
  tts_voice: 'nova',
  tts_instructions: 'تحدّث بالعربية بنطق واضح ولهجة سعودية خفيفة، بنبرة دافئة وهادئة، وبسرعة طبيعية مريحة. أنت مساعد صوتي لشخص كفيف.',
  ai_daily_limit: 200, // per user per day, 0 = unlimited
  ai_system_prompt: `أنت «حَدَق»، مساعد صوتي لشخص كفيف أو ضعيف البصر. كل ما تكتبه سيُقرأ بصوت عالٍ.
القواعد:
- اختصر: جملة أو جملتان، أقل من 25 كلمة. لا مقدمات ولا تكرار لسؤال المستخدم ولا قوائم ولا رموز.
- اقرأ النص الطويل كاملًا فقط إذا طلب المستخدم القراءة صراحة.
- أجب عن الصورة المرفقة مع هذا السؤال فقط، لا عن صور سابقة. صف ما تراه فعلًا بدقة ولا تخمّن.
- ابدأ بالأهم للسلامة: العوائق، الدرج، الحفر، السيارات، الأبواب.
- استخدم الاتجاهات بالنسبة للمستخدم: أمامك، على يمينك، على يسارك، وقدّر المسافة بالأمتار أو الخطوات.
- عند قراءة نص اذكر نوعه ثم أهم ما فيه، واعرض قراءة الباقي.
- للدواء: الاسم والتركيز وتاريخ الانتهاء إن ظهر. للعملة: الفئة والعملة.
- إن لم تكن متأكدًا فقل ذلك بوضوح، ولا تخترع. لا تحدد هوية أشخاص من وجوههم.
- ليست بديلًا عن العصا البيضاء؛ لا تقل إن الطريق آمن تمامًا.
أعد JSON فقط بهذا الشكل:
{"answer": "النص المنطوق", "label": "وصف من كلمتين لما في الصورة أو فارغ", "suggestions": ["رد سريع 1", "رد سريع 2"]}
الردود السريعة (0 إلى 3) عبارات قصيرة يمكن للمستخدم قولها بعدك، مثل «اقرأ النشرة» أو «لا شكرًا».`,
  emergency_number: '911',
  play_url: '', // Google Play listing URL — shown on the landing page once set
  // Voice survey (/survey): also send each response to the original Google Form.
  survey_forward_google: true,
  // Tester signup page (/test): the Google Group testers join, and Play's opt-in link.
  tester_group_url: '',
  tester_optin_url: '',
  tester_target: 12,
  // Data sharing (only from users who consented in the app)
  collect_data: true,
  data_retention_days: 30,
};

const now = () => new Date().toISOString();
const getSettings = () => {
  const s = { ...DEFAULT_SETTINGS };
  for (const r of db.prepare('SELECT key, value FROM settings').all()) {
    try { s[r.key] = JSON.parse(r.value); } catch { /* keep default */ }
  }
  return s;
};
const audit = (action, detail = '') =>
  db.prepare('INSERT INTO audit (at, action, detail) VALUES (?, ?, ?)').run(now(), action, String(detail).slice(0, 500));

// ---------------------------------------------------------------- secrets (AES-256-GCM at rest)
const encrypt = (plain) => {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', SECRETS_KEY, iv);
  const enc = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), enc]).toString('base64');
};
const decrypt = (b64) => {
  const b = Buffer.from(b64, 'base64');
  const d = crypto.createDecipheriv('aes-256-gcm', SECRETS_KEY, b.subarray(0, 12));
  d.setAuthTag(b.subarray(12, 28));
  return Buffer.concat([d.update(b.subarray(28)), d.final()]).toString('utf8');
};
const getSecret = (name) => {
  const r = db.prepare('SELECT value_enc FROM secrets WHERE name = ?').get(name);
  if (!r) return process.env[name] || null;
  try { return decrypt(r.value_enc); } catch { return null; }
};
const mask = (v) => (v.length <= 8 ? '••••' : `${v.slice(0, 4)}••••${v.slice(-4)}`);

// ---------------------------------------------------------------- admin sessions (signed cookie)
const sign = (payload) => {
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const sig = crypto.createHmac('sha256', SESSION_SECRET).update(body).digest('base64url');
  return `${body}.${sig}`;
};
const verify = (token) => {
  if (!token) return null;
  const [body, sig] = token.split('.');
  if (!body || !sig) return null;
  const good = crypto.createHmac('sha256', SESSION_SECRET).update(body).digest('base64url');
  if (sig.length !== good.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(good))) return null;
  const p = JSON.parse(Buffer.from(body, 'base64url').toString());
  return p.exp > Date.now() ? p : null;
};
const cookie = (req, name) =>
  (req.headers.cookie || '').split(';').map((s) => s.trim().split('=')).find(([k]) => k === name)?.[1];

const requireAdmin = (req, res, next) => {
  if (!verify(cookie(req, 'hadaq_admin'))) return res.status(401).json({ error: 'unauthorized' });
  next();
};

// Simple in-memory rate limiter.
const hits = new Map();
const limit = (key, max, windowMs) => {
  const t = Date.now();
  const arr = (hits.get(key) || []).filter((x) => t - x < windowMs);
  arr.push(t);
  hits.set(key, arr);
  return arr.length > max;
};


// ---------------------------------------------------------------- AI providers
// Both return { ok, status, text, error }. The app expects the JSON reply format
// described in the system prompt, so both are asked for JSON output.
const PROVIDERS = {
  gemini: { keyName: 'GEMINI_API_KEY', label: 'Google Gemini' },
  openai: { keyName: 'OPENAI_API_KEY', label: 'OpenAI' },
};

async function askGemini({ key, model, system, history, question, image }) {
  const contents = [];
  for (const [u, a] of history) {
    contents.push({ role: 'user', parts: [{ text: u }] });
    contents.push({ role: 'model', parts: [{ text: JSON.stringify({ answer: a }) }] });
  }
  contents.push({
    role: 'user',
    parts: [...(image ? [{ inline_data: { mime_type: 'image/jpeg', data: image } }] : []), { text: question }],
  });
  const r = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: system }] },
        contents,
        generationConfig: { responseMimeType: 'application/json', temperature: 0.2, maxOutputTokens: 300 },
      }),
    },
  );
  const j = await r.json().catch(() => ({}));
  if (!r.ok) return { ok: false, status: r.status, error: j?.error?.message };
  return { ok: true, status: 200, text: (j.candidates?.[0]?.content?.parts || []).map((p) => p.text || '').join('') };
}

async function askOpenAI({ key, model, system, history, question, image }) {
  const messages = [{ role: 'system', content: system }];
  for (const [u, a] of history) {
    messages.push({ role: 'user', content: u });
    messages.push({ role: 'assistant', content: JSON.stringify({ answer: a }) });
  }
  messages.push({
    role: 'user',
    content: [
      ...(image ? [{ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${image}`, detail: 'high' } }] : []),
      // json_object mode requires the word "JSON" somewhere in the messages; the system prompt has it.
      { type: 'text', text: question },
    ],
  });
  const r = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({ model, messages, response_format: { type: 'json_object' }, max_completion_tokens: 350, temperature: 0.2 }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) return { ok: false, status: r.status, error: j?.error?.message };
  return { ok: true, status: 200, text: j.choices?.[0]?.message?.content || '' };
}

// ---------------------------------------------------------------- app
const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 'loopback'); // behind Caddy: real client IP for rate limits
app.use(express.json({ limit: '8mb' })); // photos for vision questions

// CORS for the app's web build (the dashboard itself is same-origin).
app.use('/api', (req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, X-Device-Id');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

const validId = (id) => typeof id === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(id);

/** Called by the app on every launch: records the device and returns the config. */
app.post('/api/app/hello', (req, res) => {
  const b = req.body || {};
  if (!validId(b.device_id)) return res.status(400).json({ error: 'device_id' });
  if (limit(`hello:${req.ip}`, 60, 60_000)) return res.status(429).json({ error: 'rate' });
  const t = now();
  db.prepare(`
    INSERT INTO users (id, platform, app_version, build, os_version, device_model, locale, first_seen, last_seen, opens)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
    ON CONFLICT(id) DO UPDATE SET platform=excluded.platform, app_version=excluded.app_version,
      build=excluded.build, os_version=excluded.os_version, device_model=excluded.device_model,
      locale=excluded.locale, last_seen=excluded.last_seen, opens=opens+1`)
    .run(b.device_id, String(b.platform || '').slice(0, 20), String(b.app_version || '').slice(0, 20),
      Number(b.build) || 0, String(b.os_version || '').slice(0, 60), String(b.device_model || '').slice(0, 60),
      String(b.locale || '').slice(0, 10), t, t);
  const user = db.prepare('SELECT blocked FROM users WHERE id = ?').get(b.device_id);
  res.json(publicConfig(getSettings(), b.platform, Number(b.build) || 0, !!user?.blocked));
});

/**
 * Consent + profile. The app asks the user; without consent nothing below is stored
 * and withdrawing consent deletes what was stored.
 */
app.post('/api/app/consent', (req, res) => {
  const b = req.body || {};
  if (!validId(b.device_id)) return res.status(400).json({ error: 'device_id' });
  const user = db.prepare('SELECT id FROM users WHERE id = ?').get(b.device_id);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (b.consent) {
    db.prepare('UPDATE users SET consent = 1, consent_at = ? WHERE id = ?').run(now(), b.device_id);
  } else {
    wipeUserData(b.device_id);
    db.prepare('UPDATE users SET consent = 0, consent_at = ? WHERE id = ?').run(now(), b.device_id);
  }
  res.json({ ok: true });
});

function wipeUserData(id) {
  db.prepare('DELETE FROM conversations WHERE device_id = ?').run(id);
  db.prepare('DELETE FROM locations WHERE device_id = ?').run(id);
  db.prepare(`UPDATE users SET profile = NULL, last_lat = NULL, last_lon = NULL, last_accuracy = NULL,
    last_location_at = NULL WHERE id = ?`).run(id);
}

/** Batched sync from consenting users: profile, conversation turns, location. */
app.post('/api/app/sync', (req, res) => {
  const b = req.body || {};
  if (!validId(b.device_id)) return res.status(400).json({ error: 'device_id' });
  if (limit(`sync:${b.device_id}`, 60, 60_000)) return res.status(429).json({ error: 'rate' });
  const user = db.prepare('SELECT consent FROM users WHERE id = ?').get(b.device_id);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (!user.consent || !getSettings().collect_data) return res.json({ ok: true, stored: false });

  if (b.profile && typeof b.profile === 'object') {
    db.prepare('UPDATE users SET profile = ? WHERE id = ?').run(JSON.stringify(b.profile).slice(0, 20000), b.device_id);
  }
  const ins = db.prepare('INSERT INTO conversations (device_id, at, user_text, intent, reply) VALUES (?, ?, ?, ?, ?)');
  for (const e of (Array.isArray(b.events) ? b.events : []).slice(0, 50)) {
    ins.run(b.device_id, String(e.at || now()).slice(0, 40), String(e.user || '').slice(0, 1000),
      String(e.intent || '').slice(0, 40), String(e.reply || '').slice(0, 2000));
  }
  const l = b.location;
  if (l && Number.isFinite(Number(l.lat)) && Number.isFinite(Number(l.lon))) {
    const at = String(l.at || now()).slice(0, 40);
    db.prepare('INSERT INTO locations (device_id, at, lat, lon, accuracy) VALUES (?, ?, ?, ?, ?)')
      .run(b.device_id, at, Number(l.lat), Number(l.lon), Number(l.accuracy) || null);
    db.prepare('UPDATE users SET last_lat = ?, last_lon = ?, last_accuracy = ?, last_location_at = ? WHERE id = ?')
      .run(Number(l.lat), Number(l.lon), Number(l.accuracy) || null, at, b.device_id);
  }
  res.json({ ok: true, stored: true });
});

// Retention: drop conversations/locations older than the configured number of days.
const purgeOld = () => {
  const days = Number(getSettings().data_retention_days) || 30;
  const cutoff = new Date(Date.now() - days * 86_400_000).toISOString();
  db.prepare('DELETE FROM conversations WHERE at < ?').run(cutoff);
  db.prepare('DELETE FROM locations WHERE at < ?').run(cutoff);
};
setInterval(purgeOld, 3_600_000).unref();
purgeOld();

/** Config without registering (e.g. web gallery). */
app.get('/api/app/config', (req, res) => {
  res.json(publicConfig(getSettings(), req.query.platform, Number(req.query.build) || 0, false));
});

function publicConfig(s, platform, build, blocked) {
  const url = platform === 'ios' ? s.update_url_ios : s.update_url_android;
  return {
    force_update: build > 0 && build < Number(s.min_build),
    update_available: build > 0 && build < Number(s.latest_build),
    latest_version: s.latest_version,
    update_url: url || '',
    update_message: s.update_message,
    maintenance: !!s.maintenance,
    maintenance_message: s.maintenance_message,
    announcement: s.announcement || '',
    blocked,
    features: {
      assistant: !!s.feature_assistant,
      vision: !!s.feature_vision,
      navigation: !!s.feature_navigation,
      sos: !!s.feature_sos,
    },
    assistant_available: !!getSecret(PROVIDERS[s.ai_provider === 'openai' ? 'openai' : 'gemini'].keyName),
    stt_engine: s.stt_engine === 'openai' && getSecret('OPENAI_API_KEY') ? 'openai' : 'device',
    tts_engine: s.tts_engine === 'openai' && getSecret('OPENAI_API_KEY') ? 'openai' : 'device',
    emergency_number: s.emergency_number,
  };
}

/**
 * What the app can DO. Sent with plain (no-photo) questions so the assistant
 * answers with an action instead of «لا يمكنني» when the app's own rules missed
 * a phrasing. Kept in code (not the editable prompt) because the app parses it.
 */
const ACTIONS_PROMPT = `
تطبيق حدق على جوال المستخدم يستطيع تنفيذ هذه الأفعال، فلا تقل أبدًا «لا أستطيع» عنها، بل اطلب تنفيذها في الحقل action:
- call: اتصال بشخص من جهات الاتصال أو برقم. who = الاسم أو الرقم كما قاله، أو "" إن لم يحدد.
- emergency_call: اتصال بالطوارئ. service = "اسعاف" أو "شرطه" أو "".
- message: رسالة واتساب أو نصية. who = المستلم أو "". text = نص الرسالة أو "". channel = "whatsapp" أو "sms".
- open_app: فتح تطبيق مثبت. app = اسمه.
- places: البحث عن مكان قريب أو باسمه. place = نوعه أو اسمه. go = true إن طلب الذهاب أو الإرشاد إليه.
- maps: الملاحة بخرائط جوجل. place = المكان أو "".
- ride: طلب سيارة (أوبر، كريم، بولت، جيني، وصلني). app = اسم التطبيق أو "". place = الوجهة أو "".
- camera: الطلب يحتاج رؤية شيء أمام المستخدم (نقود، نص، دواء، منتج، مكان، لون) ولا توجد صورة. question = ما يريد معرفته.
  مهم جدًا: لا توجد صورة مع هذا السؤال. لا تصف ولا تخمّن أبدًا أي شيء أمامه أو في يده (اسم دواء، رقم، لون، نص)؛ اختر camera دائمًا.
- memory: يسأل عما يتذكره التطبيق عنه. where_am_i: يسأل عن موقعه.
- none: سؤال عام أو حديث تجيب عنه بنفسك.
افهم الطلب حتى لو كان غير واضح أو بلهجة أو فيه أخطاء تفريغ صوتي، واختر أقرب فعل منطقي. إن كان غامضًا جدًا فاسأله سؤالًا قصيرًا محددًا بخيارين.
أضف إلى JSON الحقل "action": {"type": "...", ...}. عند وجود فعل اجعل answer جملة قصيرة جدًا.
ما لا يستطيعه التطبيق بعد: التذكيرات والمنبهات والمواعيد وجدولة المهام. إن طُلبت فقل بصراحة إنها غير متاحة بعد، ولا تعد أبدًا بتذكير.`;

/** AI proxy: the Gemini key never leaves the server. */
app.post('/api/ai/ask', async (req, res) => {
  const b = req.body || {};
  if (!validId(b.device_id)) return res.status(400).json({ error: 'device_id' });
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(b.device_id);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (user.blocked) return res.status(403).json({ error: 'blocked' });
  const s = getSettings();
  const vision = !!b.image_b64;
  if (!s.feature_assistant || (vision && !s.feature_vision)) return res.status(503).json({ error: 'feature_off' });
  if (limit(`ai:${b.device_id}`, 20, 60_000)) return res.status(429).json({ error: 'rate' });
  if (s.ai_daily_limit > 0 && limit(`aiday:${b.device_id}`, s.ai_daily_limit, 86_400_000)) {
    return res.status(429).json({ error: 'daily_limit' });
  }
  const provider = s.ai_provider === 'openai' ? 'openai' : 'gemini';
  const key = getSecret(PROVIDERS[provider].keyName);
  if (!key) return res.status(503).json({ error: 'no_key' });

  const system = s.ai_system_prompt + (b.actions && !vision ? ACTIONS_PROMPT : '') +
    (b.user_context ? `

معلومات عن المستخدم (من ذاكرته): ${String(b.user_context).slice(0, 500)}` : '');
  const history = (Array.isArray(b.history) ? b.history : []).slice(-6).map(([u, a]) => [String(u), String(a)]);
  const question = String(b.question || '').slice(0, 2000);
  const image = vision ? String(b.image_b64) : null;

  try {
    const out = provider === 'openai'
      ? await askOpenAI({ key, model: s.ai_model_openai, system, history, question, image })
      : await askGemini({ key, model: s.ai_model, system, history, question, image });
    if (!out.ok) {
      audit('ai_error', `${provider} ${out.status} ${out.error || ''}`);
      return res.status(502).json({ error: 'upstream', status: out.status });
    }
    db.prepare(`UPDATE users SET ai_requests = ai_requests + 1, vision_requests = vision_requests + ?, last_seen = ? WHERE id = ?`)
      .run(vision ? 1 : 0, now(), b.device_id);
    res.json({ text: out.text, provider });
  } catch (e) {
    res.status(502).json({ error: 'network' });
  }
});

// ---------------------------------------------------------------- speech to text
app.post('/api/stt', async (req, res) => {
  const b = req.body || {};
  const user = knownDevice(b.device_id);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (limit(`stt:${b.device_id}`, 40, 60_000)) return res.status(429).json({ error: 'rate' });
  const key = getSecret('OPENAI_API_KEY');
  if (!key) return res.status(503).json({ error: 'no_key' });
  const audio = Buffer.from(String(b.audio_b64 || ''), 'base64');
  if (audio.length < 1000 || audio.length > 4_000_000) return res.status(400).json({ error: 'bad_audio' });
  const s = getSettings();
  const form = new FormData();
  form.append('file', new Blob([audio], { type: 'audio/mp4' }), 'speech.m4a');
  form.append('model', s.stt_model || 'gpt-4o-mini-transcribe');
  form.append('language', 'ar');
  // No vocabulary prompt: on unclear/silent audio the model tends to echo the prompt
  // back as if it had been said (tested), which would trigger commands nobody gave.
  form.append('response_format', 'json');
  try {
    const r = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST', headers: { Authorization: `Bearer ${key}` }, body: form,
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      audit('stt_error', `${r.status} ${j?.error?.message || ''}`);
      return res.status(502).json({ error: 'upstream' });
    }
    let text = String(j.text || '').trim();
    // Guard against the known hallucinations on non-speech audio.
    if (/^(ترجمة|اشترك|شكرا للمشاهدة|subtitles|thank you)/i.test(text) || text.length > 400) text = '';
    // Now and then the model writes Arabic speech in Latin/Greek letters («Nam», «Ναι»):
    // ask once more for Arabic script (only when there was real speech).
    const foreign = (text.match(/[a-zͰ-Ͽ]/gi) || []).length;
    if (foreign > 1 && foreign > text.replace(/\s/g, '').length / 2) {
      const f2 = new FormData();
      f2.append('file', new Blob([audio], { type: 'audio/mp4' }), 'speech.m4a');
      f2.append('model', s.stt_model || 'gpt-4o-mini-transcribe');
      f2.append('language', 'ar');
      f2.append('prompt', 'اكتب الكلام العربي بالحروف العربية.');
      f2.append('response_format', 'json');
      try {
        const r2 = await fetch('https://api.openai.com/v1/audio/transcriptions', { method: 'POST', headers: { Authorization: `Bearer ${key}` }, body: f2 });
        const j2 = await r2.json().catch(() => ({}));
        const again = String(j2.text || '').trim();
        if (r2.ok && again && !again.includes('اكتب الكلام العربي')) text = again;
      } catch { /* keep the first result */ }
    }
    res.json({ text });
  } catch {
    res.status(502).json({ error: 'network' });
  }
});

// ---------------------------------------------------------------- text to speech (GPT voice)
// Spoken replies are generated with OpenAI TTS. Identical phrases (greetings, prompts,
// guidance lines) are cached on disk so they play instantly the next time.
const ttsDir = path.join(__dirname, 'data', 'tts-cache');
fs.mkdirSync(ttsDir, { recursive: true });
const TTS_CACHE_MAX = 6000; // originals + compressed copies

function pruneTtsCache() {
  try {
    const files = fs.readdirSync(ttsDir).map((f) => ({ f, t: fs.statSync(path.join(ttsDir, f)).atimeMs }));
    if (files.length <= TTS_CACHE_MAX) return;
    files.sort((a, b) => a.t - b.t).slice(0, files.length - TTS_CACHE_MAX)
      .forEach(({ f }) => fs.rmSync(path.join(ttsDir, f), { force: true }));
  } catch { /* ignore */ }
}
setInterval(pruneTtsCache, 3_600_000).unref();

/**
 * GPT voice. GET so the phone's media player can stream it: playback starts with the
 * first chunk while OpenAI is still generating the rest. POST is kept for tests.
 *   /api/tts.mp3?d=<device_id>&t=<text>
 */
async function ttsHandler(req, res) {
  const src = req.method === 'GET' ? req.query : (req.body || {});
  const deviceId = String(src.d || src.device_id || '');
  const user = knownDevice(deviceId);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (limit(`tts:${deviceId}`, 90, 60_000)) return res.status(429).json({ error: 'rate' });
  const key = getSecret('OPENAI_API_KEY');
  if (!key) return res.status(503).json({ error: 'no_key' });
  const text = String(src.t || src.text || '').trim().slice(0, 1200);
  if (!text) return res.status(400).json({ error: 'empty' });
  return sendTts(res, key, text);
}

/** Speech-quality mono MP3 (40 kbps) next to the cached original; made once, on first use. */
function compressedTts(file) {
  const small = file.replace(/\.mp3$/, '.s.mp3');
  if (fs.existsSync(small)) return Promise.resolve(small);
  return new Promise((resolve) => {
    execFile('ffmpeg', ['-y', '-loglevel', 'error', '-i', file, '-ac', '1', '-ar', '24000', '-b:a', '40k', small], { timeout: 15000 },
      (err) => resolve(err ? null : small));
  });
}

/** Streams the GPT voice for [text] (disk-cached by text + voice settings). */
async function sendTts(res, key, text) {
  const s = getSettings();
  const hash = crypto.createHash('sha256').update(`${s.tts_model}|${s.tts_voice}|${s.tts_instructions}|${text}`).digest('hex');
  const file = path.join(ttsDir, `${hash}.mp3`);
  if (fs.existsSync(file)) {
    const t = new Date();
    try { fs.utimesSync(file, t, t); } catch { /* ignore */ }
    res.set('X-Cache', 'hit').set('Cache-Control', 'private, max-age=86400');
    // Serve the compressed copy: ~6x smaller, so it plays smoothly on slow connections.
    const small = await compressedTts(file);
    return res.sendFile(small || file, { headers: { 'Content-Type': 'audio/mpeg' } });
  }
  try {
    const r = await fetch('https://api.openai.com/v1/audio/speech', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: s.tts_model, voice: s.tts_voice, input: text, instructions: s.tts_instructions, response_format: 'mp3' }),
    });
    if (!r.ok || !r.body) {
      const j = await r.json().catch(() => ({}));
      audit('tts_error', `${r.status} ${j?.error?.message || ''}`);
      return res.status(502).json({ error: 'upstream' });
    }
    res.set('Content-Type', 'audio/mpeg').set('X-Cache', 'miss').set('Cache-Control', 'no-store');
    res.flushHeaders();
    const chunks = [];
    const reader = r.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(Buffer.from(value));
      res.write(value);
    }
    res.end();
    fs.writeFile(file, Buffer.concat(chunks), (err) => { if (!err) compressedTts(file); });
  } catch {
    if (!res.headersSent) res.status(502).json({ error: 'network' });
    else res.end();
  }
}
app.get('/api/tts.mp3', ttsHandler);
app.post('/api/tts', ttsHandler);

// ---------------------------------------------------------------- places & walking routes
const validCoord = (lat, lon) => Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
const knownDevice = (id) => validId(id) && db.prepare('SELECT blocked FROM users WHERE id = ?').get(id);

/** «أين أقرب محل شاورما؟» -> nearest matching places. */
app.post('/api/places/search', async (req, res) => {
  const b = req.body || {};
  const user = knownDevice(b.device_id);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (!getSettings().feature_navigation) return res.status(503).json({ error: 'feature_off' });
  if (limit(`places:${b.device_id}`, 20, 60_000)) return res.status(429).json({ error: 'rate' });
  const lat = Number(b.lat), lon = Number(b.lon), query = String(b.query || '').trim().slice(0, 80);
  if (!query || !validCoord(lat, lon)) return res.status(400).json({ error: 'bad_request' });
  try {
    const out = await searchPlaces({ query, lat, lon, googleKey: getSecret('GOOGLE_MAPS_KEY') });
    res.json(out);
  } catch (e) {
    audit('maps_error', `search ${e.message}`);
    res.status(502).json({ error: 'upstream' });
  }
});

/** Walking route with Arabic step-by-step instructions. */
app.post('/api/route', async (req, res) => {
  const b = req.body || {};
  const user = knownDevice(b.device_id);
  if (!user) return res.status(403).json({ error: 'unknown_device' });
  if (!getSettings().feature_navigation) return res.status(503).json({ error: 'feature_off' });
  if (limit(`route:${b.device_id}`, 20, 60_000)) return res.status(429).json({ error: 'rate' });
  const from = [Number(b.from?.[0]), Number(b.from?.[1])];
  const to = [Number(b.to?.[0]), Number(b.to?.[1])];
  if (!validCoord(...from) || !validCoord(...to)) return res.status(400).json({ error: 'bad_request' });
  try {
    res.json(await walkingRoute({ from, to, googleKey: getSecret('GOOGLE_MAPS_KEY') }));
  } catch (e) {
    audit('maps_error', `route ${e.message}`);
    res.status(502).json({ error: 'no_route' });
  }
});

// ---------------------------------------------------------------- admin API
app.post('/admin/api/login', (req, res) => {
  if (limit(`login:${req.ip}`, 10, 15 * 60_000)) return res.status(429).json({ error: 'rate' });
  const { user, password } = req.body || {};
  const ok = user === ADMIN_USER && typeof password === 'string' &&
    password.length === ADMIN_PASSWORD.length &&
    crypto.timingSafeEqual(Buffer.from(password), Buffer.from(ADMIN_PASSWORD));
  if (!ok) { audit('login_failed', req.ip); return res.status(401).json({ error: 'bad_credentials' }); }
  const token = sign({ u: user, exp: Date.now() + 7 * 86_400_000 });
  const secure = req.secure || req.headers['x-forwarded-proto'] === 'https' ? '; Secure' : '';
  res.set('Set-Cookie', `hadaq_admin=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=604800${secure}`);
  audit('login', req.ip);
  res.json({ ok: true });
});

app.post('/admin/api/logout', (req, res) => {
  res.set('Set-Cookie', 'hadaq_admin=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
  res.json({ ok: true });
});

app.get('/admin/api/me', requireAdmin, (req, res) => res.json({ user: ADMIN_USER }));

app.get('/admin/api/stats', requireAdmin, (req, res) => {
  const day = new Date(Date.now() - 86_400_000).toISOString();
  const week = new Date(Date.now() - 7 * 86_400_000).toISOString();
  const one = (sql, ...a) => db.prepare(sql).get(...a);
  res.json({
    users: one('SELECT COUNT(*) n FROM users').n,
    active_day: one('SELECT COUNT(*) n FROM users WHERE last_seen > ?', day).n,
    active_week: one('SELECT COUNT(*) n FROM users WHERE last_seen > ?', week).n,
    new_week: one('SELECT COUNT(*) n FROM users WHERE first_seen > ?', week).n,
    blocked: one('SELECT COUNT(*) n FROM users WHERE blocked = 1').n,
    ai_requests: one('SELECT COALESCE(SUM(ai_requests),0) n FROM users').n,
    vision_requests: one('SELECT COALESCE(SUM(vision_requests),0) n FROM users').n,
    platforms: db.prepare('SELECT platform, COUNT(*) n FROM users GROUP BY platform').all(),
    versions: db.prepare('SELECT app_version, build, COUNT(*) n FROM users GROUP BY app_version, build ORDER BY build DESC').all(),
    provider: getSettings().ai_provider,
    key_set: !!getSecret(PROVIDERS[getSettings().ai_provider === 'openai' ? 'openai' : 'gemini'].keyName),
    audit: db.prepare('SELECT at, action, detail FROM audit ORDER BY id DESC LIMIT 15').all(),
  });
});

app.get('/admin/api/settings', requireAdmin, (req, res) => res.json(getSettings()));

app.put('/admin/api/settings', requireAdmin, (req, res) => {
  const b = req.body || {};
  const up = db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value');
  const changed = [];
  for (const [k, def] of Object.entries(DEFAULT_SETTINGS)) {
    if (!(k in b)) continue;
    let v = b[k];
    if (typeof def === 'number') v = Number(v);
    if (typeof def === 'boolean') v = !!v;
    if (typeof def === 'string') v = String(v ?? '').slice(0, 6000);
    if (typeof def === 'number' && !Number.isFinite(v)) continue;
    up.run(k, JSON.stringify(v));
    changed.push(k);
  }
  const s = getSettings();
  if (!['gemini', 'openai'].includes(s.ai_provider)) up.run('ai_provider', JSON.stringify('gemini'));
  if (s.min_build > s.latest_build) up.run('latest_build', JSON.stringify(s.min_build));
  audit('settings', changed.join(', '));
  res.json(getSettings());
});

app.get('/admin/api/keys', requireAdmin, (req, res) => {
  const rows = db.prepare('SELECT name, value_enc, note, updated_at FROM secrets ORDER BY name').all();
  res.json(rows.map((r) => {
    let m = '••••';
    try { m = mask(decrypt(r.value_enc)); } catch { /* unreadable */ }
    return { name: r.name, masked: m, note: r.note, updated_at: r.updated_at };
  }));
});

app.put('/admin/api/keys/:name', requireAdmin, (req, res) => {
  const name = req.params.name;
  if (!/^[A-Z][A-Z0-9_]{1,63}$/.test(name)) return res.status(400).json({ error: 'name' });
  const value = String(req.body?.value || '').trim();
  if (!value) return res.status(400).json({ error: 'value' });
  db.prepare(`INSERT INTO secrets (name, value_enc, note, updated_at) VALUES (?, ?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET value_enc = excluded.value_enc, note = excluded.note, updated_at = excluded.updated_at`)
    .run(name, encrypt(value), String(req.body?.note || '').slice(0, 200), now());
  audit('key_set', name);
  res.json({ ok: true });
});

app.delete('/admin/api/keys/:name', requireAdmin, (req, res) => {
  db.prepare('DELETE FROM secrets WHERE name = ?').run(req.params.name);
  audit('key_deleted', req.params.name);
  res.json({ ok: true });
});

/** Checks a provider key (and the chosen model) without spending tokens. */
app.post('/admin/api/keys/:name/test', requireAdmin, async (req, res) => {
  const name = req.params.name;
  const key = getSecret(name);
  if (!key) return res.json({ ok: false, message: 'المفتاح غير موجود' });
  const s = getSettings();
  try {
    if (name === 'OPENAI_API_KEY') {
      const r = await fetch(`https://api.openai.com/v1/models/${encodeURIComponent(s.ai_model_openai)}`, {
        headers: { Authorization: `Bearer ${key}` },
      });
      if (r.ok) return res.json({ ok: true, message: `المفتاح يعمل، والنموذج ${s.ai_model_openai} متاح` });
      if (r.status === 404) return res.json({ ok: false, message: `المفتاح يعمل، لكن النموذج ${s.ai_model_openai} غير متاح لحسابك` });
      return res.json({ ok: false, message: `رفضه OpenAI (${r.status})` });
    }
    if (name === 'GEMINI_API_KEY') {
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(s.ai_model)}`, {
        headers: { 'x-goog-api-key': key },
      });
      if (r.ok) return res.json({ ok: true, message: `المفتاح يعمل، والنموذج ${s.ai_model} متاح` });
      if (r.status === 404) return res.json({ ok: false, message: `المفتاح يعمل، لكن النموذج ${s.ai_model} غير موجود` });
      return res.json({ ok: false, message: `رفضه Google (${r.status})` });
    }
    if (name === 'GOOGLE_MAPS_KEY') {
      const r = await fetch('https://places.googleapis.com/v1/places:searchText', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': key, 'X-Goog-FieldMask': 'places.displayName' },
        body: JSON.stringify({ textQuery: 'صيدلية في جدة', pageSize: 1, languageCode: 'ar' }),
      });
      const j = await r.json().catch(() => ({}));
      if (r.ok) return res.json({ ok: true, message: 'المفتاح يعمل، والبحث عن الأماكن عبر Google مفعّل' });
      return res.json({ ok: false, message: `رفضه Google (${r.status}) ${j?.error?.status || ''} — فعّل Places API (New) وRoutes API في المشروع` });
    }
    res.json({ ok: false, message: 'لا يوجد اختبار لهذا المفتاح' });
  } catch {
    res.json({ ok: false, message: 'تعذّر الاتصال بالمزوّد' });
  }
});

app.get('/admin/api/users', requireAdmin, (req, res) => {
  const q = String(req.query.q || '').trim();
  const page = Math.max(1, Number(req.query.page) || 1);
  const size = 25;
  const where = q ? `WHERE id LIKE ? OR device_model LIKE ? OR app_version LIKE ? OR note LIKE ? OR profile LIKE ?` : '';
  const args = q ? Array(5).fill(`%${q}%`) : [];
  const total = db.prepare(`SELECT COUNT(*) n FROM users ${where}`).get(...args).n;
  const rows = db.prepare(`SELECT * FROM users ${where} ORDER BY last_seen DESC LIMIT ? OFFSET ?`)
    .all(...args, size, (page - 1) * size);
  res.json({ total, page, size, rows });
});

/** One user's shared data: profile, latest location + trail, conversation log. */
app.get('/admin/api/users/:id', requireAdmin, (req, res) => {
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(req.params.id);
  if (!u) return res.status(404).json({ error: 'not_found' });
  const page = Math.max(1, Number(req.query.page) || 1);
  const size = 50;
  let profile = null;
  try { profile = u.profile ? JSON.parse(u.profile) : null; } catch { /* ignore */ }
  audit('user_viewed', req.params.id);
  res.json({
    user: { ...u, profile: undefined },
    profile,
    locations: db.prepare('SELECT at, lat, lon, accuracy FROM locations WHERE device_id = ? ORDER BY at DESC LIMIT 100').all(req.params.id),
    conversations: db.prepare('SELECT at, user_text, intent, reply FROM conversations WHERE device_id = ? ORDER BY at DESC LIMIT ? OFFSET ?')
      .all(req.params.id, size, (page - 1) * size),
    conversation_total: db.prepare('SELECT COUNT(*) n FROM conversations WHERE device_id = ?').get(req.params.id).n,
    page, size,
  });
});

app.delete('/admin/api/users/:id/data', requireAdmin, (req, res) => {
  wipeUserData(req.params.id);
  audit('user_data_deleted', req.params.id);
  res.json({ ok: true });
});

app.patch('/admin/api/users/:id', requireAdmin, (req, res) => {
  const b = req.body || {};
  if ('blocked' in b) db.prepare('UPDATE users SET blocked = ? WHERE id = ?').run(b.blocked ? 1 : 0, req.params.id);
  if ('note' in b) db.prepare('UPDATE users SET note = ? WHERE id = ?').run(String(b.note).slice(0, 200), req.params.id);
  audit(b.blocked ? 'user_blocked' : 'user_updated', req.params.id);
  res.json(db.prepare('SELECT * FROM users WHERE id = ?').get(req.params.id));
});

// ---------------------------------------------------------------- dashboard
// Public site: landing page at /, privacy policy at /privacy, the web app at /app/.
const noCacheEntry = (res, file) => {
  // Always revalidate entry files so a new build shows up right away.
  if (/(index\.html|privacy\.html|flutter_bootstrap\.js|flutter_service_worker\.js|version\.json)$/.test(file)) {
    res.set('Cache-Control', 'no-cache');
  }
};
const webDir = path.join(__dirname, 'web');
const landingDir = path.join(__dirname, 'landing');

/** Tiny runtime config for the landing page (the Google Play link, set from the dashboard). */
app.get('/config.js', (req, res) => {
  const url = String(getSettings().play_url || '');
  res.set('Content-Type', 'application/javascript; charset=utf-8').set('Cache-Control', 'no-cache');
  res.send(url ? `window.HADAQ_PLAY_URL=${JSON.stringify(url)};` : '');
});
/** Temporary: the Play bundle, fetchable by Play Console's page for upload (CORS to play.google.com only). */
app.get('/download/hadaq-play.aab', (req, res) => {
  const f = path.join(__dirname, 'downloads', 'hadaq-play.aab');
  if (!fs.existsSync(f)) return res.status(404).send('not here');
  res.set('Access-Control-Allow-Origin', 'https://play.google.com');
  res.set('Content-Type', 'application/octet-stream');
  res.sendFile(f);
});

/** Direct APK download (the «direct» build, uploaded to ./downloads/hadaq.apk). */
app.get(['/download/hadaq.apk', '/download/android'], (req, res) => {
  const f = path.join(__dirname, 'downloads', 'hadaq.apk');
  if (!fs.existsSync(f)) return res.status(404).send('APK not uploaded yet');
  res.set('Content-Type', 'application/vnd.android.package-archive');
  res.set('Cache-Control', 'no-cache');
  res.download(f, 'hadaq.apk');
});
/** Tester signup: saves the email so the team can see who joined, returns the next steps. */
app.post('/api/testers', (req, res) => {
  if (limit(`testers:${req.ip}`, 10, 3_600_000)) return res.status(429).json({ error: 'rate' });
  const b = req.body || {};
  const email = String(b.email || '').trim().toLowerCase().slice(0, 200);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return res.status(400).json({ error: 'email' });
  const name = String(b.name || '').trim().slice(0, 80);
  const device = String(b.device || '').trim().slice(0, 80);
  db.prepare(`INSERT INTO testers (email, name, device, created_at, ip) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(email) DO UPDATE SET name = COALESCE(NULLIF(excluded.name, ''), name), device = COALESCE(NULLIF(excluded.device, ''), device)`)
    .run(email, name, device, now(), req.ip);
  const s = getSettings();
  res.json({ ok: true, group_url: s.tester_group_url, optin_url: s.tester_optin_url, play_url: s.play_url });
});

/** Public counter for the signup page («انضم 7 من 12»). */
app.get('/api/testers/count', (req, res) => {
  const s = getSettings();
  res.json({ count: db.prepare('SELECT COUNT(*) n FROM testers').get().n, target: Number(s.tester_target) || 12,
    group_url: s.tester_group_url, optin_url: s.tester_optin_url });
});

app.get('/admin/api/testers', requireAdmin, (req, res) => {
  res.json(db.prepare('SELECT id, email, name, device, created_at, note FROM testers ORDER BY created_at DESC').all());
});
app.delete('/admin/api/testers/:id', requireAdmin, (req, res) => {
  db.prepare('DELETE FROM testers WHERE id = ?').run(Number(req.params.id));
  audit('tester_deleted', req.params.id);
  res.json({ ok: true });
});

mountSurvey({ app, db, getSecret, getSettings, limit, audit, now, requireAdmin, sendTts, landingDir, dir: __dirname });

app.get(['/test', '/testers'], (req, res) => res.sendFile(path.join(landingDir, 'test.html'), { headers: { 'Cache-Control': 'no-cache' } }));
app.get('/privacy', (req, res) => res.sendFile(path.join(landingDir, 'privacy.html'), { headers: { 'Cache-Control': 'no-cache' } }));
if (fs.existsSync(path.join(webDir, 'index.html'))) {
  app.use('/app', express.static(webDir, { setHeaders: noCacheEntry }));
}
if (fs.existsSync(path.join(landingDir, 'index.html'))) {
  app.use('/', express.static(landingDir, { setHeaders: noCacheEntry, extensions: ['html'] }));
} else {
  app.get('/', (req, res) => res.redirect('/app/'));
}
app.use('/admin', express.static(path.join(__dirname, 'public'), { index: 'index.html' }));

app.listen(PORT, () => console.log(`Hadaq server on http://localhost:${PORT}  (dashboard: /admin)`));
