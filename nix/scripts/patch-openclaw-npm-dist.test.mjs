import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawnSync } from "node:child_process";

const script = path.join(import.meta.dirname, "patch-openclaw-npm-dist.mjs");

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "openclaw-dist-patch-"));
  const dist = path.join(root, "dist");
  fs.mkdirSync(dist);
  fs.writeFileSync(
    path.join(dist, "hardlink-policy-EgX5ySNS.js"),
    `import { p as resolveIsNixMode } from "./paths-BMBAvkNf.js";
import { f as safeRealpathSync } from "./path-DILYn_gk.js";
import path from "node:path";
const NIX_STORE_ROOT = "/nix/store";
function isNixStorePluginRoot(rootDir, realpathCache) {
\tconst rootRealPath = safeRealpathSync(rootDir, realpathCache) ?? path.resolve(rootDir);
\treturn rootRealPath === NIX_STORE_ROOT || rootRealPath.startsWith(\`\${NIX_STORE_ROOT}/\`);
}
function shouldRejectHardlinkedPluginFiles(params) {
\tif (params.origin === "bundled") return false;
\tif (resolveIsNixMode(params.env) && isNixStorePluginRoot(params.rootDir, params.realpathCache)) return false;
\treturn true;
}
export { shouldRejectHardlinkedPluginFiles as t };
`,
  );
  const discoveryPath = path.join(dist, "discovery-7zi_zNvu.js");
  fs.writeFileSync(
    discoveryPath,
    `import { f as safeRealpathSync } from "./path-DILYn_gk.js";
import path from "node:path";
import { t as shouldRejectHardlinkedPluginFiles } from "./hardlink-policy-EgX5ySNS.js";
function validateOwner(params, stat) {
\tif (params.origin !== "bundled" && params.uid !== null && typeof stat.uid === "number" && stat.uid !== params.uid && stat.uid !== 0) return false;
\treturn shouldRejectHardlinkedPluginFiles(params);
}
export { validateOwner };
`,
  );
  const missingInstallPath = path.join(dist, "missing-configured-plugin-install-jsvFew4a.js");
  fs.writeFileSync(
    missingInstallPath,
    `function collectDownloadableInstallCandidates() {
\treturn [];
}
async function repairMissingPluginInstalls(params) {
\tconst env = params.env ?? process.env;
\tconst warnings = [];
\tfor (const candidate of collectDownloadableInstallCandidates({
\t\tcfg: params.cfg,
\t\tenv,
\t})) {
\t\twarnings.push(\`Failed to install missing configured plugin "\${candidate.pluginId}" from \${candidate.npmSpec}: nope\`);
\t}
\tfor (const candidate of collectDownloadableInstallCandidates({
\t\tcfg: params.fallbackCfg,
\t\tenv,
\t})) {
\t\twarnings.push(\`Failed to install missing configured plugin "\${candidate.pluginId}" from \${candidate.npmSpec}: nope\`);
\t}
\treturn { warnings };
}
export { repairMissingPluginInstalls };
`,
  );
  return { root, discoveryPath, missingInstallPath };
}

test("patches ownership check when hardlink policy lives in a separate chunk", () => {
  const { root, discoveryPath, missingInstallPath } = makeFixture();
  const result = spawnSync(process.execPath, [script], {
    env: { ...process.env, OPENCLAW_PACKAGE_ROOT: root },
    encoding: "utf8",
  });

  assert.equal(result.status, 0, result.stderr);
  const patched = fs.readFileSync(discoveryPath, "utf8");
  assert.match(patched, /function isTrustedNixStorePluginRoot/);
  assert.match(patched, /OPENCLAW_NIX_MODE === "1"/);
  assert.match(patched, /!isTrustedNixStorePluginRoot\(params\)/);

  const missingInstallPatched = fs.readFileSync(missingInstallPath, "utf8");
  assert.equal(
    [
      ...missingInstallPatched.matchAll(
        /if \(\(params\.env \?\? process\.env\)\.OPENCLAW_NIX_MODE !== "1"\) for \(const candidate of collectDownloadableInstallCandidates/g,
      ),
    ].length,
    2,
  );
  assert.equal(missingInstallPatched.includes("\n\tfor (const candidate of collectDownloadableInstallCandidates({"), false);
});
