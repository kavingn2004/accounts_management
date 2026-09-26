// The server-side half of Ask, for the deployed build only.
//
// A Flutter web bundle is public: anything passed by --dart-define is readable
// in main.dart.js, so the app can never hold a provider key. It posts here
// instead, and this function adds the key that only Netlify knows.
//
// The app speaks the OpenAI `/chat/completions` shape (see
// lib/services/ask/llm_client.dart), so this is a pass-through rather than a
// translation: same request shape in, provider's JSON straight back out. That
// keeps a single Dart client working against Ollama locally and against Groq
// on the deployed site, with nothing between them but a base URL.
//
// Netlify environment variables (Site settings -> Environment variables):
//   GROQ_API_KEY  = gsk_...        required; without it Ask falls back to
//                                  keyword routing exactly as it does today
//   GROQ_MODEL    = <model id>     optional; defaults to DEFAULT_MODEL

const UPSTREAM = 'https://api.groq.com/openai/v1/chat/completions';

/// Routing needs a model that can pick one name off a list, not a clever one.
const DEFAULT_MODEL = 'llama-3.1-8b-instant';

/// Room for the app's real request and no more.
///
/// Most of that is the system prompt, which carries the whole tool catalogue —
/// about 3 KB today and it grows with every tool added. The first cut of this
/// was 4 KB, which a live request cleared by only a kilobyte; a couple of new
/// tools would have started rejecting honest questions. Size is the weakest of
/// the guards anyway. What bounds the bill is max_tokens below.
const MAX_BODY_BYTES = 16_384;
const MAX_MESSAGES = 4;
const MAX_CONTENT_CHARS = 8000;

/// One line of routing takes Groq well under a second. A request still
/// running after ten is not going to produce a useful answer.
const UPSTREAM_TIMEOUT_MS = 10_000;

/// Every figure the model is allowed to influence, fixed here rather than
/// taken from the caller. This is the cost ceiling: whatever anyone posts,
/// the bill is one 8B-model call capped at forty tokens.
const FIXED = { temperature: 0, max_tokens: 40, stream: false };

/// A rejection with the status the caller should see.
///
/// Every one of these reaches the app as a non-200, which its client already
/// turns into LlmUnavailable — so the app falls back to keyword routing
/// rather than showing an error. There is no failure here that breaks Ask.
export class Rejected extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/// True when the browser that sent this is looking at our own site.
///
/// Browsers set Origin on every POST, and cannot be talked out of it by page
/// script, so this costs a stranger's page nothing to obey and everything to
/// forge. It is a lock on the front door, not a vault: a direct client can
/// send any Origin it likes, which is why the token cap above is the real
/// protection. Deploy previews pass because the origin they serve from is
/// also the origin they request.
export function sameOrigin(requestUrl, origin) {
  if (!origin) return false;
  try {
    return new URL(origin).host === new URL(requestUrl).host;
  } catch {
    return false;
  }
}

/// Build the body to forward, taking only the parts a router legitimately
/// sends and none of the parts that cost money.
///
/// Deliberately rebuilt field by field rather than spread-and-override: a
/// spread forwards whatever a future provider decides to charge for, and this
/// endpoint is public.
export function sanitise(raw, model = DEFAULT_MODEL) {
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new Rejected(400, 'Body must be JSON');
  }

  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    throw new Rejected(400, 'Body must carry a messages array');
  }
  if (messages.length > MAX_MESSAGES) {
    throw new Rejected(400, `At most ${MAX_MESSAGES} messages`);
  }

  return {
    model,
    ...FIXED,
    messages: messages.map((m) => {
      const role = m?.role;
      const content = m?.content;
      if (role !== 'system' && role !== 'user' && role !== 'assistant') {
        throw new Rejected(400, 'Each message needs a valid role');
      }
      if (typeof content !== 'string' || content.length === 0) {
        throw new Rejected(400, 'Each message needs string content');
      }
      if (content.length > MAX_CONTENT_CHARS) {
        throw new Rejected(400, 'Message too long');
      }
      return { role, content };
    }),
  };
}

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

export default async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'POST only' });

  if (!sameOrigin(req.url, req.headers.get('origin'))) {
    return json(403, { error: 'Not allowed from this origin' });
  }

  const key = process.env.GROQ_API_KEY;
  if (!key) return json(503, { error: 'No model configured' });

  // Read as text first so the size limit applies to what actually arrived,
  // not to a Content-Length header the caller chose.
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
    return json(413, { error: 'Body too large' });
  }

  let forwarded;
  try {
    forwarded = sanitise(raw, process.env.GROQ_MODEL || DEFAULT_MODEL);
  } catch (e) {
    if (e instanceof Rejected) return json(e.status, { error: e.message });
    throw e;
  }

  // The question is the user's own words about their own money. It is not
  // logged here, and nothing else about them is: the app sends a question and
  // a tool list, computes every figure on the device, and never sends a
  // transaction, balance or holding anywhere.
  let upstream;
  try {
    upstream = await fetch(UPSTREAM, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify(forwarded),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch {
    return json(502, { error: 'Could not reach the model' });
  }

  if (!upstream.ok) {
    return json(502, { error: `Model returned ${upstream.status}` });
  }

  // Handed back verbatim: the app's parser expects the provider's own shape,
  // and rewriting it here would be a second place to keep in step.
  return new Response(await upstream.text(), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
};
