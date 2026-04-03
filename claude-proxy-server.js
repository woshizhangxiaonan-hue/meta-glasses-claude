const http = require("http");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const PORT = 8765;
const TMP_DIR = "/tmp/claude-proxy-images";

// Ensure temp directory exists
if (!fs.existsSync(TMP_DIR)) fs.mkdirSync(TMP_DIR, { recursive: true });

function extractContent(messages, systemPrompt) {
  let textParts = [];
  let imagePaths = [];

  for (const msg of messages) {
    if (msg.role !== "user") continue;
    const parts = typeof msg.content === "string" ? [{ type: "text", text: msg.content }] : msg.content;

    for (const part of parts) {
      if (part.type === "text") {
        textParts.push(part.text);
      } else if (part.type === "image" && part.source?.type === "base64") {
        // Save base64 image to temp file
        const ext = (part.source.media_type || "image/jpeg").split("/")[1] || "jpg";
        const filename = `img_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`;
        const filepath = path.join(TMP_DIR, filename);
        fs.writeFileSync(filepath, Buffer.from(part.source.data, "base64"));
        imagePaths.push(filepath);
      }
    }
  }

  // Build prompt with image references
  let prompt = "";
  if (systemPrompt) prompt += systemPrompt + "\n\n";
  if (imagePaths.length > 0) {
    prompt += imagePaths.map(p => `请分析这张图片: ${p}`).join("\n") + "\n\n";
  }
  prompt += textParts.join("\n");

  return { prompt, imagePaths };
}

function runClaude(prompt, systemPrompt, hasImage) {
  return new Promise((resolve, reject) => {
    const args = [
      "-p",
      "--dangerously-skip-permissions",
      "--model", "sonnet",
    ];
    // 只有图片请求才给 Read 工具，纯文字不需要
    if (hasImage) {
      args.push("--allowedTools", "Read");
    } else {
      args.push("--allowedTools", "");
    }
    if (systemPrompt) {
      args.push("--system-prompt", systemPrompt);
    }

    const child = spawn("/opt/homebrew/bin/claude", args, {
      env: { ...process.env, LANG: "en_US.UTF-8" },
      cwd: "/tmp",
    });

    let stdout = "";
    let stderr = "";
    let done = false;

    // 60s timeout — kill hung/rate-limited CLI
    const timer = setTimeout(() => {
      if (!done) {
        done = true;
        child.kill("SIGKILL");
        reject(new Error("Claude CLI timed out (60s) — likely rate limited"));
      }
    }, 60000);

    child.stdin.write(prompt);
    child.stdin.end();

    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });

    child.on("close", (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (code !== 0) {
        console.error(`[claude] exit ${code}: ${stderr.slice(0, 200)}`);
        reject(new Error(stderr || `claude exited with code ${code}`));
      } else {
        resolve(stdout.trim());
      }
    });

    child.on("error", (err) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      reject(err);
    });
  });
}

// Clean up old temp images (>1 hour)
function cleanupTempImages() {
  try {
    const files = fs.readdirSync(TMP_DIR);
    const now = Date.now();
    for (const file of files) {
      const filepath = path.join(TMP_DIR, file);
      const stat = fs.statSync(filepath);
      if (now - stat.mtimeMs > 3600000) {
        fs.unlinkSync(filepath);
      }
    }
  } catch {}
}
setInterval(cleanupTempImages, 600000); // Every 10 min

const server = http.createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, x-api-key, anthropic-version");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    return res.end();
  }

  if (req.method !== "POST" || req.url !== "/v1/messages") {
    res.writeHead(404, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "Not found. Use POST /v1/messages" }));
  }

  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", async () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: "Invalid JSON" }));
    }

    const { model, messages, system: systemPrompt } = parsed;
    const { prompt, imagePaths } = extractContent(messages || [], systemPrompt);
    const hasImage = imagePaths.length > 0;

    console.log(`[req] model=${model} image=${hasImage} prompt_len=${prompt.length}`);
    console.log("[route] all requests → claude CLI (CLI proxy)");

    try {
      const defaultSystemPrompt = "你是Meta智能眼镜的AI助手，回答通过扬声器语音播报。规则：1）用和用户相同的语言回答，用户说英文你必须用英文回复。2）最多2-3句话，要短。3）语气自然像朋友聊天。4）你没有联网能力，不能查实时变化的数据（当前价格、实时天气、比分、新闻、股价、库存），遇到这类问题说查不了让用户手机搜。但常识性问题（推荐餐厅、翻译、知识问答、路线建议等）可以正常回答，不要拒绝。5）涉及他人隐私的请求（记车牌、认人脸、跟踪、偷拍）一律拒绝，回答涉及别人隐私不能帮，不提供变通方案。";
      const responseText = await runClaude(
        prompt,
        systemPrompt || defaultSystemPrompt,
        hasImage
      );

      // Cleanup temp images after use
      for (const p of imagePaths) {
        try { fs.unlinkSync(p); } catch {}
      }

      console.log(`[claude] response length=${responseText.length}`);

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        id: `msg_proxy_${Date.now()}`,
        type: "message",
        role: "assistant",
        model: model || "claude-proxy",
        content: [{ type: "text", text: responseText }],
        stop_reason: "end_turn",
        usage: { input_tokens: 0, output_tokens: 0 },
      }));
    } catch (err) {
      console.error(`[error] ${err.message}`);
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        type: "error",
        error: { type: "server_error", message: err.message },
      }));
    }
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Claude proxy server listening on http://0.0.0.0:${PORT}/v1/messages`);
  console.log("  ALL requests → claude CLI (CLI proxy)");
});
