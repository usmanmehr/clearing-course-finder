// UK Clearing Advisor - frontend logic (vanilla JS, no build step).
// Calls the API through the same CloudFront domain under /api/*.
//
// Content Security Policy note: this file is the ONLY place JavaScript lives.
// There are no inline <script> blocks, no inline event handlers (onclick=...)
// and no external script or font sources anywhere in the site, so a strict
// "script-src 'self'" policy with no 'unsafe-inline' is honoured.
'use strict';

const API = '/api';
const MAX_ALEVELS = 4;
const SEARCH_TIMEOUT_MS = 12000;
const PAGE = 10;

// Qualification types and their grade options. Values verified against
// Pearson's official BTEC/A-level UCAS Tariff table (qualifications.pearson.com)
// and cross-checked against ukcalculator.com - see lambda/shared/grading.mjs
// for the full verification note (this list only needs the grade labels,
// not the point values themselves - those are looked up server-side).
// Order matters: this is also the order shown in the "Qualification" dropdown.
const QUALIFICATION_TYPES = {
  alevel: { label: 'A-level', grades: ['A*', 'A', 'B', 'C', 'D', 'E'] },
  btecExtendedDiploma: {
    label: 'BTEC Extended Diploma (= 3 A-levels)',
    grades: ['D*D*D*', 'D*D*D', 'D*DD', 'DDD', 'DDM', 'DMM', 'MMM', 'MMP', 'MPP', 'PPP'],
  },
  btecDiploma: {
    label: 'BTEC Diploma (= 2 A-levels)',
    grades: ['D*D*', 'D*D', 'DD', 'DM', 'MM', 'MP', 'PP'],
  },
  btecExtendedCertificate: {
    label: 'BTEC Extended Certificate (= 1 A-level)',
    grades: ['D*', 'D', 'M', 'P'],
  },
};

// A-level-equivalent "slots" a qualification counts as - mirrors
// totalQualificationSlots() in lambda/shared/grading.mjs so the submit
// button's enabled state matches what the backend will actually accept
// (e.g. a single BTEC Diploma is 2 slots and is enough on its own, even
// though it's only 1 row).
const QUALIFICATION_SLOTS = { alevel: 1, btecExtendedDiploma: 3, btecDiploma: 2, btecExtendedCertificate: 1 };

// Only these status colours are ever emitted as CSS class names on a badge.
// Whitelisting means a malformed or hostile colour value from the API can
// never inject arbitrary text into the class attribute.
const BADGE_COLOURS = { Green: 'Green', Amber: 'Amber', Red: 'Red' };

let lastResults = [];
let shown = 0;
// The server-resolved course subject for the current results (e.g. "Economics"),
// or null when the student left "what do you want to study?" blank. Used to
// filter each university's live Clearing course list to matching courses.
let searchedSubject = null;
let subjectNames = []; // full subject list, loaded once, used for "did you mean"

const el = (id) => document.getElementById(id);
const fmtGBP = (n) => '\u00a3' + Number(n).toLocaleString('en-GB');

// ---- Security helpers -------------------------------------------------------
// Every value that comes from the API or the user and is placed into markup via
// innerHTML / insertAdjacentHTML MUST pass through escapeHtml first. This closes
// the 2026 XSS gap where raw API strings were interpolated directly.
function escapeHtml(value) {
  if (value == null) return '';
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// A clearing page may arrive as a bare host ("bath.ac.uk") or with a scheme.
// We always upgrade to https and reject anything that is not an https URL,
// so a javascript: or data: payload can never end up in an href.
function safeClearingUrl(value) {
  if (!value) return null;
  const host = String(value).trim().replace(/^https?:\/\//i, '');
  if (!host) return null;
  try {
    const parsed = new URL(`https://${host}`);
    return parsed.protocol === 'https:' ? parsed.href : null;
  } catch {
    return null;
  }
}

// Source links arrive as complete URLs. Require an https scheme outright -
// reject http:, javascript:, data: and anything unparseable.
function safeHttpsUrl(value) {
  if (!value) return null;
  try {
    const parsed = new URL(String(value).trim());
    return parsed.protocol === 'https:' ? parsed.href : null;
  } catch {
    return null;
  }
}

// Short relative-time string ("3 min ago", "yesterday") - used for both the
// hero freshness stat and the per-course "checked X ago" line, so a student
// deciding whether to trust a status badge can see how current it is
// without doing date-maths on an ISO timestamp themselves.
function timeAgo(isoString) {
  if (!isoString) return null;
  const diffMs = Date.now() - new Date(isoString).getTime();
  if (Number.isNaN(diffMs) || diffMs < 0) return null;
  const mins = Math.round(diffMs / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;
  const days = Math.round(hours / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

// Small Levenshtein distance for client-side "did you mean" suggestions.
// (A separate, tiny implementation - not shared with the backend's - since
// there is no build step to share modules between frontend and Lambda.)
function levenshtein(a, b) {
  a = a.toLowerCase(); b = b.toLowerCase();
  const m = a.length, n = b.length;
  const dp = Array.from({ length: m + 1 }, (_, i) => [i, ...Array(n).fill(0)]);
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost);
    }
  }
  return dp[m][n];
}

// ---- Qualification rows (A-level or BTEC) ----
function gradeOptionsHtml(type, selectedGrade) {
  const grades = (QUALIFICATION_TYPES[type] || QUALIFICATION_TYPES.alevel).grades;
  // Keep the same grade selected across a type switch where the option
  // still exists; otherwise default to the first (highest) option rather
  // than leaving nothing selected.
  const grade = grades.includes(selectedGrade) ? selectedGrade : grades[0];
  // Grade labels are from our own static constant, not user input, but we
  // escape anyway for consistency and defence in depth.
  return grades.map((g) => `<option ${g === grade ? 'selected' : ''}>${escapeHtml(g)}</option>`).join('');
}

function addAlevelRow(subject = '', grade = 'A', type = 'alevel') {
  const rows = el('alevels');
  if (rows.children.length >= MAX_ALEVELS) return;
  const row = document.createElement('div');
  row.className = 'alevel-row';
  const idx = rows.children.length;
  const qualType = QUALIFICATION_TYPES[type] ? type : 'alevel';
  row.innerHTML =
    `<div class="field">
       <label for="qual-${idx}">Qualification</label>
       <select id="qual-${idx}" class="al-type">
         ${Object.entries(QUALIFICATION_TYPES).map(([key, t]) =>
           `<option value="${escapeHtml(key)}" ${key === qualType ? 'selected' : ''}>${escapeHtml(t.label)}</option>`).join('')}
       </select>
     </div>
     <div class="field">
       <label for="subj-${idx}">Subject</label>
       <input type="text" id="subj-${idx}" class="al-subject" list="subject-list" value="${escapeHtml(subject)}" autocomplete="off" aria-describedby="subj-err-${idx}">
       <p class="al-subject-error" id="subj-err-${idx}" role="alert" hidden></p>
     </div>
     <div class="field">
       <label for="grade-${idx}">Grade</label>
       <select id="grade-${idx}" class="al-grade">
         ${gradeOptionsHtml(qualType, grade)}
       </select>
     </div>
     <button type="button" class="remove" aria-label="Remove this qualification">Remove</button>`;
  row.querySelector('.remove').addEventListener('click', () => { row.remove(); validateForm(); });
  // Changing the qualification type swaps the grade dropdown's options to
  // match that qualification's real grade scale (A*-E for A-level vs
  // D*D*D*-PPP for a BTEC Extended Diploma).
  row.querySelector('.al-type').addEventListener('change', (e) => {
    const gradeSelect = row.querySelector('.al-grade');
    const currentGrade = gradeSelect.value;
    gradeSelect.innerHTML = gradeOptionsHtml(e.target.value, currentGrade);
    validateForm();
  });
  row.querySelectorAll('input,select').forEach((i) => i.addEventListener('input', validateForm));
  const subjInput = row.querySelector('.al-subject');
  subjInput.addEventListener('input', () => validateSubjectField(row));
  subjInput.addEventListener('blur', () => validateSubjectField(row));
  if (subject) validateSubjectField(row);
  rows.appendChild(row);
  validateForm();
}

function clearAlevelRows() {
  el('alevels').innerHTML = '';
}

function collectAlevels() {
  return Array.from(document.querySelectorAll('.alevel-row')).map((r) => ({
    subject: r.querySelector('.al-subject').value.trim(),
    grade: r.querySelector('.al-grade').value,
    type: r.querySelector('.al-type').value,
  })).filter((s) => s.subject);
}

function totalSlots(entries) {
  return entries.reduce((sum, s) => sum + (QUALIFICATION_SLOTS[s.type] || 1), 0);
}

// Match a typed subject against the predefined valid-subject list (subjectNames,
// loaded once from /api/subjects). Returns:
//   {status:'empty'}                      - blank field, ignored
//   {status:'ok', canonical}              - exact (case-insensitive) match
//   {status:'suggest', suggestion}        - close typo; nearest valid subject
//   {status:'unknown'}                    - not recognised
// If the list has not loaded yet we don't block (defensive).
function matchSubject(value) {
  const v = (value || '').trim();
  if (!v) return { status: 'empty' };
  if (!subjectNames.length) return { status: 'ok', canonical: v };
  const lower = v.toLowerCase();
  const exact = subjectNames.find((s) => s.toLowerCase() === lower);
  if (exact) return { status: 'ok', canonical: exact };
  let best = null;
  let bestD = Infinity;
  for (const s of subjectNames) {
    const d = levenshtein(lower, s.toLowerCase());
    if (d < bestD) { bestD = d; best = s; }
  }
  const threshold = Math.max(2, Math.floor(lower.length * 0.34));
  if (best && bestD <= threshold) return { status: 'suggest', suggestion: best };
  return { status: 'unknown' };
}

// Render the inline error/suggestion for one qualification row's subject field.
function validateSubjectField(row) {
  const input = row.querySelector('.al-subject');
  const err = row.querySelector('.al-subject-error');
  if (!input || !err) return true;
  const m = matchSubject(input.value);
  if (m.status === 'ok' || m.status === 'empty') {
    input.removeAttribute('aria-invalid');
    err.hidden = true;
    err.textContent = '';
    return true;
  }
  input.setAttribute('aria-invalid', 'true');
  err.hidden = false;
  if (m.status === 'suggest') {
    err.innerHTML = `Not a recognised subject. Did you mean <button type="button" class="subj-suggest">${escapeHtml(m.suggestion)}</button>?`;
    const btn = err.querySelector('.subj-suggest');
    btn.addEventListener('click', () => {
      input.value = m.suggestion;
      validateSubjectField(row);
      validateForm();
      input.focus();
    });
  } else {
    err.textContent = 'Not a recognised subject - pick one from the list.';
  }
  return false;
}

function subjectsAllValid() {
  return collectAlevels().every((s) => matchSubject(s.subject).status === 'ok');
}

function validateForm() {
  const enoughSlots = totalSlots(collectAlevels()) >= 2;
  el('submit-btn').disabled = !(enoughSlots && subjectsAllValid());
}

// ---- Subject autocomplete (debounced) + "did you mean" ----
let debounce;
async function loadSubjects(q) {
  try {
    const res = await fetch(`${API}/subjects${q ? `?q=${encodeURIComponent(q)}` : ''}`, { cache: 'no-store' });
    if (!res.ok) return;
    const data = await res.json();
    // Sort alphabetically (case-insensitive) so the datalist dropdown appears
    // in order. Order does not affect validation/fuzzy matching (matchSubject
    // scans the whole list), so this is display-only.
    const subjects = (data.subjects || []).slice()
      .sort((a, b) => a.localeCompare(b, 'en-GB', { sensitivity: 'base' }));
    const list = el('subject-list');
    list.innerHTML = subjects.map((s) => `<option value="${escapeHtml(s)}">`).join('');
    if (!q) subjectNames = subjects; // cache the full (sorted) list from the initial empty-query load
  } catch { /* non-fatal */ }
}

// Shown while the user is typing, before they submit - lets a mistyped
// subject ("Buisness", "Comp Sci") get corrected early rather than silently
// resolving server-side or matching nothing.
function renderDidYouMean(query) {
  const box = el('did-you-mean');
  if (!query || query.length < 3 || !subjectNames.length) { box.hidden = true; return; }
  const qLower = query.toLowerCase();
  const exact = subjectNames.some((s) => s.toLowerCase() === qLower || s.toLowerCase().includes(qLower));
  if (exact) { box.hidden = true; return; }
  let best = null, bestD = 3;
  for (const name of subjectNames) {
    const d = levenshtein(qLower, name.toLowerCase());
    if (d < bestD) { bestD = d; best = name; }
  }
  if (!best) { box.hidden = true; return; }
  box.innerHTML = `Did you mean <button type="button" class="link-btn" id="dym-btn">${escapeHtml(best)}</button>?`;
  box.hidden = false;
  // Keep the raw suggestion for the click handler rather than reading it back
  // out of the (escaped) DOM text.
  el('dym-btn').addEventListener('click', () => {
    el('course-interest').value = best;
    box.hidden = true;
    renderDidYouMean('');
  });
}

// ---- Rendering ----

// Format an ISO-8601 UTC timestamp (as written by ingest_live_courses.py,
// e.g. "2026-08-13T18:03:56Z") into a short human string for the provenance
// line. Falls back to the raw value if it can't be parsed.
function fmtFetched(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getUTCDate()} ${months[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`;
}

// Expandable, clearly-labelled block of REAL per-course Clearing listings
// scraped from a university's own live page (Option B). Renders nothing unless
// the server attached a non-empty liveCourses array. Every course links to the
// university's own course page; the block carries an explicit source + fetch
// time and a "confirm with the university" caveat, because vacancies change
// hour-to-hour on Results Day. When the captured list is partial (the page's
// full list is JS/AJAX-driven), a prominent note says so and the live page
// stays the authoritative source.
function liveCoursesBlock(c) {
  // c.liveCourses is already SCOPED by the server: when the student searched a
  // subject it holds the matching courses (capped), otherwise a capped sample
  // of the whole list. c.liveCoursesMatched is the match total (null when no
  // subject searched, 0 when a subject matched nothing); c.liveCoursesCount is
  // the university's grand total; c.liveCoursesTruncated flags that the shown
  // set was capped. So no client-side filtering is needed here.
  const list = c.liveCourses;
  if (!Array.isArray(list)) return ''; // null => no live-course data for this uni
  const src = safeHttpsUrl(c.liveCoursesSource);
  const fetched = fmtFetched(c.liveCoursesFetchedAt);
  const total = c.liveCoursesCount != null ? c.liveCoursesCount : list.length;
  const matched = c.liveCoursesMatched; // null | number
  const srcLink = src
    ? `<a href="${escapeHtml(src)}" target="_blank" rel="noopener">the university's live Clearing page</a>`
    : "the university's live Clearing page";
  const provenance = `<div class="live-src">Scraped from ${srcLink}${fetched ? ` - fetched ${escapeHtml(fetched)}` : ''}. `
    + `Clearing vacancies can change within the hour on Results Day - always confirm the course is still open with the university before applying.</div>`;
  const partial = c.liveCoursesPartial
    ? `<div class="warn live-partial">${escapeHtml(c.liveCoursesPartialNote || 'This is only a sample of this university\u2019s Clearing courses. Open the live page above for the full list.')}</div>`
    : '';

  // Subject searched, but nothing at this university matched: say so plainly
  // (no list), and keep the live-page link as the way to see everything.
  if (matched === 0) {
    return `<details class="live-courses">
      <summary>No live Clearing courses here match \u201c${escapeHtml(searchedSubject || '')}\u201d</summary>
      ${provenance}
      <div class="live-src">None of the ${escapeHtml(total)} live Clearing course${total === 1 ? '' : 's'} at this university match \u201c${escapeHtml(searchedSubject || '')}\u201d. Open the live page above to browse them all.</div>
    </details>`;
  }

  const items = list.map((lc) => {
    const bits = [];
    if (lc.degree) bits.push(escapeHtml(lc.degree));
    if (lc.ucasCode) bits.push(`UCAS ${escapeHtml(lc.ucasCode)}`);
    if (lc.type) bits.push(escapeHtml(lc.type));
    if (lc.aLevel) bits.push(`A-level ${escapeHtml(lc.aLevel)}`);
    if (lc.btec) bits.push(`BTEC ${escapeHtml(lc.btec)}`);
    if (lc.ib) bits.push(`IB ${escapeHtml(lc.ib)}`);
    if (lc.tariff) bits.push(escapeHtml(lc.tariff));
    if (lc.entry) bits.push(`Entry: ${escapeHtml(lc.entry)}`);
    const meta = bits.length ? ` <span class="lc-meta">${bits.join(' \u00b7 ')}</span>` : '';
    // Real per-course Clearing status, where the source publishes it (Lincoln,
    // Loughborough). "closed" courses are shown - not hidden - so a student
    // knows this specific course is full rather than being left to guess.
    const status = lc.status === 'open'
      ? '<span class="lc-status open">Open</span> '
      : (lc.status === 'closed' ? '<span class="lc-status closed">Closed</span> ' : '');
    const lcUrl = safeHttpsUrl(lc.url);
    const title = lcUrl
      ? `<a href="${escapeHtml(lcUrl)}" target="_blank" rel="noopener">${escapeHtml(lc.title)}</a>`
      : escapeHtml(lc.title);
    return `<li class="${lc.status === 'closed' ? 'lc-closed' : ''}">${status}${title}${meta}</li>`;
  }).join('');

  let label;
  let note = '';
  if (matched != null) {
    label = `View ${matched} live Clearing course${matched === 1 ? '' : 's'} matching \u201c${escapeHtml(searchedSubject)}\u201d`;
    if (c.liveCoursesTruncated) {
      note = `<div class="live-src">Showing the first ${list.length} matches - open the live page above for the rest.</div>`;
    }
  } else if (c.liveCoursesPartial) {
    label = `View a sample of live Clearing courses (${list.length} shown of many)`;
  } else if (c.liveCoursesTruncated) {
    label = `View live Clearing courses (${list.length} of ${escapeHtml(total)} shown)`;
    note = `<div class="live-src">Showing ${list.length} of ${escapeHtml(total)} - enter a subject above to narrow, or open the live page for all.</div>`;
  } else {
    label = `View ${escapeHtml(total)} live Clearing course${total === 1 ? '' : 's'}`;
  }
  return `<details class="live-courses"${matched != null ? ' open' : ''}>
      <summary>${label}</summary>
      ${provenance}
      ${note}
      ${partial}
      <ul class="live-list">${items}</ul>
    </details>`;
}

function courseCard(c) {
  const badge = c.statusBadge || { colour: 'Amber', label: 'Check on Results Day' };
  const badgeColour = BADGE_COLOURS[badge.colour] || 'Amber';

  // Non-participating universities: a clear, self-contained card - no Clearing
  // phone/page/Results-Day text, because there are no Clearing places here.
  if (c.nonParticipating) {
    const npProspects = (c.graduateProspects != null)
      ? `<div class="stat-row"><div class="stat"><b>${escapeHtml(c.graduateProspects)}%</b><span>graduate prospects</span></div></div>`
      : '';
    return `<article class="course">
    <h3>${escapeHtml(c.universityName)}</h3>
    <div class="meta">${escapeHtml(c.courseTitle)}${c.ucasCode ? ` \u00b7 UCAS ${escapeHtml(c.ucasCode)}` : ''} \u00b7 ${escapeHtml(c.location)} \u00b7
      <span class="badge Red">${escapeHtml(badge.label)}</span></div>
    ${npProspects}
    <div class="warn">This university does not take part in UCAS Clearing. There are no Clearing places here - apply through the main UCAS cycle at <a href="https://www.ucas.com" target="_blank" rel="noopener">ucas.com</a> during the normal application window.</div>
  </article>`;
  }
  const phone = c.clearingPhone
    ? `<a href="tel:${escapeHtml(String(c.clearingPhone).replace(/[^+\d]/g, ''))}">${escapeHtml(c.clearingPhone)}</a>`
    : 'See clearing page';

  // clearingPageState (set server-side from the daily automated check) changes
  // how the clearing-page link itself is shown:
  //  - 'unreachable': the page was broken the last time it was checked, so
  //    linking to it as if it works would send students to a dead page. Swap
  //    the link for a plain phone-first warning instead.
  //  - 'blocked': the university's site blocked the automated check
  //    specifically (likely anti-bot, not necessarily broken for a real
  //    browser) - keep the link but add a softer heads-up.
  //  - anything else ('ok', or no data yet): show the link as normal.
  let cta = '';
  let pageWarn = '';
  const url = safeClearingUrl(c.clearingPage);
  if (url) {
    if (c.clearingPageState === 'unreachable') {
      pageWarn = '<div class="warn">Our last automated check could not load this university\'s clearing page - it may have moved. Use the phone number above instead.</div>';
    } else if (c.clearingPageState === 'blocked') {
      cta = `<div class="cta-row"><a class="live-cta" href="${escapeHtml(url)}" target="_blank" rel="noopener">View live Clearing courses \u2192</a></div>`;
      pageWarn = '<div class="note-line">Our automated check could not confirm this link is working, but it may just be blocking automated visits - it may still work fine in your browser.</div>';
    } else {
      cta = `<div class="cta-row"><a class="live-cta" href="${escapeHtml(url)}" target="_blank" rel="noopener">View live Clearing courses \u2192</a></div>`;
    }
  } else if (c.clearingPage) {
    // We had a value but it failed https validation - never render it as a link.
    pageWarn = '<div class="warn">Our last automated check could not verify this university\'s clearing page. Use the phone number above instead.</div>';
  }

  const warn = c.subjectWarning ? `<div class="warn">${escapeHtml(c.subjectWarning)}</div>` : '';
  const est = c.estimatedData ? ' <span class="badge Amber">Rough guide, not confirmed</span>' : '';
  const driftWarn = c.possibleStatusChange
    ? '<div class="warn">Automated check flagged a possible change to this page - status above may be out of date. Confirm directly.</div>'
    : '';

  // Per-card "checked X ago" and the university-level status caveat have moved
  // to a single disclaimer at the top of the results page.

  // Only show figures that are verified. Graduate prospects are per-university
  // (CUG 2027) where published and DO vary by university, so they stay on
  // each card. Salary is a national subject median (identical for every
  // university in this search) so it is shown once above the results list.
  const stats = [];
  if (c.graduateProspects != null) {
    stats.push(`<div class="stat"><b>${escapeHtml(c.graduateProspects)}%</b><span>graduate prospects</span></div>`);
  }

  // We no longer show a per-course "typical offer" grade band: it was derived
  // from institution tier, not the course's real published requirement, so it
  // risked being read as a genuine entry grade. Instead we say plainly that we
  // do not hold it, and point students to UCAS / the university.
  const offerLine = `<div class="offer-line">We don't hold this course's actual entry requirement. Check it on UCAS or call the university on Results Day.
    <a href="/faq.html#grades" class="faq-inline-link">How your points are worked out</a></div>`;

  const sources = [];
  const prospectsSource = safeHttpsUrl(c.graduateProspectsSourceUrl);
  if (c.graduateProspects != null && prospectsSource) {
    sources.push(`<a href="${escapeHtml(prospectsSource)}" target="_blank" rel="noopener">Prospects: ${escapeHtml(c.graduateProspectsYear || 'CUG 2027')}</a>`);
  }
  const sourceLine = sources.length ? `<div class="sources">Sources: ${sources.join(' \u00b7 ')}</div>` : '';

  return `<article class="course">
    <h3>${escapeHtml(c.universityName)}</h3>
    <div class="meta">${escapeHtml(c.courseTitle)}${c.ucasCode ? ` \u00b7 UCAS ${escapeHtml(c.ucasCode)}` : ''} \u00b7 ${escapeHtml(c.location)} \u00b7
      <span class="badge ${badgeColour}">${escapeHtml(badge.label)}</span>${est}</div>
    ${cta}
    ${liveCoursesBlock(c)}
    <div class="stat-row">
      ${stats.join('\n      ')}
    </div>
    ${offerLine}
    ${sourceLine}
    ${warn}
    ${driftWarn}
    <div class="contact">Clearing hotline: ${phone}
      ${c.hotlineOpens ? `<br>Hotline: ${escapeHtml(c.hotlineOpens)}` : ''}</div>
    ${pageWarn}
  </article>`;
}

function renderMore() {
  const container = el('results');
  const next = lastResults.slice(shown, shown + PAGE);
  container.insertAdjacentHTML('beforeend', next.map(courseCard).join(''));
  shown += next.length;
  el('show-more').hidden = shown >= lastResults.length;
}

// Salary is a national subject median - identical for every university in
// this result set - so it's shown once here rather than repeated per card.
function renderSalaryBanner(salaryContext) {
  const banner = el('salary-banner');
  if (!salaryContext || salaryContext.nationalMedianSalary == null) {
    banner.hidden = true;
    return;
  }
  const sourceUrl = safeHttpsUrl(salaryContext.sourceUrl);
  const sourceLink = sourceUrl
    ? `<a href="${escapeHtml(sourceUrl)}" target="_blank" rel="noopener">HESA Graduate Outcomes ${escapeHtml(salaryContext.year || '')}</a>`
    : `HESA Graduate Outcomes ${escapeHtml(salaryContext.year || '')}`;
  banner.innerHTML =
    `National median salary for <b>${escapeHtml(salaryContext.subject)}</b> graduates: `
    + `<b>${escapeHtml(fmtGBP(salaryContext.nationalMedianSalary))}</b> (15 months post-graduation, ${sourceLink}). `
    + `This is a national figure - it is the same for every university below, not a per-university wage.`;
  banner.hidden = false;
}

function showSkeletons() {
  el('results-section').hidden = false;
  el('results-summary').textContent = 'Searching...';
  el('results').innerHTML = Array(3).fill('<div class="skeleton" aria-hidden="true"></div>').join('');
  el('show-more').hidden = true;
}

// Actionable next steps when a search returns nothing, based on which
// filters are actually active - rather than a generic dead-end message.
function renderZeroResultsGuidance(payload) {
  const tips = [];
  if (payload.courseInterest) {
    tips.push(`Clear "${escapeHtml(payload.courseInterest)}" from what you want to study, to see every course you qualify for.`);
  }
  if (payload.russellGroupOnly) {
    tips.push('Untick "Russell Group only" - most universities in Clearing are outside the Russell Group.');
  }
  if (payload.location && payload.location !== 'any') {
    tips.push('Change location to "Anywhere in the UK".');
  }
  tips.push('Double-check your grades are entered correctly - a lower grade than intended will rule out more courses.');
  tips.push('If your grades are genuinely below what Clearing universities are asking for this year, call a university\'s clearing hotline directly - some accept applications below their published typical offer.');

  el('results-summary').innerHTML =
    'No matching courses found with these settings. Try:'
    + '<ul class="tip-list">' + tips.map((t) => `<li>${t}</li>`).join('') + '</ul>';
  el('show-more').hidden = true;
}

// ---- Shareable URL ----
// Encodes the current search into the address bar (replaceState only, so the
// back button isn't spammed) so a student can copy the link and reopen it
// later. Deliberately does NOT auto-run the search on load - a URL with query
// params should pre-fill the form, not silently spend the visitor's rate limit.
function updateShareUrl(payload) {
  const params = new URLSearchParams();
  // Third segment (qualification type) is omitted for plain A-levels to keep
  // links short for the common case; prefillFromUrl() treats a missing third
  // segment as 'alevel', so older links keep working.
  for (const s of payload.subjects) {
    params.append('a', s.type && s.type !== 'alevel' ? `${s.subject}:${s.grade}:${s.type}` : `${s.subject}:${s.grade}`);
  }
  if (payload.courseInterest) params.set('ci', payload.courseInterest);
  if (payload.priority && payload.priority !== 'balanced') params.set('priority', payload.priority);
  if (payload.location && payload.location !== 'any') params.set('location', payload.location);
  if (payload.russellGroupOnly) params.set('rg', '1');
  const url = `${location.pathname}?${params.toString()}`;
  history.replaceState(null, '', params.toString() ? url : location.pathname);
}

function prefillFromUrl() {
  const params = new URLSearchParams(location.search);
  const subjectPairs = params.getAll('a');
  if (!subjectPairs.length) return false;
  clearAlevelRows();
  for (const pair of subjectPairs.slice(0, MAX_ALEVELS)) {
    // Backward compatible: links created before BTEC support only have
    // "subject:grade" (2 parts) and always meant an A-level.
    const [subject, grade, type] = pair.split(':');
    const qualType = QUALIFICATION_TYPES[type] ? type : 'alevel';
    const grades = QUALIFICATION_TYPES[qualType].grades;
    if (subject) addAlevelRow(decodeURIComponent(subject), grades.includes(grade) ? grade : grades[0], qualType);
  }
  if (params.get('ci')) el('course-interest').value = params.get('ci');
  if (params.get('priority')) el('priority').value = params.get('priority');
  if (params.get('location')) el('location').value = params.get('location');
  if (params.get('rg') === '1') el('russellGroupOnly').checked = true;
  return true;
}

// ---- Submit ----
async function onSubmit(e) {
  e.preventDefault();
  const subjects = collectAlevels();
  if (totalSlots(subjects) < 2) return;
  // Reject qualification subjects that are not on the valid-subject list.
  if (!subjectsAllValid()) {
    const rows = Array.from(document.querySelectorAll('.alevel-row'));
    rows.forEach(validateSubjectField);
    const firstBad = rows.find((r) => {
      const val = r.querySelector('.al-subject').value.trim();
      return val && matchSubject(val).status !== 'ok';
    });
    if (firstBad) firstBad.querySelector('.al-subject').focus();
    return;
  }
  // Send the canonical spelling of each subject, not the raw typed value.
  const normSubjects = subjects.map((s) => ({ ...s, subject: matchSubject(s.subject).canonical || s.subject }));
  showSkeletons();

  const payload = {
    subjects: normSubjects,
    courseInterest: el('course-interest').value.trim(),
    priority: el('priority').value,
    location: el('location').value,
    russellGroupOnly: el('russellGroupOnly').checked,
    website: el('website').value, // honeypot - must stay empty
    limit: 50,
  };

  // Lock the form while the request is in flight - prevents a double-tap on a
  // slow connection from firing two searches and burning the rate limit.
  const submitBtn = el('submit-btn');
  const originalLabel = submitBtn.textContent;
  submitBtn.disabled = true;
  submitBtn.textContent = 'Searching...';

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), SEARCH_TIMEOUT_MS);

  const started = performance.now();
  try {
    const res = await fetch(`${API}/search`, {
      method: 'POST',
      cache: 'no-store',
      signal: controller.signal,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) {
      el('results').innerHTML = '';
      el('salary-banner').hidden = true;
      el('results-summary').innerHTML = `<span class="error">${escapeHtml(data.message || 'Something went wrong.')}</span>`;
      return;
    }
    updateShareUrl(payload);
    lastResults = data.results || [];
    searchedSubject = data.resolvedCourseInterest || null;
    shown = 0;
    el('results').innerHTML = '';
    renderSalaryBanner(data.salaryContext);
    const secs = ((performance.now() - started) / 1000).toFixed(1);
    if (!lastResults.length) {
      renderZeroResultsGuidance(payload);
      return;
    }
    const freshness = data.dataFreshness ? new Date(data.dataFreshness).toLocaleString('en-GB') : '';
    // The student's own tariff is exact (their entered grades run through the
    // official UCAS Tariff tables), unlike course requirements which we don't
    // hold. Shown once here, above the result list, not repeated per card.
    const profile = data.userTariffGrades ? `${escapeHtml(data.userTariffGrades)} - ` : '';
    const tariffLine = data.userTariffPoints != null
      ? `<div class="tariff-line">Your entry profile: <strong>${profile}${escapeHtml(data.userTariffPoints)} UCAS points</strong> (from the grades you entered - see <a href="/faq.html#grades" class="text-link">how this is calculated</a>).</div>`
      : '';

    // Single prominent disclaimer: one global "last checked" time (the most
    // recent automated check across the shown results) plus the university-level
    // status caveat. Replaces the per-card timestamp and per-card status note.
    const checkTimes = lastResults
      .map((c) => c.lastAutomatedCheck).filter(Boolean)
      .map((t) => new Date(t).getTime()).filter((t) => !Number.isNaN(t));
    const lastChecked = checkTimes.length ? timeAgo(new Date(Math.max(...checkTimes)).toISOString()) : null;
    const disclaimer = `<div class="results-disclaimer" role="note">`
      + `<strong>Clearing status last checked: ${lastChecked ? escapeHtml(lastChecked) : 'not yet checked'}.</strong> `
      + `The status shown reflects each university's overall Clearing availability, not this specific course. `
      + `Always confirm directly with the university before relying on it.`
      + `</div>`;

    el('results-summary').innerHTML =
      disclaimer
      + tariffLine
      + `Found ${escapeHtml(data.totalMatches)} courses in ${escapeHtml(secs)} seconds. `
      + `Showing the top ${escapeHtml(Math.min(PAGE, lastResults.length))}. Data last updated: ${escapeHtml(freshness)}.`;
    renderMore();
  } catch (err) {
    el('results').innerHTML = '';
    el('salary-banner').hidden = true;
    if (err.name === 'AbortError') {
      el('results-summary').innerHTML = '<span class="error">This is taking longer than usual. Please try again in a moment.</span>';
    } else {
      el('results-summary').innerHTML = '<span class="error">Could not reach the service. Please try again.</span>';
    }
  } finally {
    clearTimeout(timeoutId);
    submitBtn.textContent = originalLabel;
    validateForm(); // restores disabled state based on current field values
  }
}

// ---- Freshness stat (hero banner) ----
// Shows the ACTUAL most recent automated check across all tracked universities.
// Before any check data is available it shows the current automated cadence,
// which matches the deployed EventBridge Scheduler phases (kept in sync with
// terraform/modules/scraper-schedule). Never blocks or breaks the page.
function scrapeCadenceLabel() {
  const now = Date.now();
  const t = (s) => new Date(s).getTime();
  if (now < t('2026-08-11T23:00:00Z')) return 'Every 30 min';
  if (now < t('2026-08-13T23:00:00Z')) return 'Every 10 min';
  if (now < t('2026-08-31T23:00:00Z')) return '4x a day';
  return 'Seasonal'; // paused outside the Clearing window
}

async function updateFreshnessStat() {
  // Default to the current automated cadence (accurate even before data loads).
  el('freshness-value').textContent = scrapeCadenceLabel();
  try {
    const res = await fetch(`${API}/universities`, { cache: 'no-store' });
    if (!res.ok) return;
    const data = await res.json();
    const timestamps = (data.universities || [])
      .map((u) => u.lastAutomatedCheck)
      .filter(Boolean)
      .map((t) => new Date(t).getTime())
      .filter((t) => !Number.isNaN(t));
    if (!timestamps.length) return;
    const mostRecent = new Date(Math.max(...timestamps)).toISOString();
    const ago = timeAgo(mostRecent);
    if (ago) el('freshness-value').textContent = `Checked ${ago}`;
  } catch { /* keep the cadence label set above */ }
}

// ---- Init ----
document.addEventListener('DOMContentLoaded', () => {
  const prefilled = prefillFromUrl();
  if (!prefilled) {
    addAlevelRow();
    addAlevelRow();
  }
  loadSubjects('').then(() => {
    document.querySelectorAll('.alevel-row').forEach(validateSubjectField);
    validateForm();
  });
  updateFreshnessStat();
  el('add-alevel').addEventListener('click', () => addAlevelRow());
  const ciInput = el('course-interest');
  const clearCiBtn = el('clear-ci');
  const toggleClearCi = () => { clearCiBtn.classList.toggle('is-visible', !!ciInput.value); };
  toggleClearCi(); // reflect any prefilled value on load
  clearCiBtn.addEventListener('click', () => {
    clearTimeout(debounce);
    ciInput.value = '';
    el('did-you-mean').hidden = true;
    toggleClearCi();
    ciInput.focus();
  });
  ciInput.addEventListener('input', (e) => {
    toggleClearCi();
    clearTimeout(debounce);
    const q = e.target.value.trim();
    if (q.length >= 2) {
      // Do NOT re-fetch a server-filtered list into #subject-list here: that
      // datalist is SHARED with the "Your qualifications" subject fields, so
      // narrowing it to the typed study subject made those fields show only
      // that one subject. The full list is loaded once at init and the browser
      // filters the datalist natively as the user types. Keep only the fuzzy
      // "did you mean" suggestion for the study field.
      debounce = setTimeout(() => { renderDidYouMean(q); }, 300);
    } else {
      el('did-you-mean').hidden = true;
    }
  });
  el('search-form').addEventListener('submit', onSubmit);
  el('show-more').addEventListener('click', renderMore);
  validateForm();
});
