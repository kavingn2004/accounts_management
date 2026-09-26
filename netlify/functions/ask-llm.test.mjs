// Run with:  node --test netlify/functions/
//
// What is worth testing here is the guarding, not the proxying: this endpoint
// is public, so the tests below are the record of what a stranger cannot make
// it do.

import assert from 'node:assert/strict';
import { after, beforeEach, describe, it, mock } from 'node:test';

import handler, { Rejected, sameOrigin, sanitise } from './ask-llm.mjs';

const SITE = 'https://accounts.example/api/chat/completions';

const ask = (body, { origin = 'https://accounts.example', method = 'POST' } = {}) =>
  handler(
    new Request(SITE, {
      method,
      headers: origin ? { origin, 'Content-Type': 'application/json' } : {},
      body: method === 'POST' ? body : undefined,
    }),
  );

const question = (text = 'how much did I spend last month') =>
  JSON.stringify({
    model: 'qwen2.5-coder:7b',
    temperature: 0,
    max_tokens: 40,
    messages: [
      { role: 'system', content: 'You route a question to one tool.' },
      { role: 'user', content: text },
    ],
  });

/// A Groq reply in the shape the app's parser expects.
const groqReply = () =>
  new Response(
    JSON.stringify({
      choices: [{ message: { content: 'spend_by_payee; period=last_month' } }],
    }),
    { status: 200 },
  );

describe('sameOrigin', () => {
  it('accepts the site asking itself', () => {
    assert.equal(sameOrigin(SITE, 'https://accounts.example'), true);
  });

  it('accepts a deploy preview, which serves and asks from one host', () => {
    const preview = 'https://deploy-preview-7--accounts.netlify.app';
    assert.equal(sameOrigin(`${preview}/api/chat/completions`, preview), true);
  });

  it('rejects another site', () => {
    assert.equal(sameOrigin(SITE, 'https://someone-else.example'), false);
  });

  it('rejects a request with no origin at all', () => {
    assert.equal(sameOrigin(SITE, null), false);
  });

  it('rejects an unparseable origin', () => {
    assert.equal(sameOrigin(SITE, 'not a url'), false);
  });
});

describe('sanitise', () => {
  it('keeps the messages and nothing else the caller sent', () => {
    const out = sanitise(question(), 'llama-3.1-8b-instant');
    assert.deepEqual(out.messages, [
      { role: 'system', content: 'You route a question to one tool.' },
      { role: 'user', content: 'how much did I spend last month' },
    ]);
  });

  it('imposes the model, ignoring the one the caller asked for', () => {
    assert.equal(sanitise(question(), 'llama-3.1-8b-instant').model,
      'llama-3.1-8b-instant');
  });

  it('caps cost however generous the caller was to itself', () => {
    const greedy = JSON.stringify({
      model: 'a-much-larger-model',
      temperature: 1.5,
      max_tokens: 8000,
      stream: true,
      messages: [{ role: 'user', content: 'write me a novel' }],
    });
    const out = sanitise(greedy);
    assert.equal(out.max_tokens, 40);
    assert.equal(out.temperature, 0);
    assert.equal(out.stream, false);
    assert.notEqual(out.model, 'a-much-larger-model');
  });

  it('drops fields a future provider might bill for', () => {
    const padded = JSON.stringify({
      messages: [{ role: 'user', content: 'hi' }],
      n: 20,
      logprobs: true,
      tools: [{ type: 'function' }],
    });
    assert.deepEqual(Object.keys(sanitise(padded)).sort(),
      ['max_tokens', 'messages', 'model', 'stream', 'temperature']);
  });

  it('rejects a body that is not JSON', () => {
    assert.throws(() => sanitise('not json'), Rejected);
  });

  it('rejects a body with no messages', () => {
    assert.throws(() => sanitise('{"model":"x"}'), (e) => e.status === 400);
  });

  it('rejects a conversation longer than routing needs', () => {
    const long = JSON.stringify({
      messages: Array.from({ length: 5 }, () => ({ role: 'user', content: 'x' })),
    });
    assert.throws(() => sanitise(long), (e) => e.status === 400);
  });

  it('rejects an unknown role', () => {
    const odd = JSON.stringify({ messages: [{ role: 'root', content: 'x' }] });
    assert.throws(() => sanitise(odd), (e) => e.status === 400);
  });

  it('rejects content that is not a string', () => {
    const odd = JSON.stringify({ messages: [{ role: 'user', content: 42 }] });
    assert.throws(() => sanitise(odd), (e) => e.status === 400);
  });

  it('rejects one enormous message', () => {
    const huge = JSON.stringify({
      messages: [{ role: 'user', content: 'x'.repeat(8001) }],
    });
    assert.throws(() => sanitise(huge), (e) => e.status === 400);
  });

  // The app's system prompt carries the whole tool catalogue and measured
  // about 3 KB against the live API. It grows with every tool added, so the
  // limits have to have room in them — the first cut of this function capped
  // bodies at 4 KB, which a real request cleared by a single kilobyte.
  it('accepts a system prompt the size the app actually sends', () => {
    const realistic = JSON.stringify({
      messages: [
        { role: 'system', content: 'You route a question.\n'.repeat(150) },
        { role: 'user', content: 'where did my cash go since july' },
      ],
    });
    assert.ok(new TextEncoder().encode(realistic).length > 3000);
    assert.equal(sanitise(realistic).messages.length, 2);
  });
});

describe('handler', () => {
  beforeEach(() => {
    process.env.GROQ_API_KEY = 'gsk_test';
    delete process.env.GROQ_MODEL;
    mock.restoreAll();
  });

  after(() => {
    delete process.env.GROQ_API_KEY;
    mock.restoreAll();
  });

  it('forwards a well-formed question and returns the reply verbatim', async () => {
    const fetched = mock.method(globalThis, 'fetch', async () => groqReply());

    const res = await ask(question());
    assert.equal(res.status, 200);
    assert.equal(
      (await res.json()).choices[0].message.content,
      'spend_by_payee; period=last_month',
    );

    const [url, init] = fetched.mock.calls[0].arguments;
    assert.match(url, /api\.groq\.com/);
    assert.equal(init.headers.Authorization, 'Bearer gsk_test');
    assert.equal(JSON.parse(init.body).max_tokens, 40);
  });

  it('honours GROQ_MODEL when one is set', async () => {
    process.env.GROQ_MODEL = 'llama-3.3-70b-versatile';
    const fetched = mock.method(globalThis, 'fetch', async () => groqReply());

    await ask(question());

    const { model } = JSON.parse(fetched.mock.calls[0].arguments[1].body);
    assert.equal(model, 'llama-3.3-70b-versatile');
  });

  it('refuses anything but POST', async () => {
    assert.equal((await ask(null, { method: 'GET' })).status, 405);
  });

  it('refuses another site', async () => {
    const called = mock.method(globalThis, 'fetch', async () => groqReply());
    const res = await ask(question(), { origin: 'https://someone-else.example' });
    assert.equal(res.status, 403);
    assert.equal(called.mock.callCount(), 0);
  });

  it('refuses a caller that sends no origin, such as curl', async () => {
    assert.equal((await ask(question(), { origin: null })).status, 403);
  });

  it('refuses a body too large to be a question', async () => {
    const flood = JSON.stringify({
      messages: [{ role: 'user', content: 'x'.repeat(20_000) }],
    });
    assert.equal((await ask(flood)).status, 413);
  });

  it('passes a request the size the app really sends', async () => {
    mock.method(globalThis, 'fetch', async () => groqReply());
    const real = JSON.stringify({
      messages: [
        { role: 'system', content: 'Tools:\n- spend_by_payee: ...\n'.repeat(120) },
        { role: 'user', content: 'where did my cash go since july' },
      ],
    });
    assert.ok(new TextEncoder().encode(real).length > 3000);
    assert.equal((await ask(real)).status, 200);
  });

  it('says no model rather than leaking that a key is missing', async () => {
    delete process.env.GROQ_API_KEY;
    const res = await ask(question());
    assert.equal(res.status, 503);
    // The app turns this into keyword routing, so a deploy with no key set
    // behaves exactly as it did before this function existed.
    assert.equal((await res.json()).error, 'No model configured');
  });

  it('reports an upstream failure as 502', async () => {
    mock.method(globalThis, 'fetch', async () => new Response('nope', { status: 429 }));
    assert.equal((await ask(question())).status, 502);
  });

  it('reports an unreachable provider as 502', async () => {
    mock.method(globalThis, 'fetch', async () => {
      throw new Error('network down');
    });
    assert.equal((await ask(question())).status, 502);
  });
});
