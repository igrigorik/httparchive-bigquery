#standardSQL
SELECT
  *,
  SUM(pdf) OVER (PARTITION BY client ORDER BY bin) AS cdf
FROM (
  SELECT
    *,
    volume / SUM(volume) OVER (PARTITION BY client) AS pdf
  FROM (
    SELECT
      client,
      COUNT(0) AS volume,
      CAST(FLOOR(FLOAT64(summary.bytesJS) / 10240) * 10 AS INT64) AS bin
    FROM
      `httparchive.crawl.pages`
    WHERE
      date = '${YYYY-MM-DD}' AND
      is_root_page
    GROUP BY
      bin,
      client
  )
)
ORDER BY
  bin,
  client
