"""Retreat Guru reporting endpoints backing the Gurudev visit dashboard.

Everything here reads `raw_data.retreat_guru_*` on the AOLF warehouse over a
read-only connection. Note that `mart.report_course_registrations` looks like the
natural source and is not: it holds no rows for the Gurudev visit programs, and
it carries province but neither city nor country.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query, status

from app.db.session import warehouse_connection
from app.settings import get_settings

router = APIRouter(prefix="/reports", tags=["reports"])

# Geography comes from the address captured ON THE REGISTRATION, not from the
# person's profile. Both carry the same six keys and they never disagree, but the
# profile is missing for a fifth of registrations -- reading it dropped those into
# (unknown) and undercounted real provinces. Retreat Guru's own reports use the
# registration answer, so this now matches them. Retreat Guru calls the province
# "state" regardless of country.
DIMENSION_COLUMNS = {
    "Province": "state",
    "City": "city",
    "Country": "country",
}

# Kept for the rare registration that left the address blank. It should now be a
# small bucket or absent entirely; it is still drawn rather than dropped so the
# per-dimension bars always reconcile with the registration total beside them.
UNKNOWN = "(unknown)"


def _allowed_course_ids(requested: list[str] | None) -> list[str]:
    """Intersect the request with the server-side allowlist.

    The dashboard only ever asks for the Gurudev visit programs, but the check
    belongs here: a signed-in user editing the query string must not be able to
    read demographics for unrelated Retreat Guru courses.
    """
    allowed = get_settings().course_id_allowlist()
    if not requested:
        return allowed
    chosen = [course_id for course_id in requested if course_id in allowed]
    if not chosen:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"No reportable course requested. Available: {', '.join(allowed)}.",
        )
    return chosen


def _geo(column: str) -> str:
    """SQL for one geography field of the registration's address answer."""
    return f"COALESCE(NULLIF(BTRIM(r.questions->'address'->>'{column}'), ''), '{UNKNOWN}')"


# Registration rows in scope, one per registration, with geography resolved.
# `include_cancelled` is applied here so it moves the facet lists and the totals
# too, not just the bars.
BASE_SQL = f"""
    SELECT r.registration_id,
           r.program_id      AS course_id,
           {_geo('state')}   AS province,
           {_geo('city')}    AS city,
           {_geo('country')} AS country
    FROM raw_data.retreat_guru_registrations r
    WHERE r.program_id = ANY(%(course_ids)s)
      AND (%(include_cancelled)s OR r.status IS DISTINCT FROM 'cancelled')
"""

# The report is only as fresh as its stalest input, so this reports the OLDEST of
# the three tables' newest rows rather than the newest overall -- claiming the
# data is current because one table synced would be the wrong way to be wrong.
# The sync upserts on record_hash, so a table's MAX(ingested_at) moves whenever
# the sync last saw a change there.
SYNCED_AT_SQL = """
    SELECT LEAST(
        (SELECT MAX(ingested_at) FROM raw_data.retreat_guru_registrations),
        (SELECT MAX(ingested_at) FROM raw_data.retreat_guru_programs)
    ) AS data_synced_at
"""

# The ::text[] casts are load-bearing. Without them Postgres cannot infer a type
# for the parameter when the filter is absent (it arrives as a bare NULL) and
# rejects the whole statement with AmbiguousParameter.
FILTERED_SQL = """
    SELECT * FROM base
    WHERE (%(provinces)s::text[] IS NULL OR province = ANY(%(provinces)s::text[]))
      AND (%(countries)s::text[] IS NULL OR country  = ANY(%(countries)s::text[]))
"""


@router.get("/retreat-guru-course-demographics/courses")
def courses(
    course_id: list[str] | None = Query(default=None),
    page_size: int = Query(default=50, ge=1, le=200),
) -> dict[str, object]:
    course_ids = _allowed_course_ids(course_id)
    with warehouse_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT program_id AS course_id,
                       name       AS course_name,
                       start_date,
                       end_date,
                       status
                FROM raw_data.retreat_guru_programs
                WHERE program_id = ANY(%s)
                ORDER BY start_date NULLS LAST, program_id
                LIMIT %s
                """,
                (course_ids, page_size),
            )
            items = [dict(row) for row in cur.fetchall()]
    return {"items": items, "total_count": len(items)}


@router.get("/retreat-guru-course-demographics")
def course_demographics(
    course_id: list[str] | None = Query(default=None),
    province: list[str] | None = Query(default=None),
    country: list[str] | None = Query(default=None),
    dimension: str | None = Query(default=None),
    include_cancelled: bool = Query(default=False),
    page_size: int = Query(default=500, ge=1, le=5000),
) -> dict[str, object]:
    course_ids = _allowed_course_ids(course_id)

    dimensions = list(DIMENSION_COLUMNS)
    if dimension:
        if dimension not in DIMENSION_COLUMNS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unknown dimension {dimension!r}. Expected one of: {', '.join(DIMENSION_COLUMNS)}.",
            )
        dimensions = [dimension]

    params: dict[str, object] = {
        "course_ids": course_ids,
        "include_cancelled": include_cancelled,
        "provinces": province or None,
        "countries": country or None,
        "page_size": page_size,
    }

    # One row per (dimension, registration). The dimension names are interpolated
    # from DIMENSION_COLUMNS keys, never from the request -- `dimension` is
    # validated against that dict above before it can reach here.
    tall = " UNION ALL ".join(
        f"SELECT course_id, '{name}' AS dimension, {name.lower()} AS category FROM filtered"
        for name in dimensions
    )

    items_sql = f"""
        WITH base AS ({BASE_SQL}),
             filtered AS ({FILTERED_SQL}),
             course_totals AS (
                 SELECT course_id, COUNT(*) AS course_registration_count
                 FROM filtered GROUP BY course_id
             ),
             tall AS ({tall})
        SELECT t.dimension,
               t.category,
               t.course_id,
               COUNT(*)                          AS registration_count,
               MAX(ct.course_registration_count) AS course_registration_count
        FROM tall t
        JOIN course_totals ct ON ct.course_id = t.course_id
        GROUP BY t.dimension, t.category, t.course_id
        ORDER BY t.dimension, COUNT(*) DESC, t.category
        LIMIT %(page_size)s
    """

    # The facet lists come from `base`, before the province/country filters are
    # applied. Reading them from `filtered` would empty the very list a value was
    # picked from, leaving no way to widen the selection again.
    summary_sql = f"""
        WITH base AS ({BASE_SQL}),
             filtered AS ({FILTERED_SQL})
        SELECT (SELECT COUNT(*) FROM filtered)                  AS total_registration_count,
               (SELECT COUNT(DISTINCT course_id) FROM filtered) AS total_course_count,
               (SELECT ARRAY_AGG(DISTINCT province) FROM base)  AS available_provinces,
               (SELECT ARRAY_AGG(DISTINCT country)  FROM base)  AS available_countries
    """

    with warehouse_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(items_sql, params)
            items = [dict(row) for row in cur.fetchall()]

            cur.execute(summary_sql, params)
            summary = dict(cur.fetchone())

            cur.execute(
                """
                SELECT program_id AS course_id, name AS course_name, start_date, end_date
                FROM raw_data.retreat_guru_programs
                WHERE program_id = ANY(%s)
                ORDER BY start_date NULLS LAST, program_id
                """,
                (course_ids,),
            )
            course_rows = [dict(row) for row in cur.fetchall()]

            cur.execute(SYNCED_AT_SQL)
            synced_at = cur.fetchone()["data_synced_at"]

    return {
        "items": items,
        "courses": course_rows,
        "total_registration_count": summary["total_registration_count"],
        "total_course_count": summary["total_course_count"],
        "available_provinces": sorted(summary["available_provinces"] or []),
        "available_countries": sorted(summary["available_countries"] or []),
        "data_synced_at": synced_at,
    }
