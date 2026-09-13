import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  applyFP64CodecPatch,
  FP64_CODEC_PATCH_SITES,
  inspectFP64CodecPatch,
} from "./metalir-fp64-codec-patch.mjs";

const fixtureSize = Math.max(
  ...FP64_CODEC_PATCH_SITES.map(
    site => site.offset + site.expectedOriginal.length
  )
);

function pristineFixture() {
  const fixture = Buffer.alloc(fixtureSize);
  for (const site of FP64_CODEC_PATCH_SITES) {
    site.expectedOriginal.copy(fixture, site.offset);
  }
  return fixture;
}

// Execute only the actual gate's cmp, near je/jne and jmp instructions.
// Context members stand for distinct LLVM type pointers; unsupported machine
// bytes fail rather than acquiring invented emulator semantics.
function runIntegerGate(bytes, sourceType) {
  const context = new Map([[0x7d8, "i1"], [0x7f0, "i32"]]);
  const visited = [];
  let pc = 0xa19f88;
  let equal = false;
  for (let step = 0; step < 6; step += 1) {
    if (pc === 0xa19f95 || pc === 0xa1b3d6) {
      return { destination: pc, visited };
    }
    visited.push(pc);
    if (bytes.subarray(pc, pc + 3).equals(Buffer.from("493b81", "hex"))) {
      const displacement = bytes.readInt32LE(pc + 3);
      assert.ok(context.has(displacement), "comparison must use a known type member");
      equal = sourceType === context.get(displacement);
      pc += 7;
    } else if (bytes[pc] === 0x0f && (bytes[pc + 1] === 0x84 || bytes[pc + 1] === 0x85)) {
      const taken = bytes[pc + 1] === 0x84 ? equal : !equal;
      pc += 6 + (taken ? bytes.readInt32LE(pc + 2) : 0);
    } else if (bytes[pc] === 0xe9) {
      pc += 5 + bytes.readInt32LE(pc + 1);
    } else {
      assert.fail(`unexpected gate instruction at 0x${pc.toString(16)}`);
    }
  }
  assert.fail("gate did not reach its original success/error continuation");
}

describe("GPTK 4.0b2 Metal IR FP64 codec patch", () => {
  it("emits the locked branches and preserves bytes outside the patch regions", () => {
    const pristine = pristineFixture();
    const original = Buffer.from(pristine);
    assert.equal(inspectFP64CodecPatch(pristine).mode, "original");

    const patched = applyFP64CodecPatch(pristine);
    assert.equal(inspectFP64CodecPatch(patched).mode, "patched");
    assert.deepEqual(pristine, original, "patching must not mutate its input");
    assert.equal(patched.subarray(0xa19f88, 0xa19f95).toString("hex"), "493b81d80700000f855b059400");
    assert.equal(patched.subarray(0x135a4f0, 0x135a502).toString("hex"), "493b81f00700000f8498fa6bffe9d40e6cff");
    assert.equal(patched.subarray(0xa1b900, 0xa1b904).toString("hex"), "b5e1ffff");
    assert.equal(patched.subarray(0xa1a147, 0xa1a14c).toString("hex"), "8d75e49090");
    assert.deepEqual(patched.subarray(0x135a502, 0x135b000), Buffer.alloc(0xafe));

    const restored = Buffer.from(patched);
    for (const site of FP64_CODEC_PATCH_SITES) {
      site.expectedOriginal.copy(restored, site.offset);
    }
    assert.deepEqual(restored, pristine, "no bytes outside declared regions may change");
  });

  it("keeps the original i1 fast path, adds i32, and rejects other source types", () => {
    const pristine = pristineFixture();
    const patched = applyFP64CodecPatch(pristine);
    const originalI1 = runIntegerGate(pristine, "i1");
    assert.deepEqual(originalI1, { destination: 0xa19f95, visited: [0xa19f88, 0xa19f8f] });
    assert.deepEqual(runIntegerGate(patched, "i1"), originalI1);
    assert.equal(runIntegerGate(pristine, "i32").destination, 0xa1b3d6);
    assert.deepEqual(runIntegerGate(patched, "i32"), {
      destination: 0xa19f95,
      visited: [0xa19f88, 0xa19f8f, 0x135a4f0, 0x135a4f7],
    });
    assert.deepEqual(runIntegerGate(patched, "i64"), {
      destination: 0xa1b3d6,
      visited: [0xa19f88, 0xa19f8f, 0x135a4f0, 0x135a4f7, 0x135a4fd],
    });
  });

  it("fails closed on partial and already patched binaries", () => {
    for (const site of FP64_CODEC_PATCH_SITES) {
      const partial = pristineFixture();
      site.patched.copy(partial, site.offset);
      assert.equal(inspectFP64CodecPatch(partial).mode, "unknown-or-partial", site.name);
      assert.throws(() => applyFP64CodecPatch(partial), /refusing patch/);
    }
    const patched = applyFP64CodecPatch(pristineFixture());
    assert.throws(() => applyFP64CodecPatch(patched), /refusing patch/);
  });

  it("rejects changes to the preserved i1 compare, branches, guard, or unused padding", () => {
    for (const initial of [pristineFixture(), applyFP64CodecPatch(pristineFixture())]) {
      for (const offset of [0xa19f8b, 0xa19f91, 0x135a4f0, 0x135a4fa, 0x135afff]) {
        const corrupted = Buffer.from(initial);
        corrupted[offset] ^= 1;
        assert.equal(inspectFP64CodecPatch(corrupted).mode, "unknown-or-partial", `0x${offset.toString(16)}`);
        assert.throws(() => applyFP64CodecPatch(corrupted), /refusing patch/);
      }
    }
  });

  it("does not recognize the legacy three-site i32-only patch as original or current", () => {
    const legacy = pristineFixture();
    legacy[0xa19f8b] = 0xf0;
    Buffer.from("b5e1ffff", "hex").copy(legacy, 0xa1b900);
    Buffer.from("8d75e49090", "hex").copy(legacy, 0xa1a147);
    assert.equal(inspectFP64CodecPatch(legacy).mode, "unknown-or-partial");
    assert.throws(() => applyFP64CodecPatch(legacy), /refusing patch/);
  });

  it("reports truncated input without throwing", () => {
    for (const truncated of [Buffer.alloc(8), pristineFixture().subarray(0, 0x135afff)]) {
      const inspection = inspectFP64CodecPatch(truncated);
      assert.equal(inspection.mode, "unknown-or-partial");
      assert.ok(inspection.sites.some(site => site.value === "truncated"));
      assert.throws(() => applyFP64CodecPatch(truncated), /refusing patch/);
    }
  });
});
