/**
 * 회귀 테스트.
 *
 * 핵심은 마지막 블록이다 — 자곡동 271-4 에서 건폐율 20% 가 다시 나오면 실패한다.
 * 자연녹지 조례 20% 와 GB 기본 20% 가 우연히 같은 값이라, 숫자만 비교해서는
 * 이 버그를 잡을 수 없다. 그래서 값과 함께 track / 근거까지 검사한다.
 *
 * 실행: node --test lawkit/
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { resolve, gate, STATUS } from './resolver.js';

const here = dirname(fileURLToPath(import.meta.url));
const gbRule = JSON.parse(readFileSync(join(here, 'rules/gb-chwirak.json'), 'utf8'));
const rules = [gbRule];

/** 자곡동 271-4 */
const 대지 = {
  대지면적: 331,
  용도지역: '자연녹지지역',
  구역: ['개발제한구역', '취락지구'],
};

/* ---------------- gate ---------------- */

test('gate: 특별법 구역이 없으면 국토계획법 트랙', () => {
  const g = gate([], rules);
  assert.equal(g.track, '국토계획법');
  assert.equal(g.rule, null);
});

test('gate: 개발제한구역이면 특별법 트랙으로 넘어간다', () => {
  const g = gate(['개발제한구역', '취락지구'], rules);
  assert.equal(g.track, '특별법');
  assert.deepEqual(g.감지, ['개발제한구역']);
  assert.equal(g.rule.id, 'gb-chwirak');
});

test('gate: 구역은 걸렸는데 룰이 없으면 rule 은 null', () => {
  // 취락지구가 없으므로 gb-chwirak 의 적용조건을 만족하지 못한다
  const g = gate(['개발제한구역'], rules);
  assert.equal(g.track, '특별법');
  assert.equal(g.rule, null);
});

/* ---------------- NEEDS_REVIEW: 사고를 막는 분기 ---------------- */

test('룰이 없으면 숫자를 내지 않고 NEEDS_REVIEW 로 세운다', () => {
  const r = resolve({ ...대지, 구역: ['개발제한구역'], 용도: '단독주택' }, { rules });

  assert.equal(r.status, STATUS.NEEDS_REVIEW);
  assert.equal(r.건폐율, undefined, '확정값을 내보내면 안 된다');
  assert.equal(r.최대건축면적, undefined);
  assert.match(r.경고.join(' '), /용도지역 기준으로 대신 계산하지 마세요/);
});

test('공공주택지구 등 다른 특별법 구역도 동일하게 막힌다', () => {
  const r = resolve({ ...대지, 구역: ['공공주택지구'], 용도: '단독주택' }, { rules });
  assert.equal(r.status, STATUS.NEEDS_REVIEW);
  assert.equal(r.건폐율, undefined);
});

/* ---------------- INPUT_REQUIRED: 용도 없이 확정하지 않는다 ---------------- */

test('용도 미입력이면 단일 숫자 대신 분기표를 준다', () => {
  const r = resolve(대지, { rules });

  assert.equal(r.status, STATUS.INPUT_REQUIRED);
  assert.equal(r.건폐율, undefined);
  assert.equal(r.분기.length, 5);

  const 주택 = r.분기.find((b) => b.용도 === '단독주택' && b.자격 === '지정당시거주자');
  assert.equal(주택.건폐율, 60);
  assert.equal(주택.최대연면적, 300);

  const 그외 = r.분기.find((b) => b.용도 === '그외');
  assert.equal(그외.건폐율, 20);
});

/* ---------------- override: 특례가 이긴다 ---------------- */

test('주택 · 지정당시거주자 → 건폐율 60%, 연면적 300㎡', () => {
  const r = resolve({ ...대지, 용도: '단독주택', 자격: '지정당시거주자' }, { rules });

  assert.equal(r.status, STATUS.OK);
  assert.equal(r.track, '특별법');
  assert.equal(r.건폐율, 60);
  assert.equal(r.최대건축면적, 198.6);
  assert.equal(r.최대연면적, 300);
  assert.equal(r.층수, 3);
  assert.equal(r.지배제약, '연면적 캡', '용적률 300%(993㎡)가 아니라 캡이 지배한다');
});

test('주택 · 5년이상거주 → 연면적 232㎡', () => {
  const r = resolve({ ...대지, 용도: '단독주택', 자격: '5년이상거주' }, { rules });
  assert.equal(r.건폐율, 60);
  assert.equal(r.최대연면적, 232);
});

test('주택 · 토지요건만 → 연면적 200㎡', () => {
  const r = resolve({ ...대지, 용도: '단독주택', 자격: '토지요건만' }, { rules });
  assert.equal(r.최대연면적, 200);
});

test('근생은 자격이 파이프로 여러 개여도 매칭된다', () => {
  for (const 자격 of ['5년이상거주', '지정당시거주자']) {
    const r = resolve({ ...대지, 용도: '근린생활시설', 자격 }, { rules });
    assert.equal(r.status, STATUS.OK, 자격);
    assert.equal(r.건폐율, 60);
    assert.equal(r.최대연면적, 300);
  }
});

test('5년 거주자는 근생이 주택보다 68㎡ 크다 — 최대 면적이 목적이므로 중요', () => {
  const 주택 = resolve({ ...대지, 용도: '단독주택', 자격: '5년이상거주' }, { rules });
  const 근생 = resolve({ ...대지, 용도: '근린생활시설', 자격: '5년이상거주' }, { rules });
  assert.equal(근생.최대연면적 - 주택.최대연면적, 68);
});

test('그 외 용도는 GB 기본 20% 로 떨어진다', () => {
  const r = resolve({ ...대지, 용도: '창고시설', 자격: '지정당시거주자' }, { rules });
  assert.equal(r.건폐율, 20);
  assert.equal(r.최대건축면적, 66.2);
  assert.match(r.근거.join(' '), /취락지구 밖 개발제한구역 기준 준용/);
});

/* ---------------- cap: 일반 대지에서는 min 이 맞다 ---------------- */

test('구역이 없으면 조례가 법정상한을 깎는다 (cap)', () => {
  const r = resolve({ 대지면적: 331, 용도지역: '자연녹지지역', 구역: [], 시도: '서울특별시' }, { rules });

  assert.equal(r.status, STATUS.OK);
  assert.equal(r.track, '국토계획법');
  assert.equal(r.건폐율, 20);
  assert.equal(r.용적률, 50, '법정상한 100% 를 조례 50% 가 깎는다');
  assert.equal(r.최대연면적, 165.5);
});

test('미검수 시드표를 쓰면 경고가 붙는다', () => {
  const r = resolve({ 대지면적: 331, 용도지역: '자연녹지지역', 구역: [], 시도: '서울특별시' }, { rules });
  assert.match(r.경고.join(' '), /미검수/);
});

/* ---------------- 다른 지번으로 넘어갈 때 조용히 틀리는 자리 ---------------- */

test('지구단위계획구역이면 조례값을 내지 않는다 — 결정조서가 우선한다', () => {
  const r = resolve(
    { 대지면적: 300, 용도지역: '제2종일반주거지역', 구역: ['지구단위계획구역'], 시도: '서울특별시' },
    { rules },
  );

  assert.equal(r.status, STATUS.NEEDS_REVIEW);
  assert.equal(r.건폐율, undefined, '조례 60% 를 그대로 내보내면 안 된다');
  assert.match(r.확인대상.join(' '), /결정조서/);
});

test('서울 기준표를 다른 시·도 필지에 쓰지 않는다', () => {
  const r = resolve(
    { 대지면적: 300, 용도지역: '제2종일반주거지역', 구역: [], 시도: '경기도' },
    { rules },
  );

  assert.equal(r.status, STATUS.NEEDS_REVIEW);
  assert.equal(r.건폐율, undefined);
  assert.match(r.메시지, /서울특별시 조례/);
});

test('시·도를 안 주면 조례를 적용하지 않는다', () => {
  const r = resolve({ 대지면적: 300, 용도지역: '제2종일반주거지역', 구역: [] }, { rules });
  assert.equal(r.status, STATUS.NEEDS_REVIEW);
  assert.match(r.메시지, /미입력/);
});

test('시드표에 없는 용도지역은 막힌다', () => {
  const r = resolve(
    { 대지면적: 300, 용도지역: '일반상업지역', 구역: [], 시도: '서울특별시' },
    { rules },
  );
  assert.equal(r.status, STATUS.NEEDS_REVIEW);
  assert.equal(r.건폐율, undefined);
});

/* ---------------- 회귀: 20% 사고 ---------------- */

test('회귀 — 271-4 에서 건폐율 20% / 연면적 165.5㎡ 가 다시 나오면 실패', () => {
  const r = resolve({ ...대지, 용도: '단독주택', 자격: '지정당시거주자' }, { rules });

  assert.notEqual(r.건폐율, 20, 'v2 가 냈던 자연녹지 조례값');
  assert.notEqual(r.최대건축면적, 66.2);
  assert.notEqual(r.최대연면적, 165.5);

  // 값만 봐서는 부족하다. 자연녹지 20% 와 GB 기본 20% 가 같은 숫자라
  // 어느 트랙을 탔는지까지 확인해야 이 계열 버그가 잡힌다.
  assert.equal(r.track, '특별법');
  assert.match(r.근거.join(' '), /개발제한구역/);
  assert.match(r.근거.join(' '), /제26조/);
});

test('회귀 — 미검수 룰은 결과에 반드시 표시된다', () => {
  const r = resolve({ ...대지, 용도: '단독주택', 자격: '지정당시거주자' }, { rules });
  assert.match(r.경고.join(' '), /미검수/);
});

test('회귀 — 지하층 미확정 사실이 결과에 실려 나간다', () => {
  const r = resolve({ ...대지, 용도: '근린생활시설', 자격: '지정당시거주자' }, { rules });
  const 지하 = r.연면적산입.포함.find((x) => x.항목 === '지하층');
  assert.equal(지하.확실성, '미확정');
});

/* ---------------- 근거 ---------------- */

test('모든 확정 결과는 근거를 달고 나온다', () => {
  const cases = [
    { ...대지, 용도: '단독주택', 자격: '지정당시거주자' },
    { 대지면적: 331, 용도지역: '자연녹지지역', 구역: [], 시도: '서울특별시' },
  ];
  for (const c of cases) {
    const r = resolve(c, { rules });
    assert.equal(r.status, STATUS.OK);
    assert.ok(r.근거.length > 0, JSON.stringify(c));
  }
});
