// Generic smoke test of a Vela guest module under Node's WASI — what Vela's Executor does with it
// (DefineWasi + exports), without assuming anything about your app's instructions:
// imports, exports, load_module, deploy (with DEPLOY_PARAMS if your deploy needs them), result
// formats, determinism and memory hygiene. Node 20 or 24+ (Node 22 segfaults intermittently in V8).
//
//   node scripts/smoke.mjs build/app.wasm
//   DEPLOY_PARAMS='{"triggerContract":"0x…"}' node scripts/smoke.mjs build/app.wasm
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const wasmPath = process.argv[2];
if (!wasmPath) { console.error("usage: node scripts/smoke.mjs <app.wasm>"); process.exit(2); }
const params = process.env.DEPLOY_PARAMS ?? "";

let failed = 0;
const check = (cond, what) => { console.log((cond ? "  ok   " : "  FAIL ") + what); if (!cond) failed++; };

const mod = await WebAssembly.compile(await readFile(wasmPath));
const foreign = WebAssembly.Module.imports(mod).filter((i) => i.module !== "wasi_snapshot_preview1");
check(foreign.length === 0, `imports only from wasi_snapshot_preview1${foreign.length ? " — foreign: " + foreign.map((i) => i.module + "." + i.name).join(", ") : ""}`);
const exports = new Set(WebAssembly.Module.exports(mod).map((e) => e.name));
for (const name of ["memory", "allocate", "deallocate", "load_module", "deploy", "deposit", "process_request", "trusted_request"]) check(exports.has(name), `export ${name}`);
check(!exports.has("_start"), "no _start (a reactor, not a WASI command)");

const wasi = new WASI({ version: "preview1", args: [], env: {}, returnOnExit: true });
const instance = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi.wasiImport });
wasi.initialize(instance);
const ex = instance.exports;
const mem = () => new Uint8Array(ex.memory.buffer);
function write(text) {
  const b = new TextEncoder().encode(text);
  if (b.length === 0) return { ptr: 0, len: 0, free() {} };
  const ptr = ex.allocate(b.length); mem().set(b, ptr);
  return { ptr, len: b.length, free() { ex.deallocate(ptr, b.length); } };
}
function result(ptr) {
  const m = mem(); const len = new DataView(m.buffer, ptr, 4).getUint32(0, true);
  const text = new TextDecoder().decode(m.slice(ptr + 4, ptr + 4 + len)); ex.deallocate(ptr, 4 + len);
  return { text, json: JSON.parse(text) };
}
const b64 = (s) => Buffer.from(s, "base64").toString("utf8");

const lm = result(ex.load_module(1n));
check(lm.json.error === undefined && typeof lm.json.state === "string" && /^0x[0-9a-f]+$/.test(lm.json.fuel), `load_module → {state, fuel}: ${lm.text.slice(0, 100)}`);
const p = write(params);
const d1 = result(ex.deploy(1n, p.ptr, p.len));
const d2 = result(ex.deploy(1n, p.ptr, p.len));
p.free();
check(d1.json.error === undefined, `deploy${params ? " with DEPLOY_PARAMS" : ""} has no error: ${d1.json.error ?? "ok"}`);
check(typeof d1.json.state === "string" && d1.json.state.length > 0, `deploy state is base64: ${b64(d1.json.state).slice(0, 80)}`);
check(/^0x[0-9a-f]+$/.test(d1.json.fuel), `fuel is a Uint256 hex: ${d1.json.fuel}`);
check(d1.text === d2.text, "deploy twice gives identical bytes (deterministic)");
if (exports.has("get_memory_stats")) {
  const stats = result(ex.get_memory_stats());
  check(stats.json.mapSize <= 1, `no leaked allocations after the calls (live: ${stats.json.mapSize})`);
}
console.log(failed === 0 ? "\nALL OK" : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
