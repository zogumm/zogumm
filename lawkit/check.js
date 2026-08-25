#!/usr/bin/env node
/**
 * 법규검토 CLI.
 *
 *   node check.js --대지면적 331 --용도지역 자연녹지지역 \
 *                 --구역 개발제한구역,취락지구 \
 *                 --용도 근린생활시설 --자격 지정당시거주자 --시도 서울특별시
 *
 * 용도를 빼면 트랙별 분기표가 나온다. 이 대지에서는 용도를 모르면
 * 건폐율이 확정되지 않기 때문이다.
 */

import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { resolve as 판정, STATUS } from './resolver.js';

const here = dirname(fileURLToPath(import.meta.url));

function loadRules() {
  const dir = join(here, 'rules');
  return readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')));
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i]?.replace(/^--/, '');
    const v = argv[i + 1];
    if (!k || v === undefined) continue;
    out[k] = v;
  }
  return out;
}

const HELP = `
법규검토 — 대지 조건으로 최대 건축 규모를 판정한다

  --대지면적   ㎡ (필수)
  --용도지역   예: 자연녹지지역 (필수)
  --시도       예: 서울특별시   (조례 적용에 필요)
  --구역       쉼표로 구분. 예: 개발제한구역,취락지구
  --용도       예: 단독주택 / 근린생활시설
  --자격       토지요건만 / 5년이상거주 / 지정당시거주자

예)
  node check.js --대지면적 331 --용도지역 자연녹지지역 --시도 서울특별시 \\
                --구역 개발제한구역,취락지구 --용도 근린생활시설 --자격 지정당시거주자
`;

const 줄 = (n = 62) => '─'.repeat(n);
const 항목 = (k, v) => console.log(`  ${k.padEnd(12)} ${v}`);

function report(r, 대지) {
  console.log('');
  console.log(줄());
  console.log(`  ${대지.용도지역}${대지.구역?.length ? ' · ' + 대지.구역.join(' · ') : ''}  ${대지.대지면적}㎡`);
  console.log(줄());

  if (r.status === STATUS.NEEDS_REVIEW) {
    console.log('\n  ⚠  자동 산정 보류\n');
    console.log(`  ${r.메시지}`);
    if (r.확인대상?.length) {
      console.log('\n  대신 확인할 것');
      r.확인대상.forEach((x) => console.log(`    · ${x}`));
    }
  } else if (r.status === STATUS.INPUT_REQUIRED) {
    console.log('\n  ?  용도에 따라 갈림 — 확정하려면 --용도 를 주세요\n');
    console.log('  용도'.padEnd(22) + '자격'.padEnd(20) + '건폐율'.padEnd(10) + '연면적');
    console.log('  ' + 줄(58));
    for (const b of r.분기) {
      console.log(
        '  ' + String(b.용도).padEnd(20) +
        String(b.자격).padEnd(20) +
        `${b.건폐율}%`.padEnd(10) +
        (b.최대연면적 != null ? `${b.최대연면적}㎡` : '—'),
      );
    }
  } else {
    console.log('');
    if (r.적용트랙) 항목('적용', `${r.적용트랙.용도} · ${r.적용트랙.자격}`);
    항목('건폐율', `${r.건폐율}%`);
    항목('건축면적', `${r.최대건축면적}㎡`);
    if (r.최대연면적 != null) {
      항목('연면적', `${r.최대연면적}㎡  (${r.지배제약} 지배)`);
    }
    if (r.층수) 항목('층수', `${r.층수}층 이하`);

    const 제외 = r.연면적산입?.제외 ?? [];
    if (제외.length) {
      console.log('\n  연면적 밖 (면적 안 먹음)');
      제외.forEach((x) => console.log(`    + ${x.항목}${x.조건 ? ` — ${x.조건}` : ''}`));
    }
    const 포함 = (r.연면적산입?.포함 ?? []).filter((x) => x.확실성 === '미확정');
    if (포함.length) {
      console.log('\n  판단 필요');
      포함.forEach((x) => console.log(`    ? ${x.항목} — ${x.확인방법 ?? ''}`));
    }
  }

  if (r.근거?.length) {
    console.log('\n  근거');
    r.근거.forEach((g) => console.log(`    · ${g}`));
  }
  if (r.경고?.length) {
    console.log('\n  경고');
    r.경고.forEach((w) => console.log(`    ! ${w}`));
  }
  console.log('');
}

const a = parseArgs(process.argv.slice(2));

if (!a.대지면적 || !a.용도지역) {
  console.log(HELP);
  process.exit(a.대지면적 || a.용도지역 ? 1 : 0);
}

const 대지 = {
  대지면적: Number(a.대지면적),
  용도지역: a.용도지역,
  시도: a.시도 ?? null,
  구역: a.구역 ? a.구역.split(',').map((s) => s.trim()).filter(Boolean) : [],
  용도: a.용도 ?? null,
  자격: a.자격 ?? null,
};

const r = 판정(대지, { rules: loadRules() });
report(r, 대지);

// 보류는 실패가 아니다. 확정만 0 으로 끝낸다.
process.exit(r.status === STATUS.OK ? 0 : 2);
