import React, { useMemo } from 'react';
import { useHostTheme } from 'cursor/canvas';

// ─── Types ────────────────────────────────────────────────────────────────────

type Step =
  | { k: 'section'; label: string }
  | { k: 'msg';     from: number; to: number; label: string; dashed?: boolean }
  | { k: 'self';    actor: number; label: string }
  | { k: 'hsm';    title: string; objs: string[] }
  | { k: 'gap' };

// ─── Actors ───────────────────────────────────────────────────────────────────

const ACTORS = ['setup-softhsm.sh', 'OpenSSL', 'SoftHSM', 'Spring Boot'];
const ASUB   = ['(script)',          '',        'pkcs11-tool', '/ Tomcat'];
const AX     = [100, 300, 530, 780]; // x-centres for lifelines

// ─── Diagram steps ────────────────────────────────────────────────────────────

const STEPS: Step[] = [
  // ── First run ──────────────────────────────────────────────────────────────
  { k: 'section', label: '① FIRST RUN — no existing canonical objects; application not yet started' },
  { k: 'msg',  from: 0, to: 2, label: 'softhsm2-util --init-token --label springboot' },
  { k: 'hsm',  title: 'After token init', objs: [
    '[empty — token created, no PKCS#11 objects yet]',
  ]},
  { k: 'msg',  from: 0, to: 1, label: 'genrsa 2048  +  req -x509  (PEM → DER conversion)' },
  { k: 'msg',  from: 0, to: 2, label: 'write-object privkey  label=mykey  ID=01' },
  { k: 'msg',  from: 0, to: 2, label: 'write-object cert     label=mykey  ID=01' },
  { k: 'hsm',  title: 'First-run import complete', objs: [
    'privkey  mykey  (ID=01)',
    'cert     mykey  (ID=01)',
  ]},
  { k: 'gap' },

  // ── Rotation ──────────────────────────────────────────────────────────────
  { k: 'section', label: '② ROTATION — application running; TLS live on canonical mykey / ID=01' },
  { k: 'msg',  from: 0, to: 1, label: 'genrsa 2048  +  req -x509  (new key + cert → DER)' },
  { k: 'msg',  from: 0, to: 2, label: 'delete-object privkey+cert  ID=02  (cleanup leftover staging)' },
  { k: 'msg',  from: 0, to: 2, label: 'write-object privkey  label=mykey-staging  ID=02' },
  { k: 'msg',  from: 0, to: 2, label: 'write-object cert     label=mykey-staging  ID=02' },
  { k: 'hsm',  title: 'After staging import — canonical still active in Tomcat', objs: [
    'privkey  mykey          (ID=01)  ← canonical; Tomcat active; HTTPS live',
    'cert     mykey          (ID=01)  ← canonical; Tomcat active; HTTPS live',
    'privkey  mykey-staging  (ID=02)  ← new material; not yet active',
    'cert     mykey-staging  (ID=02)  ← new material; not yet active',
  ]},
  { k: 'gap' },

  // ── Reload #1: switch Tomcat to staging ────────────────────────────────────
  { k: 'msg',  from: 0, to: 3, label: 'POST /ssl/reload?alias=mykey-staging' },
  { k: 'self', actor: 3, label: 'loadKeyStore(provider)' },
  { k: 'self', actor: 3, label: 'buildBundle("mykey-staging") + updateBundle()' },
  { k: 'msg',  from: 3, to: 0, label: 'HTTP 200 — Tomcat live on mykey-staging (ID=02)', dashed: true },
  { k: 'gap' },

  // ── Promote staging → canonical ────────────────────────────────────────────
  { k: 'msg',  from: 0, to: 2, label: 'delete-object privkey+cert  ID=01  (remove old canonical)' },
  { k: 'hsm',  title: 'Old canonical deleted; staging still serving Tomcat', objs: [
    'privkey  mykey-staging  (ID=02)  ← Tomcat active',
    'cert     mykey-staging  (ID=02)  ← Tomcat active',
  ]},
  { k: 'msg',  from: 0, to: 2, label: 'write-object privkey  label=mykey  ID=01  (new cert)' },
  { k: 'msg',  from: 0, to: 2, label: 'write-object cert     label=mykey  ID=01' },
  { k: 'hsm',  title: 'New canonical ready; staging still serving Tomcat (zero-downtime gap)', objs: [
    'privkey  mykey          (ID=01)  ← new canonical (ready)',
    'cert     mykey          (ID=01)  ← new canonical (ready)',
    'privkey  mykey-staging  (ID=02)  ← Tomcat still active',
    'cert     mykey-staging  (ID=02)  ← Tomcat still active',
  ]},
  { k: 'gap' },

  // ── Reload #2: switch Tomcat to new canonical ──────────────────────────────
  { k: 'msg',  from: 0, to: 3, label: 'POST /ssl/reload  (no alias → canonical "mykey")' },
  { k: 'self', actor: 3, label: 'loadKeyStore(provider)' },
  { k: 'self', actor: 3, label: 'buildBundle("mykey") + updateBundle()' },
  { k: 'msg',  from: 3, to: 0, label: 'HTTP 200 — Tomcat live on mykey (ID=01)', dashed: true },
  { k: 'gap' },

  // ── Cleanup staging ────────────────────────────────────────────────────────
  { k: 'msg',  from: 0, to: 2, label: 'delete-object privkey+cert  ID=02  (remove staging)' },
  { k: 'hsm',  title: 'Rotation complete — zero downtime achieved', objs: [
    'privkey  mykey  (ID=01)  ✓  active',
    'cert     mykey  (ID=01)  ✓  active',
  ]},
];

// ─── Layout helpers ───────────────────────────────────────────────────────────

const SVG_W  = 960;
const BOX_W  = 130;
const BOX_H  = 44;
const LL_Y0  = BOX_H + 8; // lifeline starts below actor boxes

function stepH(s: Step): number {
  if (s.k === 'section') return 50;
  if (s.k === 'msg')     return 42;
  if (s.k === 'self')    return 36;
  if (s.k === 'gap')     return 16;
  // hsm: top-pad(14) + title(20) + rows(n*20) + bot-pad(12)
  return 46 + (s as { objs: string[] }).objs.length * 20;
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function SoftHSMSequenceDiagram() {
  const t = useHostTheme();

  const layout = useMemo(() => {
    let y = LL_Y0;
    return STEPS.map(s => { const ry = y; y += stepH(s); return { s, y: ry }; });
  }, []);

  const totalH = useMemo(
    () => layout.reduce((acc, { s, y }) => Math.max(acc, y + stepH(s)), LL_Y0),
    [layout],
  );
  const svgH = totalH + BOX_H + 24;

  // Theme aliases
  const bg      = t.bg.editor;
  const fg      = t.text.primary;
  const fg2     = t.text.secondary;
  const fg3     = t.text.tertiary;
  const accent  = t.accent.primary;
  const stroke  = t.stroke.primary;
  const stroke2 = t.stroke.secondary;
  const fill2   = t.fill.secondary;
  const fill3   = t.fill.tertiary;

  // ── Sub-components ─────────────────────────────────────────────────────────

  function ActorBox({ i, y }: { i: number; y: number }) {
    return (
      <>
        <rect x={AX[i] - BOX_W / 2} y={y} width={BOX_W} height={BOX_H} rx={4}
          fill={fill2} stroke={stroke} strokeWidth={1} />
        <text x={AX[i]} y={y + 17} textAnchor="middle"
          fill={fg} fontSize={11} fontWeight={600}>
          {ACTORS[i]}
        </text>
        <text x={AX[i]} y={y + 32} textAnchor="middle" fill={fg3} fontSize={9}>
          {ASUB[i]}
        </text>
      </>
    );
  }

  function Arrow({ x1, x2, y, dashed }: { x1: number; x2: number; y: number; dashed?: boolean }) {
    const right = x2 > x1;
    const aH    = 7;
    const pts   = right
      ? `${x2},${y} ${x2 - aH},${y - 4} ${x2 - aH},${y + 4}`
      : `${x2},${y} ${x2 + aH},${y - 4} ${x2 + aH},${y + 4}`;
    const lineEnd = right ? x2 - aH + 1 : x2 + aH - 1;
    const col = dashed ? fg3 : stroke;
    return (
      <>
        <line x1={x1} y1={y} x2={lineEnd} y2={y}
          stroke={col} strokeWidth={1.5}
          strokeDasharray={dashed ? '5 3' : undefined} />
        <polygon points={pts} fill={col} />
      </>
    );
  }

  function renderStep({ s, y }: { s: Step; y: number }, idx: number) {
    if (s.k === 'gap') return null;

    if (s.k === 'section') {
      return (
        <g key={idx}>
          <rect x={6} y={y + 8} width={SVG_W - 12} height={34} rx={3}
            fill={fill2} stroke={stroke2} strokeWidth={1} />
          <line x1={6} y1={y + 8} x2={6 + 3} y2={y + 8}
            stroke={accent} strokeWidth={3} strokeLinecap="round" />
          <text x={20} y={y + 30} fill={accent} fontSize={10} fontWeight={700}>
            {s.label}
          </text>
        </g>
      );
    }

    if (s.k === 'msg') {
      const x1  = AX[s.from];
      const x2  = AX[s.to];
      const ay  = y + 30;
      const mx  = (x1 + x2) / 2;
      const col = s.dashed ? fg2 : fg;
      return (
        <g key={idx}>
          <text x={mx} y={ay - 8} textAnchor="middle" fill={col} fontSize={9.5}>
            {s.label}
          </text>
          <Arrow x1={x1} x2={x2} y={ay} dashed={s.dashed} />
        </g>
      );
    }

    if (s.k === 'self') {
      const cx    = AX[s.actor];
      const lw    = 38;
      const top   = y + 4;
      const bot   = y + stepH(s) - 6;
      // Rightmost actor loops left; others loop right
      const goLeft = s.actor === AX.length - 1;
      const ex    = goLeft ? cx - lw : cx + lw;
      const pathD = `M ${cx} ${top} H ${ex} V ${bot} H ${cx}`;
      const apts  = goLeft
        ? `${cx},${bot} ${cx + 8},${bot - 4} ${cx + 8},${bot + 4}`
        : `${cx},${bot} ${cx - 8},${bot - 4} ${cx - 8},${bot + 4}`;
      const labelX = goLeft ? ex - 6 : ex + 6;
      const anchor = goLeft ? 'end' : 'start';
      return (
        <g key={idx}>
          <path d={pathD} fill="none" stroke={stroke} strokeWidth={1} />
          <polygon points={apts} fill={stroke} />
          <text x={labelX} y={(top + bot) / 2 + 4}
            textAnchor={anchor as 'end' | 'start'}
            fill={fg2} fontSize={9}>
            {s.label}
          </text>
        </g>
      );
    }

    if (s.k === 'hsm') {
      const h  = stepH(s) - 8;
      const bx = 8;
      const bw = SVG_W - 16;
      return (
        <g key={idx}>
          <rect x={bx} y={y + 4} width={bw} height={h} rx={3}
            fill={fill3} stroke={stroke2} strokeWidth={1} strokeDasharray="4 2" />
          {/* HSM label pill */}
          <rect x={bx + 8} y={y + 10} width={36} height={14} rx={3}
            fill={accent} opacity={0.15} />
          <text x={bx + 26} y={y + 21} textAnchor="middle"
            fill={accent} fontSize={8} fontWeight={700}>
            HSM
          </text>
          <text x={bx + 52} y={y + 21} fill={accent} fontSize={9.5} fontWeight={700}>
            {s.title}
          </text>
          {s.objs.map((obj, oi) => (
            <text key={oi} x={bx + 18} y={y + 38 + oi * 20}
              fill={fg2} fontSize={9}
              fontFamily="'Courier New', Courier, monospace">
              {obj}
            </text>
          ))}
        </g>
      );
    }

    return null;
  }

  return (
    <div style={{ background: bg, padding: '16px 20px', minHeight: '100vh' }}>
      {/* Header */}
      <div style={{
        display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 4,
        borderBottom: `1px solid ${stroke2}`, paddingBottom: 10,
      }}>
        <span style={{ color: fg, fontSize: 15, fontWeight: 700 }}>
          SoftHSM2 Sequence Diagram
        </span>
        <span style={{ color: fg3, fontSize: 10 }}>
          setup-softhsm.sh — Initialise → First-run import → Certificate rotation → Reload
        </span>
      </div>

      {/* Legend */}
      <div style={{
        display: 'flex', gap: 20, marginBottom: 12, marginTop: 10,
        flexWrap: 'wrap',
      }}>
        {[
          { label: 'Call', style: { borderBottom: `2px solid ${stroke}`, width: 28, display: 'inline-block' } },
          { label: 'Return (HTTP)', style: { borderBottom: `2px dashed ${fg3}`, width: 28, display: 'inline-block' } },
          { label: 'Self-call', style: { border: `1px solid ${stroke}`, borderRight: 'none', width: 12, height: 10, display: 'inline-block' } },
          { label: 'HSM State', style: { border: `1px dashed ${stroke2}`, background: fill3, width: 28, height: 10, display: 'inline-block', borderRadius: 2 } },
        ].map(({ label, style }) => (
          <div key={label} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={style as React.CSSProperties} />
            <span style={{ color: fg3, fontSize: 10 }}>{label}</span>
          </div>
        ))}
      </div>

      {/* Diagram */}
      <div style={{ overflowX: 'auto' }}>
        <svg
          width={SVG_W}
          height={svgH}
          style={{ display: 'block', fontFamily: 'system-ui, -apple-system, sans-serif' }}
        >
          {/* Lifelines */}
          {AX.map((ax, i) => (
            <line key={i}
              x1={ax} y1={LL_Y0} x2={ax} y2={totalH}
              stroke={stroke2} strokeWidth={1} strokeDasharray="4 3" />
          ))}

          {/* Actor boxes — top */}
          {ACTORS.map((_, i) => <ActorBox key={i} i={i} y={0} />)}

          {/* Steps */}
          {layout.map((item, idx) => renderStep(item, idx))}

          {/* Actor boxes — bottom */}
          {ACTORS.map((_, i) => <ActorBox key={`b${i}`} i={i} y={totalH} />)}
        </svg>
      </div>
    </div>
  );
}
