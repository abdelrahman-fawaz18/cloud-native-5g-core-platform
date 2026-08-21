# Dashboard Visual Evidence

This directory accepts only selected, privacy-reviewed PNG captures from the
Git-provisioned Grafana dashboards. A capture must:

- show synthetic project data only;
- exclude browser chrome, local paths, usernames, credentials, and unrelated
  applications;
- be at least 1200 by 600 pixels and contain no PNG text or EXIF metadata;
- identify its dashboard UID, title, Git commit, UTC capture time, time range,
  variables, scenario, proof, and limitation in
  `release/dashboard-evidence.json`;
- have a SHA-256 checksum that matches that manifest; and
- agree with the accepted machine-readable reports and dashboard JSON.

The required final set covers the service overview, telecom session/DNN view,
reviewed performance, and reviewed recovery. Screenshots are
visual summaries; commands, tests, and reports remain the source of truth.
