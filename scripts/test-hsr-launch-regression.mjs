import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixturePath = join(repoRoot, "scripts/fixtures/hsr-launch-regression-official.js");
const option = process.argv.indexOf("--transformer");
assert.ok(option === -1 || process.argv[option + 1], "--transformer requires a path");
const transformerPath = option === -1
  ? join(repoRoot, "installer/resources/AsarTransform.js")
  : resolve(process.argv[option + 1]);
const targetId = "11.17-hsr-gptk4b2-stock";
const displayName = "Wine 11.17 GPTK4.0b2";
const archiveURL = "file:///safe/wine-11.17-hsr-gptk4b2-stock.tar.xz";
const options = {
  registrationHelperPath: "/safe/hsr-wine-register",
  archivePath: "/safe/wine-11.17-hsr-gptk4b2-stock.tar.xz",
};

const typescriptSource = await readFile(join(repoRoot, "installer/resources/typescript.js"), "utf8");
const transformerSource = await readFile(transformerPath, "utf8");
const fixtureSource = await readFile(fixturePath, "utf8");

function transform(source) {
  const context = vm.createContext({ console });
  vm.runInContext(typescriptSource, context);
  vm.runInContext(transformerSource, context);
  const result = context.__asarTransform(source, targetId, displayName, archiveURL, options);
  assert.equal(result.error, undefined, result.error);
  return result;
}

function executable(source) {
  const calls = [];
  const context = vm.createContext({
    console,
    En: async () => "NOTFOUND",
    Xt: async (...args) => { calls.push(["move", ...args]); },
    fl: async (...args) => { calls.push(["copy", ...args]); },
    me: (...args) => { calls.push(["set", ...args]); },
    ke: async (...args) => { calls.push(["clear", ...args]); },
    atob: (value) => Buffer.from(value, "base64").toString("utf8"),
    H: { join },
    Y: (value) => value,
    z_: async (...args) => { calls.push(["acquire", ...args]); },
  });
  vm.runInContext(`${source}\nglobalThis.fixture={catalog:_S,launch:V_,patch:x_,revert:Id};`, context);
  return { ...context.fixture, calls };
}

async function launchEnvironment(launch, distro) {
  let environment;
  const wine = {
    attributes: { ...distro.attributes },
    setProps: async () => {},
    exec2: async (_command, _arguments, env) => { environment = env; },
    waitUntilServerOff: async () => {},
    toWinePath: (value) => value,
  };
  const generator = launch({
    gameDir: "/safe/game",
    gameExecutable: "StarRail.exe",
    wine,
    config: { resolutionCustom: false },
    server: { id: "hkrpg_global" },
  });
  for await (const _step of generator) { /* exhaust official launch program */ }
  return environment;
}

test("HSR stock runtime is selectable and launches with builtin D3D11", async () => {
  const first = transform(fixtureSource);
  assert.equal(first.changed, true);
  const { catalog, launch, calls } = executable(first.source);
  const stock = catalog.find((item) => item.id === targetId);
  assert.deepEqual(JSON.parse(JSON.stringify(stock)), {
    id: targetId,
    displayName,
    remoteUrl: archiveURL,
    attributes: { id: targetId, renderBackend: "d3dmetal", winePath: "wine" },
  });

  const env = await launchEnvironment(launch, stock);
  assert.equal(env.WINEDLLOVERRIDES, "d3d11,dxgi=b");
  assert.equal(env.WINEESYNC, "1");
  assert.equal(env.WINEMSYNC, undefined);
  assert.equal(env.DXMT_CONFIG_FILE, undefined);
  assert.equal(calls.some(([kind]) => kind === "acquire"), false);

  const second = transform(first.source);
  assert.equal(second.changed, false, "registration must be idempotent");
});

test("official unconditional DXMT staging and restore are skipped only for stock", async () => {
  const { patch, revert, calls } = executable(transform(fixtureSource).source);
  const exhaust = async (program) => { for await (const _step of program) { /* exhaust */ } };
  const stockWine = { prefix: "/prefix", attributes: { id: targetId, renderBackend: "d3dmetal" } };
  await exhaust(patch("/game", stockWine, { id: "hkrpg_global", patched: [], removed: [], added: [] }, {}));
  await exhaust(revert("/game", stockWine, {}, {}));
  assert.deepEqual(calls.filter(([kind]) => kind === "move" || kind === "copy"), []);

  const ordinaryWine = { prefix: "/prefix", attributes: { id: "crossover", renderBackend: "dxmt" } };
  await exhaust(patch("/game", ordinaryWine, { id: "hkrpg_global", patched: [], removed: [], added: [] }, {}));
  assert.ok(calls.some(([kind]) => kind === "copy"), "ordinary DXMT must retain staging");
  await exhaust(revert("/game", ordinaryWine, {}, {}));
  assert.ok(calls.filter(([kind]) => kind === "move").length > 0, "ordinary DXMT must retain restore");
});

test("ordinary HSR DXMT runtime keeps upstream launch behavior", async () => {
  const { catalog, launch, calls } = executable(transform(fixtureSource).source);
  const ordinary = catalog.find((item) => item.id === "9.0-crossover-hsr");
  const env = await launchEnvironment(launch, {
    ...ordinary,
    attributes: { id: ordinary.id, renderBackend: "dxmt", winePath: "wine" },
  });
  assert.equal(env.WINEDLLOVERRIDES, "");
  assert.equal(env.WINEMSYNC, "1");
  assert.match(env.DXMT_CONFIG_FILE, /dxmt\.conf$/);
  assert.equal(env.WINEESYNC, undefined);
  assert.equal(calls.some(([kind]) => kind === "acquire"), true);
});

test("unsupported client bundle is rejected accurately", () => {
  const nap = fixtureSource.replace("GAME_RUNNING", "RUNNING_OTHER_CLIENT");
  const context = vm.createContext({ console });
  vm.runInContext(typescriptSource, context);
  vm.runInContext(transformerSource, context);
  const result = context.__asarTransform(nap, targetId, displayName, archiveURL, options);
  assert.equal(result.error, "could not unambiguously locate the HSR game launch function");
});
