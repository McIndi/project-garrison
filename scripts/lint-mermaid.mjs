import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { execFileSync } from "node:child_process";

function walkMarkdownFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkMarkdownFiles(fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.toLowerCase().endsWith(".md")) {
      out.push(fullPath);
    }
  }
  return out;
}

function extractMermaidBlocks(content) {
  const blocks = [];
  const regex = /```mermaid\s*\n([\s\S]*?)```/g;
  let match = regex.exec(content);
  while (match) {
    blocks.push(match[1].trim());
    match = regex.exec(content);
  }
  return blocks;
}

async function main() {
  const root = process.cwd();
  const docsDir = path.join(root, "docs");
  const candidates = [
    path.join(root, "README.md"),
    path.join(root, "OPERATIONS-RUNBOOK.md"),
  ];

  if (fs.existsSync(docsDir)) {
    candidates.push(...walkMarkdownFiles(docsDir));
  }

  const files = candidates.filter((p) => fs.existsSync(p));

  const failures = [];
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "garrison-mermaid-"));

  const localMmdc = path.join(root, "node_modules", ".bin", process.platform === "win32" ? "mmdc.cmd" : "mmdc");
  const mmdcCommand = fs.existsSync(localMmdc) ? localMmdc : "npx";
  const mmdcBaseArgs = fs.existsSync(localMmdc) ? [] : ["--yes", "@mermaid-js/mermaid-cli"];

  for (const filePath of files) {
    const content = fs.readFileSync(filePath, "utf8");
    const blocks = extractMermaidBlocks(content);
    for (let i = 0; i < blocks.length; i += 1) {
      const code = blocks[i];
      const inputPath = path.join(tmpRoot, `diagram-${Buffer.from(filePath).toString("hex")}-${i + 1}.mmd`);
      const outputPath = path.join(tmpRoot, `diagram-${Buffer.from(filePath).toString("hex")}-${i + 1}.svg`);
      fs.writeFileSync(inputPath, `${code}\n`, "utf8");

      try {
        execFileSync(
          mmdcCommand,
          [...mmdcBaseArgs, "-i", inputPath, "-o", outputPath],
          { stdio: "pipe" }
        );
      } catch (error) {
        failures.push({
          filePath,
          blockIndex: i + 1,
          message: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  fs.rmSync(tmpRoot, { recursive: true, force: true });

  if (failures.length > 0) {
    console.error("Mermaid syntax validation failed:");
    for (const failure of failures) {
      console.error(`- ${failure.filePath} [block ${failure.blockIndex}]`);
      console.error(`  ${failure.message}`);
    }
    process.exit(1);
  }

  console.log("Mermaid syntax validation passed.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
