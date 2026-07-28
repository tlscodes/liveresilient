/**
 * Builds the single-file verifier page.
 *
 * The page has to work from a file — opened from a memory card, an email
 * attachment, a printed QR that decoded to a download — so it cannot load
 * a module beside it: browsers refuse module imports over file://. The
 * logic therefore lives in `verifier_core.mjs`, which is unit-tested, and
 * gets inlined here rather than duplicated.
 *
 * Regenerate with:
 *
 *     node tools/web_verifier/build_verifier.mjs
 *
 * A test asserts the committed page matches what this produces, so the
 * two can never drift apart quietly.
 */

import { readFileSync, writeFileSync } from 'node:fs';

const here = new URL('.', import.meta.url);
const core = readFileSync(new URL('verifier_core.mjs', here), 'utf8');

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Verify a signed post</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: system-ui, sans-serif;
    margin: 0 auto;
    padding: 2rem 1.25rem 4rem;
    max-width: 44rem;
    line-height: 1.55;
  }
  h1 { font-size: 1.35rem; font-weight: 600; margin: 0 0 .35rem; }
  .lede { color: #666; margin: 0 0 1.5rem; }
  textarea {
    width: 100%;
    min-height: 9rem;
    font-family: ui-monospace, monospace;
    font-size: .85rem;
    padding: .75rem;
    box-sizing: border-box;
    border: 1px solid #bbb;
    border-radius: .4rem;
    background: transparent;
    color: inherit;
  }
  button {
    margin-top: .75rem;
    padding: .6rem 1.1rem;
    font: inherit;
    border-radius: .4rem;
    border: 1px solid #888;
    background: transparent;
    color: inherit;
    cursor: pointer;
  }
  .verdict { margin-top: 1.5rem; padding: 1rem; border-radius: .5rem; }
  .signed { border: 2px solid #1a7f37; }
  .refused { border: 2px solid #b42318; }
  .verdict h2 { font-size: 1.05rem; margin: 0 0 .5rem; }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: .35rem .9rem; margin: .75rem 0 0; }
  dt { color: #666; }
  dd { margin: 0; overflow-wrap: anywhere; }
  .post { white-space: pre-wrap; margin-top: .9rem; padding: .8rem;
          border-left: 3px solid #888; }
  code, .mono { font-family: ui-monospace, monospace; font-size: .82rem; }
  .caveat { margin-top: 1.75rem; color: #666; font-size: .9rem; }
  .caveat strong { color: inherit; }
</style>
</head>
<body>
<h1>Verify a signed post</h1>
<p class="lede">
  Paste an evidence bundle. Everything happens on this page: nothing is
  uploaded, nothing is fetched, and this file works offline.
</p>

<label for="input" class="mono">evidence (base64)</label>
<textarea id="input" spellcheck="false" autocapitalize="off"
          autocomplete="off"></textarea>
<button id="check" type="button">Check it</button>

<div id="out" hidden class="verdict"></div>

<p class="caveat">
  <strong>What a green result means:</strong> this text was signed by
  whoever holds that key, at that position, at that stated time — and has
  not been altered by a single byte since.
  <br>
  <strong>What it does not mean:</strong> that the key belongs to any
  particular person. Compare the author key against one you obtained some
  other way. A signature proves a message is unchanged; it cannot tell you
  who someone is.
</p>

<script type="module">
${core}

const input = document.getElementById('input');
const button = document.getElementById('check');
const out = document.getElementById('out');

function row(term, value) {
  return '<dt>' + term + '</dt><dd class="mono">' + value + '</dd>';
}

function escapeHtml(text) {
  return text.replace(/[&<>]/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]
  ));
}

async function run() {
  out.hidden = false;
  const bytes = fromBase64(input.value);
  if (bytes === null || bytes.length === 0) {
    out.className = 'verdict refused';
    out.innerHTML = '<h2>Not readable</h2><p>That is not base64 text.</p>';
    return;
  }

  const result = await verifyEvidence(bytes);
  if (!result.ok) {
    out.className = 'verdict refused';
    out.innerHTML = '<h2>Not verified</h2><p>' +
      escapeHtml(result.reason) + '</p>';
    return;
  }

  const p = result.post;
  out.className = 'verdict signed';
  out.innerHTML =
    '<h2>Signed and unaltered</h2>' +
    (p.retracts
      ? '<p><strong>This post withdraws an earlier one.</strong></p>'
      : '') +
    '<dl>' +
    row('author key', p.rootPublicKey) +
    row('author id', p.authorId) +
    row('position', '#' + p.seq) +
    row('stated time', p.publishedAt.toISOString()) +
    row('delegation', p.certificateFrom.toISOString() + ' to ' +
        p.certificateUntil.toISOString()) +
    (p.retracts ? row('withdraws', p.retracts) : '') +
    '</dl>' +
    (p.textIsReadable
      ? '<div class="post">' + escapeHtml(p.text) + '</div>'
      : '<p class="caveat">The signed payload is ' + p.textBytes +
        ' bytes and is not plain text, so it cannot be shown here. Its ' +
        'hash is <span class="mono">' + p.textHash + '</span> and the ' +
        'signature over it is valid.</p>');
}

button.addEventListener('click', run);
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) run();
});
</script>
</body>
</html>
`;

writeFileSync(new URL('verifier.html', here), page);
process.stdout.write('wrote tools/web_verifier/verifier.html\n');
