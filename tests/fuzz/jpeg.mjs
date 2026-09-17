// Clang/libFuzzer supplies C coverage and AddressSanitizer independently of Zig.
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const clang = process.argv[2] ?? 'clang';
const count = /^(\d+)([KMG]?)$/i.exec(process.argv[3] ?? '100K');
if (!count) throw new Error('Run count must be a positive integer, optionally followed by K, M or G.');
const runs = Number(count[1]) * ({ '': 1, K: 1e3, M: 1e6, G: 1e9 }[count[2].toUpperCase()]);
if (!Number.isSafeInteger(runs) || runs < 1) throw new Error('Run count is out of range.');

const out = resolve(root, 'tests/out/fuzz-jpeg');
const corpus = resolve(out, 'corpus');
const seeds = resolve(out, 'seeds');
const artifacts = resolve(out, 'artifacts');
rmSync(seeds, { recursive: true, force: true });
for (const path of [out, corpus, seeds, artifacts]) mkdirSync(path, { recursive: true });
for (const name of readdirSync(resolve(root, 'tests/fixtures')).sort()) {
  if (name.endsWith('.jpg')) copyFileSync(resolve(root, 'tests/fixtures', name), resolve(seeds, name));
}
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) console.error(result.error.message);
  if (result.status !== 0 || result.signal || result.error) process.exit(result.status || 1);
}
const binary = resolve(out, 'fuzz-jpeg');
run(clang, [
  '-std=c11', '-O1', '-g', '-fwrapv', '-fno-omit-frame-pointer',
  '-fsanitize=fuzzer,address,undefined', '-fno-sanitize-recover=all',
  '-Isrc', '-Ivendor/stb', 'tests/fuzz/jpeg.c', 'src/jpeg_stb.c', '-o', binary,
]);
run(binary, [
  corpus, seeds, `-runs=${runs}`, '-max_len=32768', '-timeout=10', '-rss_limit_mb=512',
  `-artifact_prefix=${artifacts}/`, '-print_final_stats=1', ...process.argv.slice(4),
]);
