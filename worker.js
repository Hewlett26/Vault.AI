// worker.js — Vault.AI v3

export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Origin":  "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    if (request.method !== "POST")   return new Response("Method not allowed", { status: 405 });

    let question, history;
    try {
      ({ question, history } = await request.json());
    } catch {
      return respond({ error: "Invalid JSON." }, cors, 400);
    }

    if (!question?.trim()) return respond({ error: "No question provided." }, cors, 400);

    const recentHistory = Array.isArray(history)
      ? history.filter(t => typeof t.question === "string" && typeof t.answer === "string").slice(-MAX_HISTORY)
      : [];

    // 1. Classify intent
    const intent = await classifyIntent(question, recentHistory, env);
    const topics = intent.topics.length ? intent.topics.slice(0, MAX_TOPICS) : [question];

    // 2. Retrieve from vault per topic
    const matchCount = WORKFLOW_MATCH_COUNTS[intent.workflow] ?? 5;
    const retrievals = await Promise.all(topics.map(t => retrieve(t, matchCount, env)));
    const context    = mergeContext(retrievals);
    const hasVault   = retrievals.some(r => r.chunks.length > 0);

    // 3. Answer
    let answer, source;

    if (!hasVault) {
      // Nothing in vault — answer from Gemini's own knowledge
      answer = await answerWeb(question, recentHistory, env);
      source = "web";
    } else {
      const result = await answerVault(intent, topics, question, recentHistory, context, env);
      if (result.confident) {
        answer = result.answer;
        source = "vault";
      } else {
        const webAnswer = await answerWeb(question, recentHistory, env);
        answer = "**From your notes:**\n" + result.answer + "\n\n**From general knowledge:**\n" + webAnswer;
        source = "vault+web";
      }
    }

    return respond({ answer, workflow: intent.workflow, topics, source }, cors);
  },
};

// ── Constants ─────────────────────────────────────────────────────────────────

const MODEL          = "gemini-2.5-flash-lite";
const MAX_HISTORY    = 5;
const MAX_TOPICS     = 4;
const SIM_THRESHOLD  = 0.35;

const WORKFLOW_MATCH_COUNTS = {
  qa: 5, explain: 5, summary: 5, quiz: 6, mock_test: 6, revision_plan: 6,
};

const WORKFLOW_MAX_TOKENS = {
  qa: 1500,
  explain: 2000,
  summary: 1000,
  quiz: 2100,
  mock_test: 3000,
  revision_plan: 2000,
};

const PERSONA = `You are a patient, encouraging personal tutor built from the student's own notes. Help them genuinely understand — use clear explanations, concrete examples, and analogies.`;

// ── Conversation history ──────────────────────────────────────────────────────

function buildContents(history, text) {
  const contents = [];
  for (const t of history) {
    contents.push({ role: "user",  parts: [{ text: t.question }] });
    contents.push({ role: "model", parts: [{ text: t.answer   }] });
  }
  contents.push({ role: "user", parts: [{ text }] });
  return contents;
}

// ── Gemini call ───────────────────────────────────────────────────────────────

async function callGemini(env, system, contents, maxTokens = 800, temperature = 0, tools = null) {
  const body = {
    system_instruction: { parts: [{ text: system }] },
    contents,
    generationConfig: { maxOutputTokens: maxTokens, temperature },
  };
  if (tools) body.tools = tools;

  const res  = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${env.GEMINI_API_KEY}`,
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }
  );
  return res.json();
}

// ── Intent classification ─────────────────────────────────────────────────────

async function classifyIntent(question, history, env) {
  const fallback = { workflow: "qa", topics: [], num_questions: null, days: null, difficulty: null };
  try {
    const data = await callGemini(
      env,
      `Classify the student's latest message into one workflow and extract topics.

Workflows: qa | explain | quiz | mock_test | revision_plan

Extract 1-${MAX_TOPICS} short topic phrases to search the student's notes. Usually just one.
Use prior turns to resolve follow-ups like "make it harder" or "5 more".

Reply with ONLY valid JSON, no fences:
{"workflow":"qa","topics":["topic"],"num_questions":null,"days":null,"difficulty":null}`,
      buildContents(history, question),
      150,
      0
    );

    const raw     = data.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    const cleaned = raw.trim().replace(/^```json/i, "").replace(/^```/, "").replace(/```$/, "").trim();
    const parsed  = JSON.parse(cleaned);
    const VALID   = ["qa", "explain", "quiz", "mock_test", "revision_plan"];
    const topics  = Array.isArray(parsed.topics)
      ? parsed.topics.filter(t => typeof t === "string" && t.trim()).map(t => t.trim())
      : [];

    return {
      workflow:      VALID.includes(parsed.workflow) ? parsed.workflow : "qa",
      topics,
      num_questions: parsed.num_questions ?? null,
      days:          parsed.days          ?? null,
      difficulty:    parsed.difficulty    ?? null,
    };
  } catch {
    return fallback;
  }
}

// ── Embedding ─────────────────────────────────────────────────────────────────

async function embed(text, env) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent?key=${env.GEMINI_API_KEY}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model:   "models/gemini-embedding-exp-03-07",
        content: { parts: [{ text }] },
      }),
    }
  );
  const data = await res.json();
  return data.embedding?.values ?? null;
}

// ── Retrieval ─────────────────────────────────────────────────────────────────

async function retrieve(topic, matchCount, env) {
  const embedding = await embed(topic, env);
  if (!embedding) return { topic, chunks: [] };

  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/match_chunks`, {
    method: "POST",
    headers: {
      "Content-Type":  "application/json",
      "apikey":        env.SUPABASE_KEY,
      "Authorization": `Bearer ${env.SUPABASE_KEY}`,
    },
    body: JSON.stringify({ query_embedding: embedding, match_count: matchCount }),
  });

  const data   = await res.json();
  const chunks = Array.isArray(data) ? data.filter(c => c.similarity > SIM_THRESHOLD) : [];
  return { topic, chunks };
}

function mergeContext(retrievals) {
  const seen     = new Set();
  const sections = [];
  for (const { topic, chunks } of retrievals) {
    const fresh = chunks.filter(c => !seen.has(c.content) && seen.add(c.content));
    if (fresh.length) sections.push(`## ${topic}\n${fresh.map(c => c.content).join("\n\n")}`);
  }
  return sections.join("\n\n---\n\n");
}

// ── Answer from vault ─────────────────────────────────────────────────────────

async function answerVault(intent, topics, question, history, context, env) {
  const maxTokens   = WORKFLOW_MAX_TOKENS[intent.workflow] ?? 800;
  const temperature = ["qa", "explain", "summary"].includes(intent.workflow) ? 0 : 0.4;
  const topicList   = topics.join(", ");

  const insufficient = `If the VAULT CONTEXT does not contain enough to answer well, start your reply with [INSUFFICIENT] then briefly describe what's missing. Do not answer from memory.`;

  let task;
  switch (intent.workflow) {
    case "explain":
      task = `Give a clear step-by-step explanation with examples. End with a follow-up question to check understanding.`;
      break;
    case "quiz": {
      const n = intent.num_questions || 10;
      task = `Generate ${n} quiz questions (mix of multiple choice, short answer, true/false). Number them. Add an Answer Key with one-line explanations.`;
      break;
    }
    case "mock_test": {
      const n = intent.num_questions || 15;
      const d = intent.difficulty || "mixed";
      task = `Build a mock test (~${n} questions, difficulty: ${d}) on: ${topicList}. Sections: Easy / Medium / Hard. Mix question types. Include a full Answer Key.`;
      break;
    }
    case "revision_plan": {
      const days = intent.days || 3;
      task = `Create a ${days}-day revision plan for: ${topicList}. Foundational topics first. Each day: concepts + one self-check method. Actionable, no filler.`;
      break;
    }
    default:
      task = `Answer the student's question naturally and concisely. 2–4 sentences unless more depth is needed.`;
  }

  const system = `${PERSONA}

RULES:
- Only use the VAULT CONTEXT below. Never invent details.
- Rewrite everything in your own words — no verbatim copying.
- Teach naturally. Don't mention "the vault" or "the context".
- Use prior conversation turns for continuity.

${insufficient}

TASK: ${task}

VAULT CONTEXT:
${context}`;

  const data = await callGemini(env, system, buildContents(history, question), maxTokens, temperature);

  if (data.error) return { confident: true, answer: `API error: ${data.error.message ?? data.error.status}` };

  const raw = data.candidates?.[0]?.content?.parts?.[0]?.text ?? "";

  if (raw.startsWith("[INSUFFICIENT]")) {
    return { confident: false, answer: raw.replace("[INSUFFICIENT]", "").trim() };
  }
  return { confident: true, answer: raw };
}

// ── Answer from general knowledge (no vault, no grounding tool needed) ────────

async function answerWeb(question, history, env) {
  const system = `${PERSONA}

The student asked about something not covered in their notes. Answer from your general knowledge.

RULES:
- Be clear and educational.
- If the question asks what they personally wrote or noted about something, say you couldn't find any notes on that topic, then explain the subject generally.
- Do not claim this information came from their notes.`;

  const data = await callGemini(env, system, buildContents(history, question), 800, 0.2);

  if (data.error) return `Could not retrieve an answer. (${data.error.message ?? data.error.status})`;

  const parts = data.candidates?.[0]?.content?.parts ?? [];
  return parts.filter(p => p.text).map(p => p.text).join("").trim()
    || "I couldn't find relevant information. Try rephrasing your question.";
}

// ── Response helper ───────────────────────────────────────────────────────────

function respond(data, headers, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}
