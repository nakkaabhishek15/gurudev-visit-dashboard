import { beforeEach, describe, expect, it, vi } from 'vitest';

// The report writes into markup that lives in the route component, so the test
// uses that same markup rather than a copy of it -- a renamed id then fails here
// instead of silently rendering nothing in the browser. `?raw` gives the file's
// text without compiling it as a component.
import PAGE_SOURCE from '../../routes/reports/gurudev-visit/+page.svelte?raw';

import { mountGurudevVisitReport } from './gurudev-visit.js';

const MARKUP = PAGE_SOURCE.split('</script>')[1];

const COURSES = {
  items: [
    {
      course_id: '4521',
      course_name: 'Full Immersion (Silence + Wisdom) Retreat',
      start_date: '2026-09-25',
      end_date: '2026-09-30',
      status: 'confirmed'
    },
    {
      course_id: '4522',
      course_name: 'Wisdom - Life, Death &amp; Journey Beyond',
      start_date: '2026-09-26',
      end_date: '2026-09-27',
      status: 'confirmed'
    }
  ],
  total_count: 2
};

const REPORT = {
  total_registration_count: 162,
  total_course_count: 2,
  courses: COURSES.items,
  available_provinces: ['(unknown)', 'ON', 'QC'],
  available_countries: ['(unknown)', 'CA', 'US'],
  items: [
    { dimension: 'Province', category: 'ON', course_id: '4521', registration_count: 20, course_registration_count: 67 },
    { dimension: 'Province', category: 'ON', course_id: '4522', registration_count: 24, course_registration_count: 95 },
    { dimension: 'Province', category: 'QC', course_id: '4521', registration_count: 5, course_registration_count: 67 },
    { dimension: 'City', category: 'Mississauga', course_id: '4521', registration_count: 6, course_registration_count: 67 },
    { dimension: 'Country', category: 'CA', course_id: '4522', registration_count: 40, course_registration_count: 95 }
  ]
};

/** @param {string} path */
function stubRequest(path) {
  return Promise.resolve(path.includes('/courses') ? COURSES : REPORT);
}

describe('gurudev visit report', () => {
  beforeEach(() => {
    document.body.innerHTML = MARKUP;
  });

  it('renders the metric tiles from the API totals', async () => {
    await mountGurudevVisitReport({ request: stubRequest });

    expect(document.getElementById('mRegs')?.textContent).toBe('162');
    expect(document.getElementById('mCourses')?.textContent).toBe('2');
  });

  it('lists both programs and preselects them', async () => {
    await mountGurudevVisitReport({ request: stubRequest });

    const boxes = /** @type {HTMLInputElement[]} */ ([
      ...document.querySelectorAll('#courseList input[type=checkbox]')
    ]);
    expect(boxes.map((b) => b.value)).toEqual(['4521', '4522']);
    expect(boxes.every((b) => b.checked)).toBe(true);
    expect(document.getElementById('courseCount')?.textContent).toBe('2 selected of 2 programs');
  });

  it('decodes Retreat Guru\'s pre-escaped names instead of showing "&amp;"', async () => {
    await mountGurudevVisitReport({ request: stubRequest });

    const names = document.getElementById('courseList')?.textContent ?? '';
    expect(names).toContain('Death & Journey Beyond');
    expect(names).not.toContain('&amp;');
  });

  it('draws one panel per dimension with a bar per program', async () => {
    await mountGurudevVisitReport({ request: stubRequest });

    const headings = [...document.querySelectorAll('#charts h2')].map((h) => h.textContent);
    expect(headings).toEqual(['Province', 'City', 'Country']);

    // Province/ON has both programs, so both bars are drawn in that group.
    const group = /** @type {HTMLElement} */ (document.querySelector('#charts .bar-group'));
    expect(group.querySelector('.bar-cat')?.textContent).toBe('ON');
    expect(group.querySelectorAll('.bar-line')).toHaveLength(2);
  });

  it('shows each program its share of its own total, not of the grand total', async () => {
    await mountGurudevVisitReport({ request: stubRequest });

    const values = [...document.querySelectorAll('#charts .bar-group .bar-val')].map(
      (v) => v.textContent
    );
    // 20 of 4521's 67 registrations, and 24 of 4522's 95.
    expect(values[0]).toBe('20 · 29.9%');
    expect(values[1]).toBe('24 · 25.3%');
  });

  it('sends the filters the user picked, and keeps the facet list intact', async () => {
    const request = vi.fn(stubRequest);
    await mountGurudevVisitReport({ request });

    /** @type {HTMLInputElement} */ (document.getElementById('includeCancelled')).checked = true;
    const province = /** @type {HTMLElement} */ (
      document.querySelector('.ms[data-filter="province"] .ms-list input[value="ON"]')
    );
    /** @type {HTMLInputElement} */ (province).checked = true;
    province.dispatchEvent(new Event('change', { bubbles: true }));

    /** @type {HTMLElement} */ (document.getElementById('apply')).click();
    await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(3));

    const url = request.mock.calls[2][0];
    expect(url).toContain('province=ON');
    expect(url).toContain('include_cancelled=true');
    expect(url).toContain('course_id=4521');

    // available_provinces comes back unfiltered, so the choice stays widenable.
    expect(document.querySelectorAll('.ms[data-filter="province"] .ms-list input')).toHaveLength(3);
  });

  it('surfaces an API failure in the error box and clears the metrics', async () => {
    await mountGurudevVisitReport({
      request: (path) =>
        path.includes('/courses')
          ? Promise.resolve(COURSES)
          : Promise.reject(new Error('500 — warehouse unreachable'))
    });

    const box = /** @type {HTMLElement} */ (document.getElementById('errorBox'));
    expect(box.hidden).toBe(false);
    expect(box.textContent).toContain('warehouse unreachable');
    expect(document.getElementById('mRegs')?.textContent).toBe('—');
  });
});
