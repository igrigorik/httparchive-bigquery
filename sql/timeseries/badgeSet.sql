#standardSQL
SELECT
  FORMAT_TIMESTAMP('%Y_%m_%d', date) AS date,
  UNIX_DATE(date) * 1000 * 60 * 60 * 24 AS timestamp,
  client,
  SUM(IF(feat.id IS NOT NULL, 1, 0)) AS num_urls,
  ROUND(SUM(IF(feat.id IS NOT NULL, 1, 0)) / COUNT(0) * 100, 5) AS percent
FROM
  `httparchive.crawl.pages`
LEFT OUTER JOIN UNNEST(features) AS feat
ON (feat.id = '2726' OR feat.feature = 'BadgeSet')
WHERE
  date = '2024-11-01' AND
  is_root_page
GROUP BY
  date,
  timestamp,
  client
ORDER BY
  date DESC,
  client,
  num_urls DESC
