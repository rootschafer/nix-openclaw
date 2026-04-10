import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { resolveNpmRunner } from "./npm-runner.mjs";

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function removePathIfExists(targetPath) {
  fs.rmSync(targetPath, { recursive: true, force: true });
}

function makeTempDir(parentDir, prefix) {
  return fs.mkdtempSync(path.join(parentDir, prefix));
}

function sanitizeTempPrefixSegment(value) {
  const normalized = value.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/-+/g, "-");
  return normalized.length > 0 ? normalized : "plugin";
}

function replaceDir(targetPath, sourcePath) {
  removePathIfExists(targetPath);
  try {
    fs.renameSync(sourcePath, targetPath);
    return;
  } catch (error) {
    if (error?.code !== "EXDEV") {
      throw error;
    }
  }
  fs.cpSync(sourcePath, targetPath, { recursive: true, force: true });
  removePathIfExists(sourcePath);
}

function dependencyNodeModulesPath(nodeModulesDir, depName) {
  return path.join(nodeModulesDir, ...depName.split("/"));
}

function createResolver(fromDir) {
  return createRequire(path.join(fromDir, "__openclaw-runtime-deps-resolver__.cjs"));
}

function findPackageRoot(startPath, depName) {
  let currentDir = fs.statSync(startPath).isDirectory() ? startPath : path.dirname(startPath);
  while (true) {
    const packageJsonPath = path.join(currentDir, "package.json");
    if (fs.existsSync(packageJsonPath)) {
      const packageJson = readJson(packageJsonPath);
      if (packageJson.name === depName) {
        return {
          dir: currentDir,
          packageJsonPath,
        };
      }
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      return null;
    }
    currentDir = parentDir;
  }
}

function resolveDependencyFromNodeModulesPath(fromDir, depName) {
  let currentDir = fromDir;
  while (true) {
    const nodeModulesDir =
      path.basename(currentDir) === "node_modules" ? currentDir : path.join(currentDir, "node_modules");
    const directPath = dependencyNodeModulesPath(nodeModulesDir, depName);
    const packageJsonPath = path.join(directPath, "package.json");
    if (fs.existsSync(packageJsonPath)) {
      return {
        dir: directPath,
        packageJsonPath,
      };
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      return null;
    }
    currentDir = parentDir;
  }
}

function resolveInstalledDependency(fromDir, depName) {
  const directResolution = resolveDependencyFromNodeModulesPath(fromDir, depName);
  if (directResolution !== null) {
    return directResolution;
  }

  const resolver = createResolver(fromDir);
  try {
    return findPackageRoot(resolver.resolve(`${depName}/package.json`), depName);
  } catch {}

  try {
    return findPackageRoot(resolver.resolve(depName), depName);
  } catch {}

  return null;
}

function stageInstalledRuntimeTree(rootNodeModulesDir, packageJson, stagedNodeModulesDir) {
  const packageCache = new Map();
  const stagedTargets = new Set();
  const queue = [
    ...Object.entries(packageJson.dependencies ?? {}).map(([depName, spec]) => ({
      depName,
      spec,
      fromDir: rootNodeModulesDir,
      isOptional: false,
      targetNodeModulesDir: stagedNodeModulesDir,
    })),
    ...Object.entries(packageJson.optionalDependencies ?? {}).map(([depName, spec]) => ({
      depName,
      spec,
      fromDir: rootNodeModulesDir,
      isOptional: true,
      targetNodeModulesDir: stagedNodeModulesDir,
    })),
  ];
  stageInstalledRuntimeTree.lastFailure = null;

  while (queue.length > 0) {
    const { depName, fromDir, isOptional, spec, targetNodeModulesDir } = queue.shift();
    const resolvedDep = resolveInstalledDependency(fromDir, depName);
    if (resolvedDep === null) {
      if (isOptional) {
        continue;
      }
      stageInstalledRuntimeTree.lastFailure =
        fromDir === rootNodeModulesDir
          ? `missing ${depName} (${spec}) from root`
          : `missing ${depName} (${spec}) from ${fromDir}`;
      return false;
    }

    const packageJson =
      packageCache.get(resolvedDep.packageJsonPath) ?? readJson(resolvedDep.packageJsonPath);
    packageCache.set(resolvedDep.packageJsonPath, packageJson);

    const targetPath = dependencyNodeModulesPath(targetNodeModulesDir, depName);
    if (!stagedTargets.has(targetPath)) {
      fs.mkdirSync(path.dirname(targetPath), { recursive: true });
      fs.cpSync(resolvedDep.dir, targetPath, { recursive: true, force: true, dereference: true });
      stagedTargets.add(targetPath);
    }

    const childTargetNodeModulesDir = path.join(targetPath, "node_modules");
    for (const [childName, childSpec] of Object.entries(packageJson.dependencies ?? {})) {
      queue.push({
        depName: childName,
        spec: childSpec,
        fromDir: resolvedDep.dir,
        isOptional: false,
        targetNodeModulesDir: childTargetNodeModulesDir,
      });
    }
    for (const [childName, childSpec] of Object.entries(packageJson.optionalDependencies ?? {})) {
      queue.push({
        depName: childName,
        spec: childSpec,
        fromDir: resolvedDep.dir,
        isOptional: true,
        targetNodeModulesDir: childTargetNodeModulesDir,
      });
    }
  }

  return true;
}

function listBundledPluginRuntimeDirs(repoRoot) {
  const extensionsRoot = path.join(repoRoot, "dist", "extensions");
  if (!fs.existsSync(extensionsRoot)) {
    return [];
  }

  return fs
    .readdirSync(extensionsRoot, { withFileTypes: true })
    .filter((dirent) => dirent.isDirectory())
    .map((dirent) => path.join(extensionsRoot, dirent.name))
    .filter((pluginDir) => fs.existsSync(path.join(pluginDir, "package.json")));
}

function hasRuntimeDeps(packageJson) {
  return (
    Object.keys(packageJson.dependencies ?? {}).length > 0 ||
    Object.keys(packageJson.optionalDependencies ?? {}).length > 0
  );
}

function shouldStageRuntimeDeps(packageJson) {
  return packageJson.openclaw?.bundle?.stageRuntimeDependencies === true;
}

function sanitizeBundledManifestForRuntimeInstall(pluginDir) {
  const manifestPath = path.join(pluginDir, "package.json");
  const packageJson = readJson(manifestPath);
  let changed = false;

  if (packageJson.peerDependencies?.openclaw) {
    const nextPeerDependencies = { ...packageJson.peerDependencies };
    delete nextPeerDependencies.openclaw;
    if (Object.keys(nextPeerDependencies).length === 0) {
      delete packageJson.peerDependencies;
    } else {
      packageJson.peerDependencies = nextPeerDependencies;
    }
    changed = true;
  }

  if (packageJson.peerDependenciesMeta?.openclaw) {
    const nextPeerDependenciesMeta = { ...packageJson.peerDependenciesMeta };
    delete nextPeerDependenciesMeta.openclaw;
    if (Object.keys(nextPeerDependenciesMeta).length === 0) {
      delete packageJson.peerDependenciesMeta;
    } else {
      packageJson.peerDependenciesMeta = nextPeerDependenciesMeta;
    }
    changed = true;
  }

  if (packageJson.devDependencies?.openclaw) {
    const nextDevDependencies = { ...packageJson.devDependencies };
    delete nextDevDependencies.openclaw;
    if (Object.keys(nextDevDependencies).length === 0) {
      delete packageJson.devDependencies;
    } else {
      packageJson.devDependencies = nextDevDependencies;
    }
    changed = true;
  }

  if (changed) {
    writeJson(manifestPath, packageJson);
  }

  return packageJson;
}

function resolveRuntimeDepsStampPath(pluginDir) {
  return path.join(pluginDir, ".openclaw-runtime-deps-stamp.json");
}

function createRuntimeDepsFingerprint(packageJson) {
  return createHash("sha256").update(JSON.stringify(packageJson)).digest("hex");
}

function readRuntimeDepsStamp(stampPath) {
  if (!fs.existsSync(stampPath)) {
    return null;
  }
  try {
    return readJson(stampPath);
  } catch {
    return null;
  }
}

function stageInstalledRootRuntimeDeps(params) {
  const { fingerprint, packageJson, pluginDir, repoRoot } = params;
  const rootNodeModulesDir = path.join(repoRoot, "node_modules");
  const hasDeps =
    Object.keys(packageJson.dependencies ?? {}).length > 0 ||
    Object.keys(packageJson.optionalDependencies ?? {}).length > 0;
  if (!hasDeps || !fs.existsSync(rootNodeModulesDir)) {
    return false;
  }

  const nodeModulesDir = path.join(pluginDir, "node_modules");
  const stampPath = resolveRuntimeDepsStampPath(pluginDir);
  const stagedNodeModulesDir = path.join(
    makeTempDir(
      os.tmpdir(),
      `openclaw-runtime-deps-${sanitizeTempPrefixSegment(path.basename(pluginDir))}-`,
    ),
    "node_modules",
  );

  if (!stageInstalledRuntimeTree(rootNodeModulesDir, packageJson, stagedNodeModulesDir)) {
    console.error(
      `[nix-openclaw] root runtime staging unavailable for ${path.basename(pluginDir)}: ${
        stageInstalledRuntimeTree.lastFailure ?? "unknown reason"
      }`,
    );
    return false;
  }

  try {
    replaceDir(nodeModulesDir, stagedNodeModulesDir);
    writeJson(stampPath, {
      fingerprint,
      generatedAt: new Date().toISOString(),
    });
    return true;
  } finally {
    removePathIfExists(path.dirname(stagedNodeModulesDir));
  }
}

function installPluginRuntimeDeps(params) {
  const { fingerprint, packageJson, pluginDir, pluginId, repoRoot } = params;
  if (
    repoRoot &&
    stageInstalledRootRuntimeDeps({ fingerprint, packageJson, pluginDir, repoRoot })
  ) {
    return;
  }
  console.error(`[nix-openclaw] falling back to npm install for ${pluginId}`);
  const nodeModulesDir = path.join(pluginDir, "node_modules");
  const stampPath = resolveRuntimeDepsStampPath(pluginDir);
  const tempInstallDir = makeTempDir(
    os.tmpdir(),
    `openclaw-runtime-deps-${sanitizeTempPrefixSegment(pluginId)}-`,
  );
  const npmRunner = resolveNpmRunner({
    npmArgs: [
      "install",
      "--omit=dev",
      "--silent",
      "--ignore-scripts",
      "--legacy-peer-deps",
      "--package-lock=false",
    ],
  });
  try {
    writeJson(path.join(tempInstallDir, "package.json"), packageJson);
    const result = spawnSync(npmRunner.command, npmRunner.args, {
      cwd: tempInstallDir,
      encoding: "utf8",
      env: npmRunner.env,
      stdio: "pipe",
      shell: npmRunner.shell,
      windowsVerbatimArguments: npmRunner.windowsVerbatimArguments,
    });
    if (result.status !== 0) {
      const output = [result.stderr, result.stdout].filter(Boolean).join("\n").trim();
      throw new Error(
        `failed to stage bundled runtime deps for ${pluginId}: ${output || "npm install failed"}`,
      );
    }

    const stagedNodeModulesDir = path.join(tempInstallDir, "node_modules");
    if (!fs.existsSync(stagedNodeModulesDir)) {
      throw new Error(
        `failed to stage bundled runtime deps for ${pluginId}: npm install produced no node_modules directory`,
      );
    }

    replaceDir(nodeModulesDir, stagedNodeModulesDir);
    writeJson(stampPath, {
      fingerprint,
      generatedAt: new Date().toISOString(),
    });
  } finally {
    removePathIfExists(tempInstallDir);
  }
}

function installPluginRuntimeDepsWithRetries(params) {
  const { attempts = 3 } = params;
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      params.install({ ...params.installParams, attempt });
      return;
    } catch (error) {
      lastError = error;
      if (attempt === attempts) {
        break;
      }
    }
  }
  throw lastError;
}

export function stageBundledPluginRuntimeDeps(params = {}) {
  const repoRoot = params.cwd ?? params.repoRoot ?? process.cwd();
  const installPluginRuntimeDepsImpl =
    params.installPluginRuntimeDepsImpl ?? installPluginRuntimeDeps;
  const installAttempts = params.installAttempts ?? 3;
  for (const pluginDir of listBundledPluginRuntimeDirs(repoRoot)) {
    const pluginId = path.basename(pluginDir);
    const packageJson = sanitizeBundledManifestForRuntimeInstall(pluginDir);
    const nodeModulesDir = path.join(pluginDir, "node_modules");
    const stampPath = resolveRuntimeDepsStampPath(pluginDir);
    if (!hasRuntimeDeps(packageJson) || !shouldStageRuntimeDeps(packageJson)) {
      removePathIfExists(nodeModulesDir);
      removePathIfExists(stampPath);
      continue;
    }
    const fingerprint = createRuntimeDepsFingerprint(packageJson);
    const stamp = readRuntimeDepsStamp(stampPath);
    if (fs.existsSync(nodeModulesDir) && stamp?.fingerprint === fingerprint) {
      continue;
    }
    installPluginRuntimeDepsWithRetries({
      attempts: installAttempts,
      install: installPluginRuntimeDepsImpl,
      installParams: {
        fingerprint,
        packageJson,
        pluginDir,
        pluginId,
        repoRoot,
      },
    });
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  stageBundledPluginRuntimeDeps();
}
