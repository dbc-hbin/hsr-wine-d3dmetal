import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { test } from "node:test";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const upstreamArchive = join(repoRoot, "build/upstream-0.3.18/resources_napos.neu");
const transformerOption = process.argv.indexOf("--transformer");
assert.ok(transformerOption === -1 || process.argv[transformerOption + 1], "--transformer requires a path");
const transformerPath = transformerOption === -1
  ? join(repoRoot, "installer/resources/AsarTransform.js")
  : resolve(process.argv[transformerOption + 1]);
const targetId = "11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server";
const otherD3DMetalId = "other-d3dmetal-wine";
const transformerOptions = {
  registrationHelperPath: "/safe/zzz-wine-register",
  archivePath: "/safe/wine.tar.xz",
};

function archiveFile(archive, pathname) {
  const headerSize = archive.readUInt32LE(8);
  const headerLength = archive.readUInt32LE(12);
  let entry = JSON.parse(archive.subarray(16, 16 + headerLength).toString("utf8")).files;
  for (const component of pathname.split("/")) {
    entry = entry[component];
    assert.ok(entry, `upstream archive does not contain ${pathname}`);
    if (entry.files) entry = entry.files;
  }
  assert.equal(typeof entry.size, "number", `${pathname} is not an archive file`);
  const start = 12 + headerSize + Number(entry.offset);
  return archive.subarray(start, start + entry.size).toString("utf8");
}

function loadTransformer(pathname) {
  const transformerDirectory = dirname(pathname);
  const adjacentTypeScript = join(transformerDirectory, "typescript.js");
  const typeScriptPath = existsSync(adjacentTypeScript)
    ? adjacentTypeScript
    : join(dirname(transformerPath), "typescript.js");
  const context = vm.createContext({ URL });
  vm.runInContext(readFileSync(typeScriptPath, "utf8"), context, {
    filename: typeScriptPath,
  });
  vm.runInContext(readFileSync(pathname, "utf8"), context, { filename: pathname });
  assert.equal(typeof context.__asarTransform, "function", "transformer did not register its entry point");
  return { transform: context.__asarTransform, ts: context.ts };
}

function transformSource(transformer, source) {
  const transformed = transformer.transform(
    source,
    targetId,
    "Wine 11.17 ZZZ DX12",
    "file:///safe/wine.tar.xz",
    transformerOptions,
  );
  assert.equal(transformed.error, undefined, transformed.error);
  return transformed;
}

function upstreamFunctions(ts, source) {
  const file = ts.createSourceFile("upstream.js", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  const found = new Map();
  const visit = node => {
    if (ts.isFunctionDeclaration(node) && node.name && (node.name.text === "oc" || node.name.text === "V_")) {
      found.set(node.name.text, source.slice(node.getStart(file), node.end));
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  assert.equal(found.size, 2, "supported upstream frontend must retain its runner factory and game launch function");
  return { factory: found.get("oc"), launch: found.get("V_") };
}

function launchHarness(ts, source, distribution) {
  const writes = new Map();
  const executions = [];
  const { factory, launch } = upstreamFunctions(ts, source);
  const context = vm.createContext({
    H: {
      join: posix.join,
      dirname: value => {
        if (typeof value !== "string") throw new Error(`unexpected dirname input: ${JSON.stringify(value)}`);
        return posix.dirname(value);
      },
    },
    E4: async () => "/safe/wine/bin/wine",
    $e: async (...args) => {
      executions.push(args);
      return { stdout: "", stderr: "" };
    },
    Fr: async (...args) => {
      executions.push(args);
      return { stdout: "", stderr: "" };
    },
    hr: "/safe/wine",
    Vl: async () => "/safe/wine/bin/wine",
    xe: error => {
      throw error;
    },
    ge: async () => {},
    z_: async () => {},
    O_: async function* () {},
    xd: async function* () {},
    Mt: async () => {},
    ct: async () => {},
    Ut: async (pathname, contents) => {
      writes.set(pathname, contents);
    },
    Y: pathname => posix.join("/safe/working", pathname),
    atob: value => Buffer.from(value, "base64").toString("binary"),
    Ve: async error => {
      throw new Error(error);
    },
    j_: async () => {},
    Date,
  });
  vm.runInContext(`${factory}\nglobalThis.__runnerFactory=oc;\n${launch}\nglobalThis.__launch=V_;`, context, {
    filename: "transformed-upstream-launch.js",
  });

  return {
    async run(steamPatch) {
      const runner = await context.__runnerFactory({
        prefix: "/safe/prefix",
        distro: distribution,
      });
      assert.equal(Object.hasOwn(runner, "id"), false, "upstream runner must be used without an invented runner.id");
      assert.equal(runner.attributes.id, distribution.attributes.id, "actual oc factory must preserve distro attributes");

      const config = {
        resolutionCustom: false,
        steamPatch,
        metalHud: false,
        timeoutFix: false,
        proxyEnabled: false,
        blockNet: false,
      };
      for await (const _ of context.__launch({
        gameDir: "/safe/game",
        gameExecutable: "ZenlessZoneZero.exe",
        wine: runner,
        config,
        server: { id: "nap_global" },
      })) {
        // The UI state yields are deliberately not part of this launch-boundary regression.
      }
      return { writes, executions };
    },
  };
}

function distribution(id, backend = "d3dmetal") {
  return {
    id,
    displayName: id,
    remoteUrl: "file:///safe/wine.tar.xz",
    attributes: { id, renderBackend: backend, winePath: "wine" },
  };
}

function useD3D12Count(value) {
  return Array.isArray(value)
    ? value.flat(Infinity).filter(argument => argument === "-use-d3d12").length
    : value.split("-use-d3d12").length - 1;
}

async function assertLaunchArguments(ts, transformedSource, distro, steamPatch, expectedCount) {
  const harness = launchHarness(ts, transformedSource, distro);
  const { writes, executions } = await harness.run(steamPatch);
  if (steamPatch) {
    const steam = executions.find(call => call.flat(Infinity).includes("C:\\windows\\system32\\steam.exe"));
    assert.ok(steam, "Steam launch must reach the stubbed process boundary");
    assert.equal(useD3D12Count(steam), expectedCount, "Steam game arguments must contain the expected number of DX12 flags");
    assert.ok(steam.flat(Infinity).includes("Z:\\safe\\game\\ZenlessZoneZero.exe"), "Steam must receive the game executable");
  } else {
    const batch = writes.get("/safe/working/config.bat");
    assert.ok(batch, "normal launch must write its game batch file");
    assert.equal(useD3D12Count(batch), expectedCount, "normal game batch must contain the expected number of DX12 flags");
    assert.match(batch, /ZenlessZoneZero\.exe/, "normal game batch must invoke the game executable");
  }
}

async function assertFixedTransformer(transformer, source) {
  const first = transformSource(transformer, source);
  assert.equal(first.changed, true, "first registration must modify the pristine upstream frontend");

  const second = transformSource(transformer, first.source);
  assert.equal(second.changed, false, "re-registering an already transformed frontend must be idempotent");
  assert.equal(second.source, first.source, "idempotent registration must retain the transformed frontend byte-for-byte");

  for (const steamPatch of [false, true]) {
    await assertLaunchArguments(transformer.ts, first.source, distribution(targetId), steamPatch, 1);
    await assertLaunchArguments(transformer.ts, first.source, distribution(otherD3DMetalId), steamPatch, 0);
  }
}

function optionalLegacyTransformerPath() {
  const position = process.argv.indexOf("--legacy-transformer");
  if (position === -1) return undefined;
  const pathname = process.argv[position + 1];
  assert.ok(pathname, "--legacy-transformer requires a path");
  return resolve(pathname);
}

const upstreamSource = archiveFile(readFileSync(upstreamArchive), "dist/assets/index.6abd63f7.js");
const transformer = loadTransformer(transformerPath);
const legacyTransformerPath = optionalLegacyTransformerPath();

test("DX12 launch registration reaches only the selected D3DMetal runtime", async () => {
  await assertFixedTransformer(transformer, upstreamSource);
});

if (legacyTransformerPath) {
  test("saved pre-fix transformer demonstrates the repaired runtime boundary", async () => {
    const legacy = loadTransformer(legacyTransformerPath);
    const priorPatched = transformSource(legacy, upstreamSource);
    assert.equal(priorPatched.changed, true, "saved pre-fix transformer must transform the supported upstream frontend");

    // This invokes the real oc-created runner. It has no runner.id, so the old
    // guard cannot put the flag in the normal batch path.
    await assertLaunchArguments(legacy.ts, priorPatched.source, distribution(targetId), false, 0);

    const upgraded = transformSource(transformer, priorPatched.source);
    assert.equal(upgraded.changed, true, "the current transformer must upgrade a previously patched frontend");
    for (const steamPatch of [false, true]) {
      await assertLaunchArguments(transformer.ts, upgraded.source, distribution(targetId), steamPatch, 1);
      await assertLaunchArguments(transformer.ts, upgraded.source, distribution(otherD3DMetalId), steamPatch, 0);
    }
    const repeatedUpgrade = transformSource(transformer, upgraded.source);
    assert.equal(repeatedUpgrade.changed, false, "upgrading a previously patched frontend must become idempotent");
  });
}
