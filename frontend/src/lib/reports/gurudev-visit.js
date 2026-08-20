/**
 * Gurudev visit report: registrations by province, city, and country.
 *
 * Ported from a standalone dashboard.html preview, since removed -- this module
 * and the route are the only copy now. The rendering drives the DOM directly
 * rather than going through Svelte bindings: it was already verified against the
 * live warehouse, so it was moved across intact instead of being rewritten in
 * idiomatic Svelte. The markup it expects lives in the route's +page.svelte, and
 * its styles in gurudev-visit.css (global, because innerHTML output never
 * receives Svelte's scoping attribute).
 *
 * The DOM lookups are narrowed once here, at the top, instead of at each of the
 * ~40 use sites below.
 */

/** @typedef {{ course_id: string, course_name?: string, start_date?: string, end_date?: string, status?: string }} Course */
/** @typedef {{ dimension: string, category: string, course_id: string, registration_count: number, course_registration_count: number }} Item */
/** @typedef {{ items: Item[], courses: Course[], total_registration_count: number, total_course_count: number, available_provinces: string[], available_countries: string[], data_synced_at: string | null }} Report */
/** @typedef {{ key: string, empty: string }} MultiConfig */

/** @param {string} id */
const el = (id) => /** @type {HTMLElement} */ (document.getElementById(id));
/** @param {string} id */
const inputEl = (id) => /** @type {HTMLInputElement} */ (document.getElementById(id));
/** @param {string} id */
const selectEl = (id) => /** @type {HTMLSelectElement} */ (document.getElementById(id));
/** @param {string} key */
const msNode = (key) =>
  /** @type {HTMLElement} */ (document.querySelector(`.ms[data-filter="${key}"]`));
/** @param {HTMLElement} node @param {string} selector */
const within = (node, selector) =>
  /** @type {HTMLElement} */ (node.querySelector(selector));

// Scoped to the two Gurudev visit programs only. The server enforces this too --
// the reports router refuses any course outside its allowlist.
const COURSE_IDS = ['4521', '4522'];
// Personal attributes (gender, age group) and workflow fields (registration
// status, guest type) are deliberately not offered here.
const DIMENSIONS = ['Province', 'City', 'Country'];
const API = '/reports/retreat-guru-course-demographics';

const nf = new Intl.NumberFormat('en-CA');

// Retreat Guru stores its form's "Other" province option lowercase. Presented
// capitalised so it reads as a label rather than a stray value -- display only:
// the raw string is still what gets filtered on, and nothing in the warehouse
// changes. Distinct from (unknown), which this dashboard adds for registrations
// whose person record is missing.
const CATEGORY_LABELS = /** @type {Record<string, string>} */ ({ other: 'Other' });

/** @param {string} value */
const categoryLabel = (value) => CATEGORY_LABELS[value] ?? value;

/** @type {MultiConfig[]} */
const MULTI = [
  { key: 'province', empty: 'All provinces' },
  { key: 'country', empty: 'All countries' }
];

/**
 * Mount the report into the already-rendered markup.
 *
 * @param {object} deps
 * @param {(path: string) => Promise<any>} deps.request Fetches an API path and returns parsed JSON.
 * @returns {Promise<void>}
 */
export async function mountGurudevVisitReport({ request }) {
  /** @type {{ courses: Course[], selected: Set<string>, expanded: Set<string>, options: Record<string, string[]>, filters: Record<string, Set<string>>, search: Record<string, string> }} */
  const state = {
    courses: [],
    selected: new Set(COURSE_IDS),
    expanded: new Set(),
    options: { province: [], country: [] },
    filters: { province: new Set(), country: new Set() },
    search: { province: '', country: '' }
  };

  /** @param {string | null} message */
  function showError(message) {
    const box = el('errorBox');
    if (!message) {
      box.hidden = true;
      box.innerHTML = '';
      return;
    }
    box.hidden = false;
    box.innerHTML = `<div class="error">${message}</div>`;
  }

  /**
   * @param {string} path
   * @param {[string, string][]} params
   */
  async function api(path, params) {
    const qs = new URLSearchParams();
    for (const [key, value] of params) {
      if (value === null || value === undefined || value === '') continue;
      qs.append(key, value);
    }
    const query = qs.toString();
    return request(`${path}${query ? `?${query}` : ''}`);
  }

  /** @returns {[string, string][]} */
  function filterParams() {
    /** @type {[string, string][]} */
    const params = [];
    for (const id of state.selected) params.push(['course_id', id]);
    for (const { key } of MULTI) {
      for (const value of state.filters[key]) params.push([key, value]);
    }
    params.push(['include_cancelled', inputEl('includeCancelled').checked ? 'true' : 'false']);
    const dimension = selectEl('dimension').value;
    if (dimension) params.push(['dimension', dimension]);
    return params;
  }

  /** @param {MultiConfig} config */
  function renderMulti(config) {
    const node = msNode(config.key);
    const options = state.options[config.key];
    const chosen = state.filters[config.key];
    const query = state.search[config.key].trim().toLowerCase();
    // A chosen value stays listed even when it does not match the query --
    // otherwise typing would hide a selection that is still being applied.
    const visible = query
      ? options.filter(
          (o) =>
            o.toLowerCase().includes(query) ||
            categoryLabel(o).toLowerCase().includes(query) ||
            chosen.has(o)
        )
      : options;

    within(node, '.ms-list').innerHTML = visible.length
      ? visible
          .map(
            (option) =>
              `<label class="${chosen.has(option) ? 'on' : ''}"><input type="checkbox" value="${escapeHtml(option)}" ${
                chosen.has(option) ? 'checked' : ''
              } /><span>${escapeHtml(categoryLabel(option))}</span></label>`
          )
          .join('')
      : `<p class="ms-note">${options.length ? 'Nothing matches that search.' : 'No values in the current scope.'}</p>`;
    const label = within(node, '.ms-value');
    if (chosen.size === 0) {
      label.textContent = config.empty;
      label.classList.add('empty');
    } else {
      const picked = options.filter((option) => chosen.has(option));
      const shown = picked.length ? picked : [...chosen];
      label.textContent =
        shown.length <= 2 ? shown.map(categoryLabel).join(', ') : `${shown.length} selected`;
      label.classList.remove('empty');
    }
    const count = within(node, '.ms-count');
    if (count) {
      count.textContent = chosen.size ? String(chosen.size) : '';
      count.hidden = chosen.size === 0;
    }
  }

  function renderAllMulti() {
    for (const config of MULTI) renderMulti(config);
  }

  /** @param {MultiConfig} config */
  function wireMulti(config) {
    const node = msNode(config.key);

    const search = /** @type {HTMLInputElement | null} */ (node.querySelector('.ms-search input'));
    if (search) {
      search.addEventListener('input', () => {
        state.search[config.key] = search.value;
        renderMulti(config);
      });
      // Typing in the box must not reach the details element, which would
      // otherwise treat the keystroke as a toggle.
      search.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') {
          search.value = '';
          state.search[config.key] = '';
          renderMulti(config);
          node.removeAttribute('open');
        }
        event.stopPropagation();
      });
    }

    // Click anywhere else closes the dropdown, which a bare <details> will not do.
    document.addEventListener('click', (event) => {
      if (node.hasAttribute('open') && !node.contains(/** @type {Node} */ (event.target))) {
        node.removeAttribute('open');
      }
    });

    node.addEventListener('change', (event) => {
      const input = /** @type {HTMLInputElement} */ (event.target);
      if (input.type !== 'checkbox') return;
      if (input.checked) state.filters[config.key].add(input.value);
      else state.filters[config.key].delete(input.value);
      renderMulti(config);
    });
    node.addEventListener('click', (event) => {
      const button = /** @type {HTMLElement} */ (event.target).closest('button');
      if (!button) return;
      event.preventDefault();
      if (button.hasAttribute('data-select-all')) {
        for (const option of state.options[config.key]) state.filters[config.key].add(option);
      } else {
        state.filters[config.key].clear();
      }
      renderMulti(config);
    });
  }

  function renderCourseList() {
    el('courseList').innerHTML = state.courses
      .map((course) => {
        const checked = state.selected.has(course.course_id) ? 'checked' : '';
        const dates = [course.start_date, course.end_date].filter(Boolean).join(' → ') || 'no dates';
        return `<label><input type="checkbox" value="${course.course_id}" ${checked} />
          <span><span class="cname">${text(course.course_name || '(unnamed)')}</span>
          <span class="cmeta">#${course.course_id} · ${dates} · ${text(course.status || '')}</span></span></label>`;
      })
      .join('');
    updateCourseCount();
  }

  function updateCourseCount() {
    el('courseCount').textContent =
      `${nf.format(state.selected.size)} selected of ${nf.format(state.courses.length)} programs`;
  }

  async function loadCourses() {
    const body = await api(`${API}/courses`, [
      ...(/** @type {[string, string][]} */ (COURSE_IDS.map((id) => ['course_id', id]))),
      ['page_size', '50']
    ]);
    const known = new Set(COURSE_IDS);
    state.courses = body.items.filter(
      (/** @type {Course} */ course) => known.has(course.course_id)
    );
    renderCourseList();
  }

  /** @param {Report} payload */
  function renderSyncedAt(payload) {
    const node = el('syncedAt');
    if (!node) return;
    const iso = payload.data_synced_at;
    if (!iso) {
      // Null means no ingested_at anywhere, which is itself worth saying rather
      // than leaving the line blank and implying freshness.
      node.textContent = 'Sync time unavailable.';
      node.removeAttribute('title');
      return;
    }
    const age = describeAge(iso);
    const exact = new Date(iso).toLocaleString('en-CA');
    node.textContent = `Warehouse data last synced ${age ?? 'at an unknown time'} · ${exact}`;
    node.title = `Oldest of the three source tables' most recent ingested_at (${iso})`;
  }

  /** @param {Report} payload */
  function refreshOptions(payload) {
    state.options.province = payload.available_provinces || [];
    state.options.country = payload.available_countries || [];
    renderAllMulti();
  }

  /** @param {Report} payload */
  function renderCharts(payload) {
    el('mRegs').textContent = nf.format(payload.total_registration_count);
    el('mCourses').textContent = nf.format(payload.total_course_count);

    const meta = new Map(payload.courses.map((c) => [c.course_id, c]));
    // Fixed program order so a program keeps its colour no matter which ones are
    // selected, and no matter what order the API returns.
    const series = COURSE_IDS.filter((id) => meta.has(id)).map((id) => ({
      id,
      label: decodeHtml(meta.get(id)?.course_name || `Course ${id}`),
      color: `var(--series-${COURSE_IDS.indexOf(id) + 1})`,
      total: 0
    }));

    if (!series.length) {
      el('charts').innerHTML =
        `<section class="panel"><p class="empty">No registrations matched these filters.</p></section>`;
      return;
    }

    // One panel per dimension, one bar per program inside each category.
    const allowed = new Set(DIMENSIONS);
    /** @type {Map<string, Map<string, Map<string, Item>>>} */
    const byDimension = new Map();
    for (const row of payload.items) {
      if (!allowed.has(row.dimension)) continue;
      if (!byDimension.has(row.dimension)) byDimension.set(row.dimension, new Map());
      const categories = /** @type {Map<string, Map<string, Item>>} */ (
        byDimension.get(row.dimension)
      );
      if (!categories.has(row.category)) categories.set(row.category, new Map());
      /** @type {Map<string, Item>} */ (categories.get(row.category)).set(row.course_id, row);
      const entry = series.find((s) => s.id === row.course_id);
      if (entry) entry.total = row.course_registration_count || entry.total;
    }

    const cards = [];
    for (const dimension of DIMENSIONS) {
      const categories = byDimension.get(dimension);
      if (!categories) continue;

      const groups = [...categories.entries()].map(([category, rows]) => ({
        category,
        rows,
        total: series.reduce((sum, s) => sum + (rows.get(s.id)?.registration_count || 0), 0)
      }));
      // The API orders categories by people; this view counts registrations.
      groups.sort((a, b) => b.total - a.total || a.category.localeCompare(b.category));

      // One scale per panel, so bars are comparable across both categories and
      // programs within the dimension.
      const max = Math.max(
        ...groups.flatMap((g) => series.map((s) => g.rows.get(s.id)?.registration_count || 0)),
        1
      );
      const expanded = state.expanded.has(dimension);
      const visible = expanded ? groups : groups.slice(0, 10);

      const bars = visible
        .map((group) => {
          const lines = series
            .map((s) => {
              const count = group.rows.get(s.id)?.registration_count || 0;
              const share = s.total ? ((count / s.total) * 100).toFixed(1) : '0.0';
              const tip = `${s.label} (#${s.id}) — ${decodeHtml(categoryLabel(group.category))}: ${nf.format(
                count
              )} of ${nf.format(s.total)} registrations (${share}%)`;
              return `<div class="bar-line" title="${escapeHtml(tip)}">
                <div class="bar-track"><div class="bar-fill"
                  style="background:${s.color};width:${(count / max) * 100}%"></div></div>
                <span class="bar-val">${nf.format(count)} · ${share}%</span>
              </div>`;
            })
            .join('');
          return `<div class="bar-group">
            <div class="bar-cat">${text(categoryLabel(group.category))}</div>
            ${lines}
          </div>`;
        })
        .join('');

      // A legend only earns its box with two or more programs on screen; with
      // one, naming it in the heading is enough.
      const legend =
        series.length > 1
          ? `<div class="legend">${series
              .map(
                (s) =>
                  `<span class="legend-item"><span class="swatch"
                    style="background:${s.color}"></span>${escapeHtml(s.label)} (#${s.id})</span>`
              )
              .join('')}</div>`
          : `<div class="legend">${escapeHtml(series[0].label)} (#${series[0].id})</div>`;
      const more =
        groups.length > 10
          ? `<button class="more" data-toggle="${escapeHtml(dimension)}">${
              expanded ? 'Show top 10' : `Show all ${groups.length} categories`
            }</button>`
          : '';
      cards.push(`<section class="panel">
        <div class="panel-heading">
          <div>
            <p class="kicker" style="margin:0">Registrations by</p>
            <h2>${escapeHtml(dimension)}</h2>
          </div>
          <span class="pill">${groups.length} categories</span>
        </div>
        ${legend}
        <div class="bars">${bars}${more}</div>
      </section>`);
    }
    el('charts').innerHTML =
      cards.join('') ||
      `<section class="panel"><p class="empty">No registrations matched these filters.</p></section>`;
  }

  async function loadReport() {
    showError(null);
    if (state.selected.size === 0) {
      el('charts').innerHTML = '';
      el('mRegs').textContent = el('mCourses').textContent = '—';
      showError('Select at least one program, then Apply filters.');
      return;
    }
    el('charts').classList.add('busy');
    try {
      const body = await api(API, [...filterParams(), ['page_size', '500']]);
      refreshOptions(body);
      renderSyncedAt(body);
      renderCharts(body);
    } catch (error) {
      el('charts').innerHTML = '';
      el('mRegs').textContent = el('mCourses').textContent = '—';
      showError(escapeHtml(error instanceof Error ? error.message : String(error)));
    } finally {
      el('charts').classList.remove('busy');
    }
  }

  el('courseList').addEventListener('change', (event) => {
    const input = /** @type {HTMLInputElement} */ (event.target);
    if (input.type !== 'checkbox') return;
    if (input.checked) state.selected.add(input.value);
    else state.selected.delete(input.value);
    updateCourseCount();
  });
  el('apply').addEventListener('click', loadReport);
  el('clear').addEventListener('click', () => {
    state.selected = new Set(COURSE_IDS);
    state.expanded.clear();
    for (const key of Object.keys(state.filters)) state.filters[key].clear();
    renderAllMulti();
    inputEl('includeCancelled').checked = false;
    selectEl('dimension').value = '';
    renderCourseList();
    loadReport();
  });
  el('charts').addEventListener('click', (event) => {
    const toggle = /** @type {HTMLElement} */ (event.target).closest('[data-toggle]');
    if (!toggle) return;
    const key = /** @type {HTMLElement} */ (toggle).dataset.toggle;
    if (!key) return;
    if (state.expanded.has(key)) state.expanded.delete(key);
    else state.expanded.add(key);
    loadReport();
  });

  for (const config of MULTI) wireMulti(config);
  for (const dimension of DIMENSIONS) {
    selectEl('dimension').insertAdjacentHTML(
      'beforeend',
      `<option>${escapeHtml(dimension)}</option>`
    );
  }
  try {
    await loadCourses();
    await loadReport();
  } catch (error) {
    showError(escapeHtml(error instanceof Error ? error.message : String(error)));
  }
}

/** @param {unknown} value */
function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (c) =>
      /** @type {Record<string, string>} */ ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
      })[c]
  );
}

// Retreat Guru stores names already HTML-escaped ("Death &amp; Journey"), so
// decode once before re-escaping for output -- otherwise the page shows a literal
// "&amp;". Only display text goes through this; filter values that get sent back
// to the API are left exactly as the API returned them.
/** @type {Record<string, string>} */
const NAMED_ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

/** @param {unknown} value */
function decodeHtml(value) {
  return String(value).replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, code) => {
    if (code[0] === '#') {
      const point =
        code[1].toLowerCase() === 'x' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(point) && point > 0 ? String.fromCodePoint(point) : whole;
    }
    const named = NAMED_ENTITIES[code.toLowerCase()];
    return named === undefined ? whole : named;
  });
}

/** @param {unknown} value */
const text = (value) => escapeHtml(decodeHtml(value ?? ''));

/**
 * "3 hours ago" style age, so a stale snapshot is obvious at a glance in a way an
 * absolute timestamp is not. The exact time goes in the title attribute for
 * anyone who needs it.
 *
 * @param {string} iso
 */
export function describeAge(iso) {
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return null;
  const minutes = Math.floor((Date.now() - then.getTime()) / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}
