# Resilience Testing Runbook

## Safety Boundary

Run every command from the repository root on the Ubuntu host. The lifecycle
uses the project kubeconfig and the `cn5g` namespace only. Do not manually
delete Deployments, StatefulSets, namespaces, Secrets, PVCs, or kind/Docker
resources during a campaign.

Raw evidence is written under ignored `benchmarks/raw/resilience/`. A failed
attempt is intentionally retained. Rerunning the same matrix command creates a
new numbered attempt and resumes the remaining conditions.

## Before Snapshot And Preflight

```bash
cd ~/projects/cloud-native-5g-core-platform
sudo -v
./scripts/capture-host-state.sh before-resilience
sudo ./scripts/resilience-campaign.sh preflight
```

Expected final markers:

```text
resilience_fault_targets=pass replicas=1 selectors=exact
deterministic_resilience_baseline_render=pass
resilience_preflight=pass
```

If platform or observability stack validation fails, do not inject a fault. Run the scoped
recovery action below, then repeat preflight.

## Component Pilots

Run and review one pilot at a time:

```bash
sudo ./scripts/resilience-campaign.sh pilot amf
sudo ./scripts/resilience-campaign.sh pilot smf
sudo ./scripts/resilience-campaign.sh pilot upf
```

Each successful pilot ends with:

```text
resilience_attempt=pass component=<component> mode=<automatic|operator-assisted> ...
resilience_pilot=pass component=<component> ...
```

An `operator-assisted` result is not itself a failed experiment. It means the
replacement Pod became Ready but full 5G service required the documented
session-repair procedure. A pilot fails if the fault was not detected, the
replacement did not become Ready, evidence could not be captured, persistent
identity changed, or the complete baseline did not return.

## Repeated Matrix

After all three pilots pass:

```bash
sudo ./scripts/resilience-campaign.sh run-matrix
```

The runner executes nine accepted conditions and stops on the first failed
attempt. Review the retained failure, recover the baseline if necessary, and
rerun the identical command to resume. Do not edit the experiment contract
during a campaign; a changed contract intentionally abandons the old campaign
state rather than mixing results.

Expected final marker:

```text
resilience_matrix=pass campaign=<UTC-ID>-matrix accepted=9
```

## Secondary Safety Tests

After the main matrix:

```bash
sudo ./scripts/resilience-campaign.sh test-mongodb
sudo ./scripts/resilience-campaign.sh test-invalid-config
```

Expected markers include:

```text
resilience_mongodb_recreation=pass pvc_identity=preserved subscriber_records=5
resilience_invalid_configuration_test=pass release_revision_unchanged=<revision>
```

The invalid-config action uses dry-run admission and must not create its test
Deployment or increment the Helm release revision.

## Analysis

Run analysis without `sudo`:

```bash
./scripts/resilience-campaign.sh analyze
```

It should accept exactly nine conditions and create two CSV files, one JSON
summary, three SVGs, and one report. If it rejects evidence, preserve the raw
campaign and correct or repeat only the affected runtime condition; never hand
edit a runtime manifest into a passing result.

## Reviewed Dashboard Acceptance

After analysis passes, install the reviewed resilience campaign projection through the
existing observability lifecycle:

```bash
sudo ./scripts/observability-lifecycle.sh preflight
sudo ./scripts/observability-lifecycle.sh install
sudo ./scripts/observability-lifecycle.sh test-alerts
```

Expected markers include:

```text
resilience_dashboard_metrics=pass
prometheus_target_health=pass ue_targets=5 reviewed_results_targets=2
resilience_reviewed_metric_validation=pass accepted_conditions=9 series=75 limit=100
grafana_provisioning=pass datasources=2 dashboards=6
observability_validation=pass
observability_alert_lifecycle=pass tested=3
```

Then start the loopback-only Grafana session:

```bash
sudo ./scripts/observability-lifecycle.sh grafana
```

Open `http://127.0.0.1:13000`, inspect **CN5G Reliability And Recovery** and
the cross-dashboard links, and keep the session open for at least 30 minutes.
Press Ctrl-C in the terminal after inspection, then run:

```bash
sudo ./scripts/observability-lifecycle.sh verify-grafana-soak
```

The gate requires the same Grafana Pod, no restart increase, no runtime plugin
installation, and at least 20% memory headroom below the 768 MiB limit.

The accepted run lasted 2,606 seconds, retained the same Ready Pod with zero
restart increase, and measured a 468.6 MiB peak under the 768 MiB limit.

## Scoped Recovery

If a command is interrupted or the five-UE baseline is unhealthy:

```bash
sudo ./scripts/resilience-campaign.sh recover
```

Expected final marker:

```text
resilience_recovery=pass baseline=platform-and-observability
```

This action performs dependency-ordered session reconstruction and complete
Platform and observability validation. It preserves the Helm releases, subscriber Secret,
MongoDB PVC, observability PVCs, and kind-node return-route contract.

## Final Snapshot

Capture the after state only after analysis, secondary tests, reviewed-result
dashboard acceptance, and final regression pass:

```bash
./scripts/capture-host-state.sh after-resilience
```
