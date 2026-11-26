// Voice survey for blind and low-vision users (hadaq.waal.dev/survey).
//
// The page reads each question aloud with the GPT voice, records the spoken answer,
// and this module transcribes it and lets the AI map it onto the question's options
// (dialect, synonyms, "all of them", ages to ranges…). Answers are stored here and,
// when enabled, forwarded to the original Google Form so its sheet stays complete.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const SESSION_TTL = 3 * 3600_000;
const AI_MODEL = 'gpt-4.1-mini';

/** Arabic folding for quick exact matches (same idea as the app's normalizeAr). */
const norm = (s) => String(s || '')
  .replace(/[ً-ْـ]/g, '')
  .replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي').replace(/ئ/g, 'ي').replace(/ؤ/g, 'و')
  .replace(/[^\p{L}\p{N}\s]/gu, ' ').replace(/\s+/g, ' ').trim().toLowerCase();

function loadSurvey(file) {
  const s = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const q of s.questions) {
    q.speak = speakQuestion(q);
  }
  return s;
}

/** The question as it is read aloud: the question, then its choices. */
function speakQuestion(q) {
  if (q.type === 'text') return q.q;
  const says = q.options.map((o) => o.say);
  if (q.type === 'multi') {
    return `${q.q} مثل: ${says.join('، ')}${q.other ? '، أو غير ذلك' : ''}.`;
  }
  const last = q.other ? 'أو شيء آخر تذكره' : `أو ${says.pop()}`;
  return `${q.q} ${says.join('، ')}، ${last}.`;
}

const PHRASES = {
  listenHint: 'بعد النغمة تكلّم.',
  noHear: 'لم أسمع.',
  required: 'هذا السؤال مهم لنا، أجب ولو بكلمة.',
  first: 'هذا أول سؤال.',
  savedText: 'سجّلت إجابتك.',
  skipped: 'تخطّيته.',
  sending: 'أرسل إجاباتك الآن.',
  error: 'حدث خطأ في الاتصال. المس الشاشة وحاول مرة أخرى.',
  waitTap: 'المس الشاشة متى ما كنت جاهزًا.',
  notSaved: 'لم تُرسل الإجابات بسبب خطأ. المس الشاشة لإعادة الإرسال.',
  more: 'تضيف شيئًا آخر؟',
};

const confirmFor = (q, a) => {
  if (!a) return PHRASES.skipped;
  if (q.type === 'text') return PHRASES.savedText;
  if (q.type === 'multi' && !a.other && (a.values || []).length === q.options.length && q.options.length > 2) return 'سجّلت: كل الخيارات.';
  const parts = [...(a.values || []).map((v) => q.options.find((o) => o.v === v)?.say || v)];
  if (a.other) parts.push(a.other);
  return `سجّلت: ${parts.join('، و')}.`;
};

const SYSTEM = `أنت محلّل إجابات لاستبيان صوتي يجيب عليه مكفوفون وضعاف بصر عرب بلهجاتهم.
تستلم: السؤال، ونوعه، وخياراته مرقّمة، وما قاله المجيب كنص مفرّغ من الصوت (قد يحوي أخطاء تفريغ).
أعد JSON فقط بهذا الشكل:
{"action":"answer|repeat|back|skip|unclear|clarify","choices":[أرقام الخيارات المطابقة],"other":null أو نص,"text":null أو نص,"say":null أو جملة}
القواعد:
- answer: فهمت الإجابة. لسؤال single اختر خيارًا واحدًا فقط. لسؤال multi اختر كل ما ذُكر، و«كلها/الكل» تعني كل الخيارات.
- افهم المرادفات واللهجات: ايه/اي/أكيد/طبعًا = نعم، لا/مو/ما = لا، شوي/بعض الأحيان = أحيانًا. الأعمار بالأرقام تُطابق مع النطاق الصحيح.
- إن قال شيئًا خارج الخيارات وكان السؤال يقبل «أخرى» فضعه في other بصياغة قصيرة، واترك choices فارغة إن لم يطابق شيئًا.
- لسؤال text: ضع الإجابة في text بكلمات المجيب نفسها وبلهجته، ولا تحوّلها إلى الفصحى. صحّح أخطاء التفريغ الواضحة فقط، دون إضافة أو تلخيص.
- repeat: طلب إعادة السؤال (أعد، كرر، ما سمعت، وش قلت). back: طلب السؤال السابق. skip: طلب التخطي أو قال لا أعرف/ما عندي في سؤال اختياري أو text اختياري.
- clarify: سأل عن معنى السؤال أو الخيارات. ضع في say شرحًا بسيطًا قصيرًا ثم أعد صياغة السؤال باختصار.
- unclear: الكلام غير مفهوم أو يحتمل خيارين. ضع في say سؤالًا قصيرًا يحدد بين الأقرب، مثل: «تقصد صعب أو صعب جدًّا؟».
- say عربي فصيح بسيط، أقل من عشرين كلمة، ولا تستخدمه في answer.`;

export function mountSurvey({ app, db, getSecret, getSettings, limit, audit, now, requireAdmin, sendTts, landingDir, dir }) {
  const survey = loadSurvey(path.join(dir, 'surveys', 'hadaq-needs.json'));
  const byId = new Map(survey.questions.map((q) => [q.id, q]));

  db.exec(`CREATE TABLE IF NOT EXISTS survey_responses (
    id INTEGER PRIMARY KEY AUTOINCREMENT, survey TEXT NOT NULL, created_at TEXT NOT NULL,
    answers TEXT NOT NULL, mode TEXT, duration_s INTEGER, forwarded INTEGER DEFAULT 0, forward_status TEXT)`);

  // Fixed phrases that the page may ask the voice for. AI replies are added per session.
  const fixed = new Set([survey.intro_say, survey.outro_say, ...Object.values(PHRASES), ...survey.questions.map((q) => q.speak)]);
  for (const q of survey.questions) {
    for (const o of q.options || []) fixed.add(confirmFor(q, { values: [o.v] }));
  }
  fixed.add(PHRASES.savedText);

  const sessions = new Map();
  setInterval(() => {
    const t = Date.now();
    for (const [k, v] of sessions) if (t - v.at > SESSION_TTL) sessions.delete(k);
  }, 600_000).unref();
  const session = (sid) => (typeof sid === 'string' ? sessions.get(sid) : null);

  // Warm the voice cache so the first visitor doesn't wait on every question.
  const warm = async () => {
    const key = getSecret('OPENAI_API_KEY');
    if (!key) return;
    for (const text of fixed) {
      const sink = { set() { return sink; }, flushHeaders() {}, write() {}, end() {}, status() { return sink; }, json() {}, sendFile() {}, headersSent: false };
      try { await sendTts(sink, key, text); } catch { /* ignore */ }
    }
  };
  setTimeout(warm, 5000).unref?.();

  const publicSurvey = () => ({
    id: survey.id, title: survey.title, intro: survey.intro, intro_say: survey.intro_say, outro_say: survey.outro_say,
    phrases: PHRASES,
    questions: survey.questions.map((q) => ({
      id: q.id, type: q.type, required: !!q.required, other: !!q.other, when: q.when || null, q: q.q, speak: q.speak,
      options: (q.options || []).map((o) => ({ v: o.v, say: o.say })),
      confirms: Object.fromEntries((q.options || []).map((o) => [o.v, confirmFor(q, { values: [o.v] })])),
    })),
  });

  app.get('/survey', (req, res) => res.sendFile(path.join(landingDir, 'survey.html'), { headers: { 'Cache-Control': 'no-cache' } }));

  app.post('/api/survey/start', (req, res) => {
    if (limit(`survey-start:${req.ip}`, 30, 3_600_000)) return res.status(429).json({ error: 'rate' });
    const sid = crypto.randomBytes(16).toString('hex');
    sessions.set(sid, { at: Date.now(), started: Date.now(), allowed: new Set(), turns: 0 });
    res.json({ sid, voice: !!getSecret('OPENAI_API_KEY'), survey: publicSurvey() });
  });

  // GPT voice, only for this survey's phrases (no free text-to-speech for anyone).
  app.get('/api/survey/tts.mp3', (req, res) => {
    const s = session(String(req.query.s || ''));
    if (!s) return res.status(403).json({ error: 'session' });
    const text = String(req.query.t || '').trim();
    if (!fixed.has(text) && !s.allowed.has(text)) return res.status(403).json({ error: 'text' });
    if (limit(`survey-tts:${req.query.s}`, 120, 60_000)) return res.status(429).json({ error: 'rate' });
    const key = getSecret('OPENAI_API_KEY');
    if (!key) return res.status(503).json({ error: 'no_key' });
    s.at = Date.now();
    return sendTts(res, key, text);
  });

  const ARABIC_HINT = 'اكتب الكلام العربي بالحروف العربية.';
  async function transcribe(key, audio, mime) {
    const text = await transcribeOnce(key, audio, mime);
    // Now and then the model answers in Latin letters ("Said Gelt, Ceif"); ask again for Arabic script.
    const latin = (text.match(/[a-z]/gi) || []).length;
    if (latin > 3 && latin > text.replace(/\s/g, '').length / 2) {
      const again = await transcribeOnce(key, audio, mime, ARABIC_HINT);
      if (again && !again.includes(ARABIC_HINT.slice(0, 12))) return again; // never the hint echoed back
    }
    return text;
  }

  async function transcribeOnce(key, audio, mime, prompt) {
    const ext = /mp4|m4a|aac/.test(mime) ? 'm4a' : /mpeg|mp3/.test(mime) ? 'mp3' : /ogg/.test(mime) ? 'ogg' : /wav/.test(mime) ? 'wav' : 'webm';
    const form = new FormData();
    form.append('file', new Blob([audio], { type: mime || 'audio/webm' }), `answer.${ext}`);
    form.append('model', getSettings().stt_model || 'gpt-4o-transcribe');
    form.append('language', 'ar');
    if (prompt) form.append('prompt', prompt);
    form.append('response_format', 'json');
    const r = await fetch('https://api.openai.com/v1/audio/transcriptions', { method: 'POST', headers: { Authorization: `Bearer ${key}` }, body: form });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      audit('survey_stt_error', `${r.status} ${j?.error?.message || ''}`);
      throw new Error('stt');
    }
    let text = String(j.text || '').trim();
    if (/^(ترجمة|اشترك|شكرا للمشاهدة|subtitles|thank you)/i.test(text)) text = '';
    return text;
  }

  /** Commands and exact option names are handled without the AI (faster). */
  function quick(q, heard, adding = false) {
    // After «تضيف شيئًا آخر؟»: a plain no / that's all means move on.
    if (adding && /^(لا|لاء|خلاص|بس|لا بس|لا شكرا|لا شي|لا شيء|ما في|مافي|هذا كل شي|هذا كل شيء|كذا بس|تم|انتهيت|لا خلاص)$/.test(norm(heard))) return { action: 'done' };
    const h = norm(heard);
    if (!h) return { action: 'silence' };
    if (/^(اعد|عيد|كرر|اعيد|ما سمعت|وش قلت|ايش قلت)( السوال)?$/.test(h)) return { action: 'repeat' };
    if (/^(ارجع|رجوع|السابق|السوال السابق)$/.test(h)) return { action: 'back' };
    if (/^(تخط|تخطي|تجاوز|التالي|عدي|سكب)$/.test(h)) return { action: 'skip' };
    if (q.type === 'single') {
      // Common dialect words for yes / no / sometimes.
      const syn = { 'نعم': /^(نعم|ايه|اي|ايوه|اكيد|طبعا|اكيد نعم|ايوا|يب)$/, 'لا': /^(لا|لاء|ابدا لا|مو|لا ما)$/, 'احياناً': /^(احيانا|ساعات|بعض الاحيان|احيان)$/ };
      for (const o of q.options) if (syn[o.v]?.test(h)) return { action: 'answer', values: [o.v] };
      const exact = q.options.filter((o) => norm(o.v) === h || norm(o.say) === h);
      if (exact.length === 1) return { action: 'answer', values: [exact[0].v] };
      // A short reply that contains exactly one option's name ("ضعيف بصر يا اخوي").
      if (h.split(' ').length <= 5) {
        const inside = q.options.filter((o) => norm(o.say).length > 2 && ` ${h} `.includes(` ${norm(o.say)} `));
        const longest = inside.sort((a, b) => norm(b.say).length - norm(a.say).length);
        if (longest.length && !longest.slice(1).some((o) => !norm(longest[0].say).includes(norm(o.say)))) {
          if (!/(مو|غير|ما|لا) /.test(` ${h}`) || /^(غير|لا) /.test(norm(longest[0].say))) return { action: 'answer', values: [longest[0].v] };
        }
      }
    }
    return null;
  }

  async function interpret(key, q, heard) {
    const opts = (q.options || []).map((o, i) => `${i}: ${o.say}`).join('\n');
    const user = `السؤال: ${q.q}\nالنوع: ${q.type}${q.other ? ' (يقبل أخرى)' : ''}${q.required ? '' : ' (اختياري)'}\n${opts ? `الخيارات:\n${opts}\n` : ''}قال المجيب: «${heard}»`;
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        model: AI_MODEL, temperature: 0, max_completion_tokens: 300, response_format: { type: 'json_object' },
        messages: [{ role: 'system', content: SYSTEM }, { role: 'user', content: user }],
      }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      audit('survey_ai_error', `${r.status} ${j?.error?.message || ''}`);
      throw new Error('ai');
    }
    let o = {};
    try { o = JSON.parse(j.choices?.[0]?.message?.content || '{}'); } catch { /* unclear */ }
    const action = ['answer', 'repeat', 'back', 'skip', 'unclear', 'clarify'].includes(o.action) ? o.action : 'unclear';
    if (action !== 'answer') return { action, say: typeof o.say === 'string' ? o.say.slice(0, 220) : null };
    if (q.type === 'text') {
      const text = String(o.text || heard).trim().slice(0, 1500);
      return text ? { action, text } : { action: 'unclear' };
    }
    let idx = [...new Set((Array.isArray(o.choices) ? o.choices : []).map(Number).filter((n) => Number.isInteger(n) && n >= 0 && n < q.options.length))];
    if (q.type === 'single') idx = idx.slice(0, 1);
    const values = idx.map((i) => q.options[i].v);
    const other = q.other && o.other ? String(o.other).trim().slice(0, 200) : null;
    if (!values.length && !other) return { action: 'unclear', say: typeof o.say === 'string' ? o.say.slice(0, 220) : null };
    return { action, values, other: q.type === 'single' && values.length ? null : other };
  }

  app.post('/api/survey/turn', async (req, res) => {
    const b = req.body || {};
    const s = session(b.sid);
    if (!s) return res.status(403).json({ error: 'session' });
    if (limit(`survey-turn:${b.sid}`, 40, 60_000) || ++s.turns > 400) return res.status(429).json({ error: 'rate' });
    const q = byId.get(String(b.qid));
    if (!q) return res.status(400).json({ error: 'question' });
    const key = getSecret('OPENAI_API_KEY');
    if (!key) return res.status(503).json({ error: 'no_key' });
    s.at = Date.now();
    const t0 = Date.now();
    // One log line per spoken turn (no audio, no answer text): lets us see why a phone
    // isn't heard — meter level, audio size and format, browser.
    const diag = { q: q.id, bytes: 0, mime: String(b.mime || '').slice(0, 40), meta: b.meta && typeof b.meta === 'object' ? b.meta : null,
      ua: String(req.get('user-agent') || '').replace(/\s+/g, ' ').slice(0, 110) };
    const logTurn = (extra) => { if (b.audio_b64) audit('survey_turn', JSON.stringify({ ...diag, ...extra, ms: Date.now() - t0 }).slice(0, 500)); };
    try {
      let heard = typeof b.text === 'string' ? b.text.trim().slice(0, 1500) : '';
      if (!heard && b.audio_b64) {
        const audio = Buffer.from(String(b.audio_b64), 'base64');
        diag.bytes = audio.length;
        if (audio.length > 6_000_000) return res.status(400).json({ error: 'too_long' });
        // Under ~6 KB is a fraction of a second of audio (a muted mic): the model would invent words from it.
        heard = audio.length < 6000 ? '' : await transcribe(key, audio, String(b.mime || ''));
      }
      const adding = !!b.adding;
      const out = quick(q, heard, adding) || await interpret(key, q, heard);
      if (out.action === 'skip' && adding) out.action = 'done';
      if (out.action === 'skip' && q.required) Object.assign(out, { action: 'unclear', say: PHRASES.required });
      if (out.action === 'answer') out.say = q.type === 'text' ? PHRASES.savedText : confirmFor(q, out);
      if (out.say) s.allowed.add(out.say);
      logTurn({ heardLen: heard.length, action: out.action });
      res.json({ heard, ...out });
    } catch (e) {
      logTurn({ error: String(e.message || e).slice(0, 40) });
      res.status(502).json({ error: 'upstream' });
    }
  });

  /** Checks the page's answers against the survey and returns them cleaned. */
  function clean(answers) {
    const out = {};
    for (const q of survey.questions) {
      const a = answers?.[q.id];
      if (!a) continue;
      if (q.type === 'text') {
        const t = String(a.text || '').trim().slice(0, 1500);
        if (t) out[q.id] = { text: t };
        continue;
      }
      const vals = (Array.isArray(a.values) ? a.values : []).filter((v) => q.options.some((o) => o.v === v));
      const one = q.type === 'single' ? vals.slice(0, 1) : [...new Set(vals)];
      const other = q.other && a.other ? String(a.other).trim().slice(0, 200) : null;
      if (one.length || other) out[q.id] = { values: one, ...(other && !(q.type === 'single' && one.length) ? { other } : {}) };
    }
    return out;
  }

  async function forward(answers) {
    const p = new URLSearchParams();
    for (const q of survey.questions) {
      const a = answers[q.id];
      if (!a) continue;
      const k = `entry.${q.entry}`;
      if (q.type === 'text') p.append(k, a.text);
      else {
        for (const v of a.values) p.append(k, v);
        if (a.other) { p.append(k, '__other_option__'); p.append(`${k}.other_option_response`, a.other); }
      }
    }
    p.append('fvv', '1');
    p.append('pageHistory', '0');
    const r = await fetch(survey.form_action, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: p, redirect: 'manual' });
    return r.status;
  }

  app.post('/api/survey/submit', async (req, res) => {
    const b = req.body || {};
    const s = session(b.sid);
    if (!s) return res.status(403).json({ error: 'session' });
    if (s.submitted) return res.json({ ok: true, duplicate: true });
    const answers = clean(b.answers);
    const missing = survey.questions.filter((q) => q.required && !answers[q.id]).map((q) => q.id);
    if (missing.length) return res.status(400).json({ error: 'missing', missing });
    s.submitted = true;
    const mode = b.mode === 'text' ? 'text' : b.mode === 'mixed' ? 'mixed' : 'voice';
    const dur = Math.round((Date.now() - s.started) / 1000);
    const row = db.prepare('INSERT INTO survey_responses (survey, created_at, answers, mode, duration_s) VALUES (?, ?, ?, ?, ?)')
      .run(survey.id, now(), JSON.stringify(answers), mode, dur);
    res.json({ ok: true });
    if (getSettings().survey_forward_google && !b.test) {
      try {
        const st = await forward(answers);
        db.prepare('UPDATE survey_responses SET forwarded = ?, forward_status = ? WHERE id = ?').run(st === 200 ? 1 : 0, String(st), row.lastInsertRowid);
      } catch (e) {
        db.prepare('UPDATE survey_responses SET forward_status = ? WHERE id = ?').run(`error ${e.message}`.slice(0, 60), row.lastInsertRowid);
      }
    }
  });

  // ---------------------------------------------------------------- dashboard
  app.get('/admin/api/survey', requireAdmin, (req, res) => {
    const rows = db.prepare('SELECT * FROM survey_responses WHERE survey = ? ORDER BY created_at DESC').all(survey.id)
      .map((r) => ({ ...r, answers: JSON.parse(r.answers) }));
    const tallies = survey.questions.map((q) => {
      const t = { id: q.id, q: q.q, type: q.type, answered: 0, counts: {}, others: [], texts: [] };
      for (const o of q.options || []) t.counts[o.v] = 0;
      for (const r of rows) {
        const a = r.answers[q.id];
        if (!a) continue;
        t.answered++;
        if (q.type === 'text') t.texts.push(a.text);
        else {
          for (const v of a.values || []) t.counts[v] = (t.counts[v] || 0) + 1;
          if (a.other) t.others.push(a.other);
        }
      }
      return t;
    });
    res.json({ title: survey.title, total: rows.length, voice: rows.filter((r) => r.mode !== 'text').length, rows, tallies });
  });

  app.delete('/admin/api/survey/:id', requireAdmin, (req, res) => {
    db.prepare('DELETE FROM survey_responses WHERE id = ?').run(Number(req.params.id));
    audit('survey_deleted', req.params.id);
    res.json({ ok: true });
  });
}
