<script>
  // The report drives the DOM directly rather than through Svelte bindings: this
  // view was ported from a standalone page that was already verified against the
  // live warehouse, so the rendering moved across intact. The markup below is
  // what it expects; the logic and the type narrowing live in the module.
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { api, ApiError } from '$lib/api';
  import { mountGurudevVisitReport } from '$lib/reports/gurudev-visit.js';
  import '$lib/reports/gurudev-visit.css';

  onMount(() => {
    mountGurudevVisitReport({
      request: async (path) => {
        try {
          return await api(path);
        } catch (error) {
          if (error instanceof ApiError) {
            // The session expired mid-session; an error box would be a dead end.
            if (error.status === 401) {
              await goto('/login');
            }
            throw new Error(`${error.status} — ${error.message}`);
          }
          throw error;
        }
      }
    });
  });
</script>

<div class="rg-report">
      <header class="page-header">
        <div>
          <p class="kicker">Reports</p>
          <h1>Gurudev Visit - Sept 2026</h1>
          <p class="subtitle">
            Registrations for the two Gurudev visit programs, broken down by province, city, and country.
          </p>
        </div>
      </header>

      <div class="stack">
        <div id="errorBox" hidden></div>

        <section class="metric-row">
          <div class="metric"><span>Registrations</span><strong id="mRegs">—</strong></div>
          <div class="metric"><span>Courses in scope</span><strong id="mCourses">—</strong></div>
        </section>

        <section class="panel">
          <div class="panel-heading">
            <p class="kicker" style="margin:0">Filters</p>
            <span id="courseCount" class="pill">loading programs…</span>
          </div>
          <div class="filter-form">
            <!-- Not a <label>: the checkboxes inside are inserted at runtime, so
                 there is no single control for it to be bound to. -->
            <div class="field programs">
              <span>Programs</span>
              <div class="course-picker">
                <div class="course-list" id="courseList"></div>
              </div>
            </div>
            <label>
              <span>Dimension</span>
              <select id="dimension">
                <option value="">All dimensions</option>
              </select>
            </label>
            <div class="field"><span>Province</span>
              <details class="ms" data-filter="province">
                <summary><span class="ms-value empty">All provinces</span><span class="ms-count" hidden></span></summary>
                <div class="ms-search"><input type="search" placeholder="Search provinces" aria-label="Search provinces" /></div>
                <div class="ms-list"></div>
                <div class="ms-actions"><button data-select-all>Select all</button><button data-clear-all>Clear</button></div>
              </details>
            </div>
            <div class="field"><span>Country</span>
              <details class="ms" data-filter="country">
                <summary><span class="ms-value empty">All countries</span><span class="ms-count" hidden></span></summary>
                <div class="ms-search"><input type="search" placeholder="Search countries" aria-label="Search countries" /></div>
                <div class="ms-list"></div>
                <div class="ms-actions"><button data-select-all>Select all</button><button data-clear-all>Clear</button></div>
              </details>
            </div>
            <div class="field">
              <span>Include cancelled</span>
              <label class="checkline">
                <input type="checkbox" id="includeCancelled" aria-label="Include cancelled registrations" />
              </label>
            </div>
          </div>
          <div class="actions">
            <button class="primary" id="apply">Apply filters</button>
            <button class="ghost" id="clear">Reset</button>
          </div>
        </section>

        <div class="charts" id="charts"></div>
      </div>
    </div>
