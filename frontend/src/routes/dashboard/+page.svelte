<script lang="ts">
  let { data } = $props();

  const nf = new Intl.NumberFormat('en-CA');

  // Retreat Guru stores names already HTML-escaped ("Death &amp; Journey").
  // Svelte escapes on output, so without decoding first the page shows the
  // literal "&amp;".
  const ENTITIES: Record<string, string> = {
    amp: '&',
    lt: '<',
    gt: '>',
    quot: '"',
    apos: "'",
    nbsp: ' '
  };

  function decode(value: string | null | undefined): string {
    return String(value ?? '').replace(/&([a-z]+);/gi, (whole, code: string) => {
      const named = ENTITIES[code.toLowerCase()];
      return named === undefined ? whole : named;
    });
  }

  const report = $derived(data.report);

  // Per-program registration totals come from any row for that program: the API
  // repeats the program's own total on every row it returns.
  const programs = $derived(
    (report?.courses ?? []).map((course) => ({
      ...course,
      name: decode(course.course_name),
      registrations:
        report?.items.find((item) => item.course_id === course.course_id)
          ?.course_registration_count ?? 0
    }))
  );

  const firstDay = $derived(
    programs
      .map((p) => p.start_date)
      .filter((d): d is string => Boolean(d))
      .sort()[0] ?? null
  );

  // Whole days, floored, from today to the first programme's start date.
  const daysAway = $derived.by(() => {
    if (!firstDay) return null;
    const start = new Date(firstDay + 'T00:00:00');
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return Math.round((start.getTime() - today.getTime()) / 86_400_000);
  });

  const countries = $derived(
    (report?.available_countries ?? []).filter((c) => c !== '(unknown)').length
  );

  function dateRange(start: string | null, end: string | null): string {
    if (!start) return 'dates to be confirmed';
    const fmt = (iso: string) =>
      new Date(iso + 'T00:00:00').toLocaleDateString('en-CA', {
        month: 'short',
        day: 'numeric'
      });
    const year = new Date(start + 'T00:00:00').getFullYear();
    return end && end !== start ? `${fmt(start)} – ${fmt(end)}, ${year}` : `${fmt(start)}, ${year}`;
  }
</script>

<section class="page">
  <header class="hero">
    <p class="eyebrow">Gurudev Visit &middot; September 2026</p>
    <h1>{data.dashboard.greeting}</h1>
    <p class="sub">
      Signed in as {data.user?.email} &middot; {data.dashboard.role}
    </p>
  </header>

  {#if report}
    <div class="stats">
      <div class="stat">
        <span>Registrations</span>
        <strong>{nf.format(report.total_registration_count)}</strong>
      </div>
      <div class="stat">
        <span>Programs</span>
        <strong>{nf.format(report.total_course_count)}</strong>
      </div>
      <div class="stat">
        <span>Countries</span>
        <strong>{nf.format(countries)}</strong>
      </div>
      {#if daysAway !== null}
        <div class="stat">
          <span>{daysAway >= 0 ? 'Days away' : 'Days since'}</span>
          <strong>{nf.format(Math.abs(daysAway))}</strong>
        </div>
      {/if}
    </div>
  {:else}
    <p class="notice">
      Live registration figures are unavailable right now &mdash; the warehouse connection did not
      respond. The report below will show the same error until it recovers.
    </p>
  {/if}

  <h2 class="section-title">Reports</h2>

  <a class="card" href="/reports/gurudev-visit">
    <div class="card-body">
      <h3>Registrations by region</h3>
      <p>Province, city, and country breakdowns for both visit programs, with filters.</p>
      {#if programs.length}
        <ul class="programs">
          {#each programs as program (program.course_id)}
            <li>
              <span class="pname">{program.name}</span>
              <span class="pmeta">
                {dateRange(program.start_date, program.end_date)}
                &middot; {nf.format(program.registrations)} registrations
              </span>
            </li>
          {/each}
        </ul>
      {/if}
    </div>
    <span class="chev" aria-hidden="true">&rarr;</span>
  </a>
</section>

<style>
  .page {
    max-width: 52rem;
    margin: 0 auto;
  }

  .hero {
    padding-bottom: 1.5rem;
    border-bottom: 1px solid var(--border);
  }

  .eyebrow {
    margin: 0 0 0.4rem;
    font-size: 0.75rem;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--accent);
  }

  h1 {
    margin: 0;
    font-size: 1.9rem;
    line-height: 1.15;
    letter-spacing: -0.01em;
  }

  .sub {
    margin: 0.5rem 0 0;
    color: var(--muted);
    font-size: 0.9rem;
  }

  .stats {
    display: grid;
    gap: 0.75rem;
    grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
    margin-top: 1.5rem;
  }

  .stat {
    display: grid;
    gap: 0.2rem;
    padding: 0.9rem 1rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--surface);
  }

  .stat span {
    font-size: 0.78rem;
    font-weight: 600;
    color: var(--muted);
  }

  .stat strong {
    font-size: 1.6rem;
    line-height: 1.1;
    font-variant-numeric: tabular-nums;
  }

  .notice {
    margin-top: 1.5rem;
    padding: 0.9rem 1rem;
    border: 1px solid var(--border);
    border-left: 3px solid var(--danger);
    border-radius: 8px;
    color: var(--muted);
    font-size: 0.9rem;
  }

  .section-title {
    margin: 2.25rem 0 0.75rem;
    font-size: 0.78rem;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--muted);
  }

  .card {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 1.1rem 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--surface);
    color: inherit;
    text-decoration: none;
    transition:
      border-color 0.15s ease,
      transform 0.15s ease;
  }

  .card:hover {
    border-color: var(--accent);
    transform: translateY(-1px);
  }

  .card-body {
    flex: 1;
    min-width: 0;
  }

  .card h3 {
    margin: 0;
    font-size: 1.05rem;
    color: var(--accent);
  }

  .card p {
    margin: 0.3rem 0 0;
    color: var(--muted);
    font-size: 0.9rem;
  }

  .programs {
    margin: 0.9rem 0 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 0.5rem;
  }

  .programs li {
    padding-left: 0.75rem;
    border-left: 2px solid var(--border);
  }

  .pname {
    display: block;
    font-size: 0.9rem;
    font-weight: 600;
  }

  .pmeta {
    display: block;
    font-size: 0.82rem;
    color: var(--muted);
  }

  .chev {
    flex: none;
    font-size: 1.2rem;
    color: var(--muted);
  }

  @media (prefers-reduced-motion: reduce) {
    .card {
      transition: none;
    }

    .card:hover {
      transform: none;
    }
  }
</style>
