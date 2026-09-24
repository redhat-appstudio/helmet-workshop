"use strict";

const crypto = require("crypto");
const express = require("express");
const cookieParser = require("cookie-parser");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.env.PORT || 8080);
const CREDENTIALS_PATH =
  process.env.CREDENTIALS_PATH || "/data/credentials.csv";
const STATE_PATH = process.env.STATE_PATH || "/data/state.json";
const ACTIVITIES_PATH =
  process.env.ACTIVITIES_PATH ||
  path.join(__dirname, "workshop-activities.md");
const CONSOLE_URL = process.env.CONSOLE_URL || "";
const IDP_NAME = process.env.IDP_NAME || "htpasswd";
const SESSION_SECRET =
  process.env.COORDINATOR_SESSION_SECRET || "change-me-in-production";

const app = express();
app.use(cookieParser(SESSION_SECRET));
app.use(express.urlencoded({ extended: false }));

/** @type {Promise<void>} */
let lock = Promise.resolve();

function withLock(fn) {
  const run = lock.then(fn);
  lock = run.catch(() => {});
  return run;
}

function readState() {
  try {
    const raw = fs.readFileSync(STATE_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed.assignments || typeof parsed.nextIndex !== "number") {
      throw new Error("invalid state shape");
    }
    return parsed;
  } catch (err) {
    if (err.code === "ENOENT") {
      return { fingerprint: "", nextIndex: 0, assignments: {} };
    }
    throw err;
  }
}

function credentialsFingerprint(csvText) {
  return crypto.createHash("sha256").update(csvText).digest("hex");
}

function loadQueueAndState() {
  const csv = fs.readFileSync(CREDENTIALS_PATH, "utf8");
  const fingerprint = credentialsFingerprint(csv);
  const { queue, roomChallenge } = parseCredentials(csv);
  let state = readState();
  if (state.fingerprint !== fingerprint) {
    state = { fingerprint, nextIndex: 0, assignments: {} };
    writeState(state);
  }
  return { queue, roomChallenge, state };
}

function writeState(state) {
  const dir = path.dirname(STATE_PATH);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${STATE_PATH}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, STATE_PATH);
}

function parseCredentials(csvText) {
  const lines = csvText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length <= 1) {
    return { queue: [], roomChallenge: "" };
  }
  const header = lines[0].split(",").map((h) => h.trim().toLowerCase());
  const userIdx = header.indexOf("username");
  const passIdx = header.indexOf("password");
  const nsIdx = header.indexOf("namespace");
  if (userIdx === -1 || passIdx === -1 || nsIdx === -1) {
    throw new Error("credentials CSV must have username,password,namespace columns");
  }

  const queue = [];
  let roomChallenge = "";
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(",");
    if (cols.length < 3) {
      continue;
    }
    const username = cols[userIdx].trim();
    const password = cols[passIdx].trim();
    const namespace = cols[nsIdx].trim();
    if (username === "coordinator") {
      roomChallenge = password;
      continue;
    }
    queue.push({ username, password, namespace });
  }
  return { queue, roomChallenge };
}

function challengeMatches(expected, provided) {
  if (!expected) {
    return true;
  }
  const a = Buffer.from(String(provided ?? ""));
  const b = Buffer.from(String(expected));
  if (a.length !== b.length) {
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

function roomUnlocked(req) {
  return Boolean(req.signedCookies?.ws_room_unlock);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Render a small subset of inline Markdown (links + code + bold) safely as HTML. */
function renderInlineMarkdown(text) {
  const escaped = escapeHtml(text);
  // Only http(s) hrefs; label may still contain `code` / **bold** markers.
  const withLinks = escaped.replace(
    /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,
    (_match, label, url) =>
      `<a href="${url}" target="_blank" rel="noopener noreferrer">${label}</a>`,
  );
  const withCode = withLinks.replace(/`([^`]+)`/g, "<code>$1</code>");
  return withCode.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

function renderMarkdownParagraph(text) {
  return renderInlineMarkdown(text).replaceAll("\n", "<br>");
}

/** Render hint/details body: fenced code blocks + inline markdown paragraphs. */
function renderHintBody(text) {
  const fence = /```(?:[\w-]*\n)?([\s\S]*?)```/g;
  let html = "";
  let cursor = 0;
  for (const match of text.matchAll(fence)) {
    const before = text.slice(cursor, match.index).trim();
    if (before) {
      html += `<p>${renderMarkdownParagraph(before)}</p>`;
    }
    html += `<pre class="code-block"><code>${escapeHtml(match[1].replace(/\n$/, ""))}</code></pre>`;
    cursor = match.index + match[0].length;
  }
  const tail = text.slice(cursor).trim();
  if (tail) {
    html += `<p>${renderMarkdownParagraph(tail)}</p>`;
  }
  return html || `<p>${renderMarkdownParagraph(text)}</p>`;
}

/** @typedef {{ id: string, title: string, description?: string, items: string[], hint?: { label: string, body: string } }} ActivitySection */

/** Parse workshop-activities.md into renderable sections. */
function parseActivitiesMarkdown(text) {
  /** @type {ActivitySection[]} */
  const sections = [];
  const chunks = text.split(/^## /m).slice(1);
  for (const chunk of chunks) {
    const lines = chunk.split("\n");
    const title = lines[0].trim();
    const body = lines.slice(1).join("\n");
    const id = title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "");
    /** @type {string[]} */
    const items = [];
    for (const line of body.split("\n")) {
      const match = line.match(/^- \[ \] (.+)$/);
      if (match) {
        items.push(match[1].trim());
      }
    }
    // Purpose blurb: prose between the heading and the first checkbox / details.
    const preambleMatch = body.match(
      /^([\s\S]*?)(?=^- \[ \]|^<details>)/m,
    );
    const description = preambleMatch
      ? preambleMatch[1].trim().replace(/\n+/g, " ")
      : "";
    const hintMatch = body.match(
      /<details>\s*<summary>([\s\S]*?)<\/summary>\s*([\s\S]*?)<\/details>/,
    );
    /** @type {ActivitySection} */
    const section = { id, title, items };
    if (description) {
      section.description = description;
    }
    if (hintMatch) {
      section.hint = {
        label: hintMatch[1].trim(),
        body: hintMatch[2].trim(),
      };
    }
    if (items.length > 0) {
      sections.push(section);
    }
  }
  return sections;
}

function loadActivities() {
  try {
    const text = fs.readFileSync(ACTIVITIES_PATH, "utf8");
    return parseActivitiesMarkdown(text);
  } catch (err) {
    console.warn(`activities unavailable (${ACTIVITIES_PATH}): ${err.message}`);
    return [];
  }
}

function renderActivitiesHtml(sections) {
  if (sections.length === 0) {
    return "";
  }

  const blocks = sections
    .map((section) => {
      const checks = section.items
        .map((item, index) => {
          const itemId = `${section.id}-${index}`;
          return `<li><label><input type="checkbox" data-activity-id="${escapeHtml(itemId)}"><span class="check-text">${renderInlineMarkdown(item)}</span></label></li>`;
        })
        .join("\n");

      const description = section.description
        ? `<p class="activity-desc">${renderInlineMarkdown(section.description)}</p>`
        : "";

      const hint = section.hint
        ? `<details class="hint"><summary>${renderInlineMarkdown(section.hint.label)}</summary>${renderHintBody(section.hint.body)}</details>`
        : "";

      return `<details class="activity">
  <summary>${renderInlineMarkdown(section.title)}</summary>
  ${description}
  <ul class="checks">${checks}</ul>
  ${hint}
</details>`;
    })
    .join("\n");

  return `<details class="lab-activities" id="lab-activities">
  <summary>Lab activities — expand when your instructor tells you</summary>
  <p class="muted">Check items off here as you work in the pod terminal. Progress is saved in this browser.</p>
  <div class="activity-list">
${blocks}
  </div>
</details>`;
}

function pageStyles() {
  return `:root { font-family: system-ui, sans-serif; color: #151515; background: #f5f5f5; }
    body { max-width: 52rem; margin: 2rem auto; padding: 0 1rem; }
    .card { background: #fff; border-radius: 8px; padding: 1.5rem; box-shadow: 0 1px 4px rgba(0,0,0,.12); margin-bottom: 1rem; }
    h1 { font-size: 1.35rem; margin-top: 0; }
    h2 { font-size: 1.05rem; margin: 1.25rem 0 .5rem; }
    dl { display: grid; grid-template-columns: 9rem 1fr; gap: .5rem 1rem; }
    dt { font-weight: 600; }
    dd { margin: 0; font-family: ui-monospace, monospace; word-break: break-all; }
    .btn { display: inline-block; margin-top: 1rem; padding: .6rem 1rem; background: #ee0000; color: #fff; text-decoration: none; border-radius: 4px; border: 0; font-size: 1rem; cursor: pointer; }
    .field { margin: 1rem 0; }
    .field label { display: block; font-weight: 600; margin-bottom: .35rem; }
    .field input { width: 100%; max-width: 20rem; padding: .5rem .65rem; font-size: 1rem; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
    .error { color: #b00020; margin-top: .75rem; }
    .muted { color: #666; font-size: .9rem; }
    ol { padding-left: 1.2rem; }
    code { font-family: ui-monospace, monospace; font-size: .9em; }
    .lab-activities { background: #fff; border-radius: 8px; padding: 1rem 1.25rem; box-shadow: 0 1px 4px rgba(0,0,0,.12); overflow: hidden; }
    .lab-activities > summary { font-weight: 700; font-size: 1.05rem; cursor: pointer; }
    .activity { margin-top: .75rem; border: 1px solid #e0e0e0; border-radius: 6px; padding: .5rem .75rem; overflow: hidden; }
    .activity > summary { font-weight: 600; cursor: pointer; overflow-wrap: anywhere; }
    .activity-desc { margin: .5rem 0 .25rem; font-size: .9rem; color: #444; overflow-wrap: anywhere; }
    .checks { list-style: none; padding-left: 0; margin: .5rem 0; }
    .checks li { margin: .35rem 0; }
    .checks label { display: flex; gap: .5rem; align-items: flex-start; }
    .checks input[type=checkbox] { flex-shrink: 0; margin-top: .2rem; }
    .checks .check-text { flex: 1; min-width: 0; overflow-wrap: anywhere; }
    code { font-family: ui-monospace, monospace; font-size: .9em; background: #f0f0f0; padding: .1em .25em; border-radius: 3px; overflow-wrap: anywhere; }
    .hint { margin-top: .5rem; font-size: .9rem; color: #444; overflow-wrap: anywhere; }
    .hint > summary { cursor: pointer; color: #0066cc; }
    .hint p { overflow-wrap: anywhere; margin: .35rem 0 0; }
    .hint a, .checks a, .activity > summary a { color: #0066cc; }
    .code-block { background: #f0f0f0; padding: .65rem .75rem; border-radius: 4px; overflow-x: auto; font-size: .85rem; margin: .35rem 0 0; }
    .code-block code { background: none; padding: 0; white-space: pre; display: block; overflow-wrap: normal; }`;
}

function pageScripts() {
  return `(function () {
  var key = "helmet-workshop-activities";
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(key) || "{}"); } catch (e) { saved = {}; }
  document.querySelectorAll("input[data-activity-id]").forEach(function (cb) {
    var id = cb.getAttribute("data-activity-id");
    cb.checked = !!saved[id];
    cb.addEventListener("change", function () {
      saved[id] = cb.checked;
      localStorage.setItem(key, JSON.stringify(saved));
    });
  });
})();`;
}

function renderChallengeForm(res, { error = "" } = {}) {
  const errorHtml = error
    ? `<p class="error">${escapeHtml(error)}</p>`
    : "";
  res.type("html").send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Helmet Workshop — Room code</title>
  <style>${pageStyles()}</style>
</head>
<body>
  <div class="card">
    <h1>Enter room code</h1>
    <p class="muted">Your instructor will share this at the start of the session. Wrong or missing codes do not use a workshop slot.</p>
    <form method="post" action="/unlock">
      <div class="field">
        <label for="code">Room code</label>
        <input id="code" name="code" autocomplete="off" autocapitalize="characters" required autofocus>
      </div>
      <button class="btn" type="submit">Continue</button>
    </form>
    ${errorHtml}
  </div>
</body>
</html>`);
}

function renderPage(res, entry, stats) {
  const consoleLink = CONSOLE_URL
    ? `<a class="btn" href="${escapeHtml(CONSOLE_URL)}" target="_blank" rel="noopener">Open OpenShift Console</a>`
    : `<p class="muted">Console URL not configured on coordinator.</p>`;

  const activitiesHtml = renderActivitiesHtml(loadActivities());

  res.type("html").send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Helmet Workshop — Your login</title>
  <style>${pageStyles()}</style>
</head>
<body>
  <div class="card">
    <h1>Your workshop environment</h1>
    <p class="muted">Save this page — your assignment is tied to this browser session. Keep this tab open.</p>
    <dl>
      <dt>Console</dt><dd>${CONSOLE_URL ? escapeHtml(CONSOLE_URL) : "—"}</dd>
      <dt>Login with</dt><dd>${escapeHtml(IDP_NAME)} (HTPasswd)</dd>
      <dt>Username</dt><dd id="user">${escapeHtml(entry.username)}</dd>
      <dt>Password</dt><dd id="pass">${escapeHtml(entry.password)}</dd>
      <dt>Namespace</dt><dd>${escapeHtml(entry.namespace)}</dd>
    </dl>
    ${consoleLink}
    <h2>Getting started</h2>
    <ol>
      <li>Open the console (new tab) and log in with <strong>${escapeHtml(IDP_NAME)}</strong>.</li>
      <li>Select project <strong>${escapeHtml(entry.namespace)}</strong>.</li>
      <li>Go to <strong>Workloads → Pods → workshop</strong> → <strong>Terminal</strong>.</li>
      <li>In the pod terminal, follow the banner — expand <strong>Lab activities</strong> on the coordinator page when your instructor tells you.</li>
    </ol>
    <p class="muted">${escapeHtml(stats.assigned)} of ${escapeHtml(stats.total)} slots assigned · ${escapeHtml(stats.remaining)} remaining</p>
  </div>
  ${activitiesHtml}
  <script>${pageScripts()}</script>
</body>
</html>`);
}

function renderExhausted(res, stats) {
  res.status(503).type("html").send(`<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Workshop full</title></head>
<body style="font-family:system-ui;max-width:36rem;margin:3rem auto;padding:0 1rem;">
  <h1>All workshop slots are assigned</h1>
  <p>Every participant credential has already been claimed. Ask an instructor if you need help.</p>
  <p class="muted">${escapeHtml(stats.assigned)} of ${escapeHtml(stats.total)} slots assigned.</p>
</body></html>`);
}

function renderError(res, message) {
  res.status(500).type("html").send(`<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Coordinator error</title></head>
<body style="font-family:system-ui;max-width:36rem;margin:3rem auto;padding:0 1rem;">
  <h1>Coordinator unavailable</h1>
  <p>${escapeHtml(message)}</p>
</body></html>`);
}

function stats(state, total) {
  const assigned = Object.keys(state.assignments).length;
  return {
    assigned: String(assigned),
    total: String(total),
    remaining: String(Math.max(total - state.nextIndex, 0)),
  };
}

app.get("/healthz", (_req, res) => {
  res.json({ ok: true });
});

app.post("/unlock", (req, res) => {
  try {
    const { roomChallenge } = loadQueueAndState();
    if (!roomChallenge) {
      res.redirect(303, "/");
      return;
    }
    const code = String(req.body?.code ?? "").trim();
    if (!challengeMatches(roomChallenge, code)) {
      renderChallengeForm(res, { error: "Incorrect room code. Try again." });
      return;
    }
    res.cookie("ws_room_unlock", "1", {
      signed: true,
      httpOnly: true,
      sameSite: "lax",
      maxAge: 7 * 24 * 60 * 60 * 1000,
    });
    res.redirect(303, "/");
  } catch (err) {
    console.error(err);
    renderError(res, err.message);
  }
});

app.get("/", (req, res) => {
  withLock(() => {
    try {
      const { queue, roomChallenge, state: initialState } = loadQueueAndState();
      const total = queue.length;
      if (total === 0) {
        return renderError(res, "No credentials loaded.");
      }

      if (roomChallenge && !roomUnlocked(req)) {
        return renderChallengeForm(res);
      }

      const state = initialState;
      const sessionId = req.signedCookies?.ws_session;
      if (sessionId && state.assignments[sessionId]) {
        return renderPage(res, state.assignments[sessionId], stats(state, total));
      }

      if (state.nextIndex >= total) {
        return renderExhausted(res, stats(state, total));
      }

      const entry = queue[state.nextIndex];
      const newSession = crypto.randomUUID();
      state.nextIndex += 1;
      state.assignments[newSession] = entry;
      writeState(state);

      res.cookie("ws_session", newSession, {
        signed: true,
        httpOnly: true,
        sameSite: "lax",
        maxAge: 7 * 24 * 60 * 60 * 1000,
      });
      renderPage(res, entry, stats(state, total));
    } catch (err) {
      console.error(err);
      renderError(res, err.message);
    }
  }).catch((err) => {
    console.error(err);
    renderError(res, err.message);
  });
});

app.listen(PORT, () => {
  console.log(`workshop coordinator listening on :${PORT}`);
});
