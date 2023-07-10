CREATE DATABASE dora;

\ c dora;

CREATE TABLE events_raw (
  source VARCHAR(255),
  event_type VARCHAR(255),
  id VARCHAR(255),
  metadata JSON,
  time_created TIMESTAMPTZ,
  signature VARCHAR(255)
);

CREATE
OR REPLACE VIEW public.changes AS
SELECT
  source,
  event_type,
  commit ->> 'id' AS change_id,
  DATE_TRUNC(
    'second',
    TO_TIMESTAMP(
      commit ->> 'timestamp',
      'YYYY-MM-DD HH24:MI:SS.US'
    )
  ) AS time_created
FROM
  events_raw e,
  JSON_ARRAY_ELEMENTS(e.metadata -> 'commits') AS commit
WHERE
  event_type = 'push'
GROUP BY
  1,
  2,
  3,
  4;

CREATE
OR REPLACE VIEW public.deployments AS WITH deploys AS (
  SELECT
    source,
    id as deploy_id,
    time_created,
    metadata -> 'deployment' ->> 'sha' as main_commit,
    ARRAY(
      SELECT
        string_element ->> ''
      FROM
        json_array_elements(metadata -> 'deployment' -> 'additional_sha') AS string_element
    ) as additional_commits
  FROM
    events_raw
  WHERE
    source LIKE 'github%'
    and event_type = 'deployment_status'
    and metadata -> 'deployment_status' ->> 'state' = 'success'
),
changes_raw AS (
  SELECT
    id,
    metadata as change_metadata
  FROM
    events_raw
),
deployment_changes as (
  SELECT
    source,
    deploy_id,
    deploys.time_created as time_created,
    change_metadata,
    (
      SELECT
        ARRAY_AGG(c)
      FROM
        json_array_elements(change_metadata -> 'commits') AS c
    ) as array_commits,
    main_commit
  FROM
    deploys
    JOIN changes_raw on (
      changes_raw.id = deploys.main_commit
      or changes_raw.id = ANY (deploys.additional_commits)
    )
)
SELECT
  source,
  deploy_id,
  time_created,
  main_commit,
  ARRAY_AGG(DISTINCT t ->> 'id') changes
FROM
  deployment_changes
  CROSS JOIN (
    SELECT
      UNNEST(array_commits) as t
    from
      deployment_changes
  ) AS commits
GROUP BY
  1,
  2,
  3,
  4;

CREATE
OR REPLACE VIEW public.incident AS
SELECT
  source,
  incident_id,
  MIN(
    CASE
      WHEN root.time_created < issue.time_created THEN root.time_created
      ELSE issue.time_created
    END
  ) as time_created,
  MAX(time_resolved) as time_resolved,
  ARRAY_AGG(root_cause) changes
FROM
  (
    SELECT
      source,
      metadata -> 'issue' ->> 'number' AS incident_id,
      TO_TIMESTAMP(
        metadata -> 'issue' ->> 'created_at',
        'YYYY-MM-DD HH24:MI:SS.US'
      ) AS time_created,
      TO_TIMESTAMP(
        metadata -> 'issue' ->> 'closed_at',
        'YYYY-MM-DD HH24:MI:SS.US'
      ) AS time_resolved,
      SUBSTRING(metadata :: text, 'root cause: (\w+)') as root_cause,
      CASE
        WHEN metadata -> 'issue' ->> 'labels' :: text LIKE '%"name":"Incident"%' THEN TRUE
        ELSE FALSE
      END AS bug
    FROM
      events_raw
    WHERE
      event_type LIKE 'issue%'
      OR event_type LIKE 'incident%'
      OR (
        event_type = 'note'
        AND metadata -> 'object_attributes' ->> 'noteable_type' = 'Issue'
      )
  ) issue
  LEFT JOIN (
    SELECT
      time_created,
      changes
    FROM
      (
        SELECT
          time_created,
          UNNEST(changes) AS changes
        FROM
          deployments
      ) d
  ) root on root.changes = root_cause
GROUP BY
  1,
  2
HAVING
  max(
    CASE
      WHEN bug THEN 1
      ELSE 0
    END
  ) = 1;

CREATE DATABASE grafana;

CREATE USER grafana WITH ENCRYPTED PASSWORD 'admin@123';

GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana;

\ c grafana;

GRANT ALL ON SCHEMA public TO grafana;