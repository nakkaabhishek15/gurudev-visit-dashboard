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

# Geography arrives as a jsonb blob on the person, not as columns. Retreat Guru
# calls the province "state" regardless of country.
DIMENSION_COLUMNS = {
    "Province": "state",
    "City": "city",
    "Country": "country",
}

# A third of the registrations for these programs have a person_id with no row in
# retreat_guru_people, so they carry no geography at all. They get their own
# bucket rather than being dropped -- silently discarding them would make the
# per-dimension bars disagree with the registration total on the same screen.
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
    """SQL for one geography field, with blanks and missing people folded into UNKNOWN."""
    return f"COALESCE(NULLIF(BTRIM(p.address->>'{column}'), ''), '{UNKNOWN}')"


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
    LEFT JOIN raw_data.retreat_guru_people p ON p.person_id = r.person_id
    WHERE r.program_id = ANY(%(course_ids)s)
      AND (%(include_cancelled)s OR r.status IS DISTINCT FROM 'cancelled')
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

    return {
        "items": items,
        "courses": course_rows,
        "total_registration_count": summary["total_registration_count"],
        "total_course_count": summary["total_course_count"],
        "available_provinces": sorted(summary["available_provinces"] or []),
        "available_countries": sorted(summary["available_countries"] or []),
    }
