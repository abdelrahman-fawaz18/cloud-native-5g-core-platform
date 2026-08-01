# Metrics And Dashboards

This directory will contain Prometheus scrape configuration, recording and
alert rules, Grafana data-source provisioning, and version-controlled dashboard
definitions.

Dashboards must use live measured data. Metric labels must be reviewed for
bounded cardinality, and alerts must be tested for both firing and resolution.
