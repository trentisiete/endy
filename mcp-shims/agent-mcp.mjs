#!/usr/bin/env node
// Tiny stdio MCP server that exposes one tool: `delegate_to_<AGENT_NAME>`.
// The tool spawns an underlying CLI agent (opencode, cmd, claude) with the
// given prompt and returns the agent's final output. One shim, parameterised
// by env vars, used by every subagent in the endy stack.
//
// Required env vars (set in ~/.codex/config.toml under each [mcp_servers.X]):
//   AGENT_NAME      e.g. "opencode"        — used as the tool name suffix
//   AGENT_BIN       absolute path to CLI   — e.g. "$HOME/.opencode/bin/opencode"
//   AGENT_RUN_MODE  "opencode" | "commandcode" | "claude-code"  — selects argv shape
//
// Optional:
//   AGENT_TIMEOUT_MS  default 600000 (10 min)

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "node:child_process";

const AGENT_NAME = process.env.AGENT_NAME || "agent";
const AGENT_BIN = process.env.AGENT_BIN || AGENT_NAME;
const AGENT_RUN_MODE = process.env.AGENT_RUN_MODE || "opencode";
const TIMEOUT_MS = Number(process.env.AGENT_TIMEOUT_MS || 10 * 60 * 1000);

function buildArgv(prompt, { model, agent }) {
  switch (AGENT_RUN_MODE) {
    case "opencode": {
      const argv = ["run"];
      if (model) argv.push("--model", model);
      if (agent) argv.push("--agent", agent);
      argv.push(prompt);
      return argv;
    }
    case "commandcode": {
      // Verify against `cmd exec --help` once CommandCode is installed —
      // the flag names below are the convention; adjust if cmd uses different ones.
      const argv = ["exec"];
      if (model) argv.push("--model", model);
      if (agent) argv.push("--agent", agent);
      argv.push(prompt);
      return argv;
    }
    case "claude-code": {
      const argv = ["-p"];
      if (model) argv.push("--model", model);
      argv.push(prompt);
      return argv;
    }
    default:
      throw new Error(`Unknown AGENT_RUN_MODE: ${AGENT_RUN_MODE}`);
  }
}

function runAgent({ prompt, model, agent, workingDir }) {
  return new Promise((resolve, reject) => {
    const argv = buildArgv(prompt, { model, agent });
    const child = spawn(AGENT_BIN, argv, {
      cwd: workingDir || process.cwd(),
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`${AGENT_NAME} timed out after ${TIMEOUT_MS}ms`));
    }, TIMEOUT_MS);

    child.stdout.on("data", (b) => (stdout += b.toString()));
    child.stderr.on("data", (b) => (stderr += b.toString()));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) {
        resolve(stdout.trim() || "(no stdout)");
      } else {
        reject(
          new Error(
            `${AGENT_NAME} exited with code ${code}\n--- stderr ---\n${stderr.trim() || "(empty)"}`
          )
        );
      }
    });
  });
}

const TOOL_NAME = `delegate_to_${AGENT_NAME}`;

const server = new Server(
  { name: `${AGENT_NAME}-mcp`, version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: TOOL_NAME,
      description:
        `Delegate a task to ${AGENT_NAME}. Pass a self-contained prompt; ` +
        `the subagent runs non-interactively and its final output is returned as text.`,
      inputSchema: {
        type: "object",
        properties: {
          prompt: {
            type: "string",
            description: "Self-contained task description for the subagent.",
          },
          model: {
            type: "string",
            description: "Optional model override (e.g. 'anthropic/claude-sonnet-4-6').",
          },
          agent: {
            type: "string",
            description:
              "Optional named persona file (without extension) to invoke, e.g. 'refactor'.",
          },
          working_dir: {
            type: "string",
            description: "Optional working directory for the subagent.",
          },
        },
        required: ["prompt"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name !== TOOL_NAME) {
    throw new Error(`Unknown tool: ${req.params.name}`);
  }
  const { prompt, model, agent, working_dir } = req.params.arguments || {};
  if (!prompt || typeof prompt !== "string") {
    throw new Error("`prompt` is required and must be a string");
  }
  try {
    const output = await runAgent({
      prompt,
      model,
      agent,
      workingDir: working_dir,
    });
    return { content: [{ type: "text", text: output }] };
  } catch (err) {
    return {
      content: [{ type: "text", text: `ERROR: ${err.message}` }],
      isError: true,
    };
  }
});

await server.connect(new StdioServerTransport());
