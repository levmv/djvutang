// Own short essay and geometric illustration. Only rendered glyphs are stored,
// no font files. Regeneration needs Chromium and DjVuLibre; normal tests do not.
// Usage: node examples/reader/generate-sample.mjs /path/to/playwright/index.mjs
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const { chromium } = await import(pathToFileURL(resolve(process.argv[2])));
const temp = await mkdtemp(join(tmpdir(), 'djvu-reader-fixture-'));
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  const documents = await page.evaluate(() => {
    const result = [];
    for (let number = 1; number <= 2; number++) {
      const canvas = document.createElement('canvas'); canvas.width = 1200; canvas.height = 1600;
      const ctx = canvas.getContext('2d'); ctx.fillStyle = 'white'; ctx.fillRect(0, 0, 1200, 1600); ctx.fillStyle = 'black';
      const lines = [];
      function line(text, x, y, size = 29, weight = 400) {
        ctx.font = `${weight} ${size}px sans-serif`;
        ctx.textBaseline = 'top';
        const words = [];
        for (const word of text.split(' ')) {
          const width = ctx.measureText(word).width;
          ctx.fillText(word, x, y);
          words.push({ text: word, x: Math.floor(x), y, width: Math.ceil(width), height: Math.ceil(size * 1.2) });
          x += ctx.measureText(word + ' ').width;
        }
        lines.push(words);
      }
      line('ПОЛЕВЫЕ ЗАМЕТКИ', 96, 86, 20, 600);
      line(`МАРШРУТ / 0${number}`, 906, 86, 17);
      ctx.fillRect(96, 140, 1008, 2);
      if (number === 1) {
        line('Заметить привычное', 96, 210, 66, 600);
        line('Короткая прогулка без спешки', 99, 310, 29);
        // Own schematic map, with paths, trees, a river and an open square.
        ctx.lineWidth = 3; ctx.strokeRect(96, 410, 1008, 380);
        ctx.lineWidth = 2;
        for (let i = 0; i < 4; i++) {
          ctx.beginPath(); ctx.moveTo(740 + i * 16, 412); ctx.bezierCurveTo(870 + i * 16, 520, 620 + i * 16, 680, 770 + i * 16, 788); ctx.stroke();
        }
        ctx.setLineDash([12, 10]); ctx.lineWidth = 4; ctx.beginPath();
        ctx.moveTo(172, 696); ctx.lineTo(316, 696); ctx.lineTo(316, 520); ctx.lineTo(574, 520); ctx.lineTo(574, 700); ctx.lineTo(966, 700); ctx.stroke(); ctx.setLineDash([]);
        for (const [x, y] of [[175, 482], [236, 534], [944, 486], [998, 556], [934, 587]]) {
          ctx.beginPath(); ctx.arc(x, y, 20, 0, 2 * Math.PI); ctx.stroke(); ctx.beginPath(); ctx.moveTo(x, y - 12); ctx.lineTo(x, y + 12); ctx.stroke();
        }
        for (const [x, y, label] of [[316, 696, '1'], [574, 520, '2'], [966, 700, '3']]) {
          ctx.fillStyle = 'white'; ctx.beginPath(); ctx.arc(x, y, 22, 0, 2 * Math.PI); ctx.fill(); ctx.stroke(); ctx.fillStyle = 'black'; line(label, x - 7, y - 14, 22, 600);
        }
        line('Три остановки на знакомом пути', 96, 819, 20);
        line('Начните с ближайшего перекрёстка. На этот раз', 96, 905);
        line('выберите улицу, по которой обычно проходите', 96, 950);
        line('не оглядываясь. Здесь не нужен длинный маршрут:', 96, 995);
        line('достаточно двадцати минут и одного блокнота.', 96, 1040);
        line('01 / Сменить темп', 96, 1150, 32, 600);
        line('Остановитесь у дерева или старой вывески.', 96, 1214);
        line('Запишите одну деталь: цвет, звук, форму тени.', 96, 1259);
        line('Короткая запись сохранит больше, чем общий', 96, 1304);
        line('вывод о том, каким был этот день.', 96, 1349);
      } else {
        line('Сохранить наблюдение', 96, 210, 62, 600);
        line('02 / Посмотреть ещё раз', 96, 360, 32, 600);
        line('На площади найдите удобное место и посидите', 96, 430);
        line('несколько минут. Что меняется, пока вы смотрите?', 96, 475);
        line('Кто-то открывает окно. Велосипедист объезжает', 96, 520);
        line('лужу. Облако закрывает солнечный фасад.', 96, 565);
        line('03 / Оставить место', 96, 690, 32, 600);
        line('Не старайтесь записать всё. Оставьте на странице', 96, 760);
        line('немного свободного пространства для следующей', 96, 805);
        line('прогулки. Через неделю вернитесь к той же точке', 96, 850);
        line('и сравните две заметки.', 96, 895);
        ctx.lineWidth = 2; ctx.strokeRect(96, 1030, 1008, 300);
        line('ДАТА', 124, 1060, 18, 600); line('МЕСТО', 635, 1060, 18, 600);
        for (const y of [1145, 1210, 1275]) ctx.fillRect(124, y, 950, 1);
        line('Один маршрут. Каждый раз — новая деталь.', 96, 1385, 24);
      }
      ctx.fillRect(96, 1480, 1008, 1);
      line('ЗАМЕТКИ О ПОВСЕДНЕВНОМ', 96, 1510, 17);
      line(String(number), 1080, 1507, 22);
      const pixels = ctx.getImageData(0, 0, 1200, 1600).data;
      const bitmap = new Uint8Array(150 * 1600);
      for (let y = 0; y < 1600; y++) for (let x = 0; x < 1200; x++)
        if (pixels[(y * 1200 + x) * 4] < 160) bitmap[y * 150 + (x >> 3)] |= 128 >> (x % 8);
      result.push({ bitmap: Array.from(bitmap), lines });
    }
    return result;
  });
  for (let i = 0; i < documents.length; i++) {
    const { bitmap, lines } = documents[i];
    const pbm = join(temp, `${i}.pbm`), djvu = join(temp, `${i}.djvu`), txt = join(temp, `${i}.txt`);
    await writeFile(pbm, Buffer.concat([Buffer.from('P4\n1200 1600\n'), Buffer.from(bitmap)]));
    const bounds = z => `${z.x} ${1600 - z.y - z.height} ${z.x + z.width} ${1600 - z.y}`;
    const tree = lines.map(words => {
      const x = Math.min(...words.map(w => w.x)), y = Math.min(...words.map(w => w.y));
      const width = Math.max(...words.map(w => w.x + w.width)) - x, height = Math.max(...words.map(w => w.y + w.height)) - y;
      return `(line ${bounds({ x, y, width, height })}\n${words.map(w => `(word ${bounds(w)} ${JSON.stringify(w.text)})`).join('\n')})`;
    });
    await writeFile(txt, `(page 0 0 1200 1600\n${tree.join('\n')})\n`);
    execFileSync('cjb2', [pbm, djvu]);
    execFileSync('djvused', ['-s', djvu, '-e', `select 1; set-txt ${txt}`]);
  }
  execFileSync('djvm', ['-c', join(temp, 'sample.djvu'), join(temp, '0.djvu'), join(temp, '1.djvu')]);
  const bytes = await readFile(join(temp, 'sample.djvu'));
  await writeFile(resolve(import.meta.dirname, '../../tests/fixtures/reader-sample.djvu'), bytes);
  console.log(`Own two-page sample: ${bytes.length} bytes`);
} finally {
  await browser.close();
  await rm(temp, { recursive: true, force: true });
}
