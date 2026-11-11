#!/usr/bin/env node
// Merges today's new Strava activities into data/activities.json — the
// snapshot the Run Coach app reads (github.com/ogingell/run-coach-app).
//
//   node bin/publish-activities.mjs <new.json>
//
// <new.json> is an array of activities in the app's compact shape:
//   { "id": "20938198983", "name": "DR Track", "desc": "5km WU…",   (desc optional)
//     "sport": "Run" | "Ride" | "Swim" | …, "start": "2026-11-10T18:40:40" (LOCAL time),
//     "km": 16.16, "moving": 4690, "elapsed": 6438, "elev": 138,
//     "effort": 46, "cadence": 170 (steps/min, i.e. Strava's per-leg value x2),
//     "kudos": 6, "wx": { "c": "Rain", "t": 10 },
//     "splits": [ { "km": 1, "sec": 309, "hr": 141 }, … ] }          (optional, long runs)
//
// Merge is by id, so re-sending an activity is harmless and edits win.
// `splits`, when present, go to data/longruns.json instead. No GPS, ever.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ACTS = path.join(ROOT, 'data', 'activities.json')
const LONG = path.join(ROOT, 'data', 'longruns.json')
const src = process.argv[2]
if (!src) { console.error('usage: publish-activities.mjs <new.json>'); process.exit(1) }

const load = (f, fallback) => (fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : fallback)
const incoming = JSON.parse(fs.readFileSync(src, 'utf8'))
if (!Array.isArray(incoming)) { console.error('expected a JSON array of activities'); process.exit(1) }

const snap = load(ACTS, { activities: [] })
const longruns = load(LONG, {})
const byId = new Map(snap.activities.map((a) => [String(a.id), a]))
const FORBIDDEN = ['polyline', 'map', 'location', 'latlng', 'start_latlng', 'end_latlng']
let added = 0, updated = 0
const bad = []

for (const raw of incoming) {
  const id = String(raw?.id ?? '')
  const ok = /^\d+$/.test(id) && typeof raw.name === 'string' && typeof raw.sport === 'string'
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(raw.start ?? '')
    && Number.isFinite(raw.km) && raw.km >= 0 && raw.km < 400
    && Number.isFinite(raw.moving) && raw.moving > 0
  if (!ok) { bad.push(id || JSON.stringify(raw).slice(0, 60)); continue }
  const { splits, ...a } = raw
  for (const k of FORBIDDEN) delete a[k]
  a.id = id
  a.km = Math.round(a.km * 100) / 100
  a.elapsed ??= a.moving
  a.elev = Math.round(a.elev ?? 0)
  a.kudos ??= 0
  byId.has(id) ? updated++ : added++
  byId.set(id, { ...byId.get(id), ...a })
  if (Array.isArray(splits) && splits.length) {
    const clean = splits.filter((s) => Number.isFinite(s.km) && Number.isFinite(s.sec) && s.sec > 120 && s.sec < 900)
      .map((s) => ({ km: s.km, sec: Math.round(s.sec), ...(s.hr ? { hr: Math.round(s.hr) } : {}), ...(s.cad ? { cad: Math.round(s.cad) } : {}) }))
    const hr = clean.map((s) => s.hr).filter(Boolean)
    // Never let a thinner set of splits replace a fuller one
    if (clean.length && clean.length >= (longruns[id]?.splits?.length ?? 0)) longruns[id] = { splits: clean, ...(hr.length ? { hrAvg: Math.round(hr.reduce((x, y) => x + y, 0) / hr.length), hrMax: Math.max(...hr) } : {}) }
  }
}

const activities = [...byId.values()].sort((a, b) => a.start.localeCompare(b.start))
fs.mkdirSync(path.dirname(ACTS), { recursive: true })
fs.writeFileSync(ACTS, JSON.stringify({ generatedAt: new Date().toISOString(), latest: activities.at(-1)?.start ?? null, activities }))
fs.writeFileSync(LONG, JSON.stringify(longruns))
console.log(`activities: +${added} new, ${updated} updated, ${activities.length} total, latest ${activities.at(-1)?.start}`)
if (bad.length) { console.error(`skipped ${bad.length} invalid: ${bad.join(', ')}`); process.exit(2) }
