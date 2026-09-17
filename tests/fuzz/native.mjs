// Zig 0.16 can report a fuzz-test crash and still exit with status 0. Preserve
// its diagnostics, reject reported failures, and require actual fuzz executions.
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';

const child = spawn(process.argv[2] ?? 'zig', [
  'build', 'test', `--fuzz=${process.argv[3] ?? '100K'}`, '--color', 'off', ...process.argv.slice(4),
], { cwd: resolve(import.meta.dirname, '../..'), stdio: ['ignore', 'pipe', 'pipe'] });
let failed = false, ran = false;
const pending = new Map();
function inspect(line) {
  if (/^error:|^thread .*panic:/.test(line)) failed = true;
  const runs = /^Runs: (\d+) -> (\d+)/.exec(line);
  if (runs && BigInt(runs[2]) > BigInt(runs[1])) ran = true;
}
for (const [name, stream] of [['stdout', child.stdout], ['stderr', child.stderr]]) {
  pending.set(name, '');
  stream.setEncoding('utf8');
  stream.on('data', (text) => {
    process[name].write(text);
    const lines = (pending.get(name) + text).split('\n');
    pending.set(name, lines.pop());
    for (const line of lines) inspect(line);
  });
}
child.on('error', (error) => {
  failed = true;
  console.error(error.message);
});
child.on('close', (code, signal) => {
  for (const line of pending.values()) inspect(line);
  if (code !== 0 || signal || failed || !ran) {
    console.error('Native fuzzing failed or did not execute; see diagnostics above.');
    process.exitCode = 1;
  }
});
