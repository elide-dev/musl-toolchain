import * as core from "@actions/core";
import * as tc from "@actions/tool-cache";
import * as io from "@actions/io";
import { createHash } from "crypto";
import { readFile } from "fs/promises";
import { join } from "path";

const BASE_URL = "https://static.elideusercontent.com";
const TOOL_NAME = "musl-toolchain";

/**
 * Convert arbitrary revision string to semver-compatible version.
 * tc.find() and tc.cacheDir() require valid semver versions.
 */
function toSemver(revision: string): string {
  // If already semver-like, return as-is
  if (/^\d+\.\d+\.\d+/.test(revision)) {
    return revision;
  }
  // Otherwise, use as build metadata: 0.0.0+<revision>
  return `0.0.0+${revision}`;
}

async function computeSha256(filePath: string): Promise<string> {
  const content = await readFile(filePath);
  return createHash("sha256").update(content).digest("hex");
}

async function parseHashFile(hashFilePath: string): Promise<string> {
  const content = await readFile(hashFilePath, "utf-8");
  // SHA256 files typically have format: "<hash>  <filename>" or just "<hash>"
  const hash = content.trim().split(/\s+/)[0];
  if (!hash || hash.length !== 64) {
    throw new Error(`Invalid SHA256 hash file content: ${content}`);
  }
  return hash.toLowerCase();
}

async function run(): Promise<void> {
  try {
    const revision = core.getInput("revision", { required: true });
    const arch = core.getInput("arch") || "x86_64-linux-musl";
    const version = toSemver(revision);

    const toolchainFilename = `${TOOL_NAME}-${revision}-${arch}.txz`;
    const toolchainUrl = `${BASE_URL}/${toolchainFilename}`;
    const sha256Url = `${toolchainUrl}.sha256`;

    core.info(`Musl toolchain revision: ${revision}`);
    core.info(`Cache version: ${version}`);
    core.info(`Architecture: ${arch}`);

    // Check tool cache first
    const cachedPath = tc.find(TOOL_NAME, version, arch);
    if (cachedPath) {
      core.info(`Found cached toolchain at: ${cachedPath}`);
      await configureEnvironment(cachedPath);
      return;
    }

    core.info(`Toolchain not cached, downloading...`);
    core.info(`Downloading toolchain from: ${toolchainUrl}`);
    core.info(`Downloading checksum from: ${sha256Url}`);

    // Download both files
    const [toolchainPath, sha256Path] = await Promise.all([
      tc.downloadTool(toolchainUrl),
      tc.downloadTool(sha256Url),
    ]);

    core.info(`Downloaded toolchain to: ${toolchainPath}`);
    core.info(`Downloaded checksum to: ${sha256Path}`);

    // Verify SHA256
    core.info("Verifying SHA256 checksum...");
    const expectedHash = await parseHashFile(sha256Path);
    const actualHash = await computeSha256(toolchainPath);

    if (expectedHash !== actualHash) {
      throw new Error(
        `SHA256 mismatch!\n  Expected: ${expectedHash}\n  Actual:   ${actualHash}`
      );
    }
    core.info("SHA256 checksum verified successfully");

    // Extract the tarball (.txz = tar with xz compression)
    core.info("Extracting toolchain...");
    const extractedPath = await tc.extractTar(toolchainPath, undefined, [
      "xJ", // x = extract, J = xz compression
    ]);
    core.info(`Extracted to: ${extractedPath}`);

    // Cache the extracted toolchain
    core.info("Caching toolchain...");
    const toolchainRoot = await tc.cacheDir(
      extractedPath,
      TOOL_NAME,
      version,
      arch
    );
    core.info(`Cached toolchain at: ${toolchainRoot}`);

    await configureEnvironment(toolchainRoot);
  } catch (error) {
    if (error instanceof Error) {
      core.setFailed(error.message);
    } else {
      core.setFailed(String(error));
    }
  }
}

async function configureEnvironment(toolchainRoot: string): Promise<void> {
  const binDir = join(toolchainRoot, "bin");

  // Verify bin directory exists
  try {
    await io.which(binDir, false);
  } catch {
    core.warning(`bin directory may not exist at: ${binDir}`);
  }

  // Set MUSL_HOME environment variable
  core.exportVariable("MUSL_HOME", toolchainRoot);
  core.info(`Set MUSL_HOME=${toolchainRoot}`);

  // Add bin to PATH
  core.addPath(binDir);
  core.info(`Added ${binDir} to PATH`);

  // Set output
  core.setOutput("musl-home", toolchainRoot);
}

run();

