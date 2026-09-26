// Does the Ask proxy work with the key on this machine?
//
//   node tool/check_ask_proxy.mjs
//
// Reads GROQ_API_KEY from supabase.env (git-ignored) and drives the real
// function against the real provider. Nothing is mocked, so this answers the
// question the unit tests cannot: is the key live, is the model reachable, and
// does it route a plain-English question to a sensible tool.
//
// The prompt is the app's own, dumped out of the Dart code by
// test/ask_prompt_test.dart rather than paraphrased here. That costs a few
// seconds and is worth them: an earlier version of this script approximated
// the prompt, dropped its worked examples, and reported two failures on
// questions the real app routes correctly.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const readEnv = (name) => {
  const line = readFileSync(join(root, 'supabase.env'), 'utf8')
    .split('\n')
    .find((l) => l.startsWith(`${name}=`));
  return line?.slice(name.length + 1).trim() ?? '';
};

const key = process.env.GROQ_API_KEY || readEnv('GROQ_API_KEY');
if (!key) {
  console.error('No GROQ_API_KEY in supabase.env or the environment.');
  process.exit(1);
}
process.env.GROQ_API_KEY = key;
process.env.GROQ_MODEL ||= readEnv('GROQ_MODEL');

const { default: handler } = await import(
  join(root, 'netlify/functions/ask-llm.mjs')
);

const dumpTo = join(mkdtempSync(join(tmpdir(), 'ask-proxy-')), 'prompt.txt');
console.log('Dumping the app\'s own system prompt...');
execFileSync('flutter', ['test', 'test/ask_prompt_test.dart'], {
  cwd: root,
  env: { ...process.env, DUMP_TO: dumpTo },
  stdio: 'pipe',
});
const SYSTEM = readFileSync(dumpTo, 'utf8');

const QUESTIONS = [
  ['where did all my cash disappear to since july', 'spend_by_payee'],
  ['am I actually up on the market stuff', 'investment_summary'],
  ['who still owes me money', 'money_owed_to_me'],
  ['how much is sitting in indian bank', 'account_balances'],
  ['is my tata sip doing anything', 'sip_detail'],
];

const origin = 'https://accounts.example';
let failures = 0;

for (const [question, expected] of QUESTIONS) {
  const body = JSON.stringify({
    messages: [
      { role: 'system', content: SYSTEM },
      { role: 'user', content: question },
    ],
  });

  const started = Date.now();
  const res = await handler(
    new Request(`${origin}/api/chat/completions`, {
      method: 'POST',
      headers: { origin, 'Content-Type': 'application/json' },
      body,
    }),
  );
  const ms = `${Date.now() - started}ms`.padStart(7);

  if (res.status !== 200) {
    failures++;
    console.log(`${ms}  HTTP ${res.status}  ${await res.text()}`);
    continue;
  }

  const line = (await res.json()).choices[0].message.content.trim();
  const tool = line.split(';')[0].trim();
  const ok = tool === expected;
  if (!ok) failures++;
  console.log(`${ms}  ${ok ? 'ok  ' : 'MISS'}  ${line.padEnd(48)} <- ${question}`);
}

console.log(
  failures === 0
    ? `\nProxy, key and model all working (${process.env.GROQ_MODEL || 'default model'}).`
    : `\n${failures} of ${QUESTIONS.length} did not route as expected.`,
);
process.exit(failures === 0 ? 0 : 1);
