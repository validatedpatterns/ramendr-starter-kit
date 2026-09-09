# RamenDR Starter Kit

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![AWS](https://img.shields.io/endpoint?url=https%3A%2F%2Fstorage.googleapis.com%2Fhcp-results%2Faegitops-aws-ci.json)](https://storage.googleapis.com/hcp-results/aegitops-aws-ci.json)

## Start Here

If you've followed a link to this repository, but are not really sure what it contains
or how to use it, head over to [RamenDR Starter Kit](https://validatedpatterns.io/patterns/ramendr-starter-kit/)
for additional context and installation instructions.

## Documentation

| Topic | URL |
|-------|-----|
| Pattern overview and architecture | [RamenDR Starter Kit](https://validatedpatterns.io/patterns/ramendr-starter-kit/) |
| Deployment and secrets | [Getting Started](https://validatedpatterns.io/patterns/ramendr-starter-kit/getting-started/) |
| Install sequencing, scripts, and operations | [Installation Details](https://validatedpatterns.io/patterns/ramendr-starter-kit/installation-details/) |
| Architecture and connectivity (variants) | [Architecture](https://validatedpatterns.io/patterns/ramendr-starter-kit/architecture/) · [Connectivity](https://validatedpatterns.io/patterns/ramendr-starter-kit/connectivity/) |

## Variants

This pattern uses the clustergroup/ACM `variants/` folder layout. Presence of
`variants/` makes the patterns-operator set `global.vpNewFolderDir=true`.

Spoke BOMs nest under the install variant as
`variants/<variant>/values-<managedClusterGroup.name>.yaml`.

| Variant | Select | Purpose |
|---------|--------|---------|
| `odf` (default) | `main.variant: odf` | Baseline: full ODF Regional DR + Virtualization; `byoc: true` |
| `drpartner-s4` | `main.variant: drpartner-s4` | Partner CSI + hub S4: OADP, OCP-V, preview RHDR; infrastructure DRClusters + `2m-novm` DRPolicy (no `2m-vm`/DRPC/VMs); Submariner disabled; `byoc: true` |
| `drpartner-minimal` | `main.variant: drpartner-minimal` | Partner CSI without S4, Submariner, or DRCluster sync/validation: OADP, OCP-V, preview RHDR; Hive/BYOC only (`byoc: true`) |

Layout:

```text
values-global.yaml
variants/
  odf/
    values-odf.yaml
    values-resilient.yaml              # full ODF spoke BOM
  drpartner-s4/
    values-drpartner-s4.yaml           # preview RHDR catalog/IDMS + vp-s4-storage
    values-resilient.yaml              # partner spoke BOM (no ODF; preview RHDR catalog/IDMS)
    values-regional-dr.yaml            # infrastructureEnabled: DRClusters + 2m-novm only + hub s3StoreProfiles; byoc: true
    values-console-plugins-*.yaml
  drpartner-minimal/
    values-drpartner-minimal.yaml      # preview RHDR catalog/IDMS; no vp-s4-storage
    values-resilient.yaml              # partner spoke BOM (preview RHDR catalog/IDMS)
    values-regional-dr.yaml            # resourcesEnabled + infrastructureEnabled false; byoc: true
    values-opp-policy.yaml             # submariner.enabled: false
    values-console-plugins-*.yaml
overrides/                             # shared hub/spoke chart overrides
```

### S3 profiles and DRClusters by variant

| Variant | Hub DRClusters | Hub s3StoreProfiles | Buckets | CA on profiles |
|---------|----------------|---------------------|---------|----------------|
| `odf` | MirrorPeer / MCO | MirrorPeer / MCO | ODF | opp-policy `s3CaInjector` |
| `drpartner-s4` | regionaldr (`ramen.infrastructureEnabled`) | regionaldr upsert (`ensureBuckets: false`) | **vp-s4-storage** `s4Role.buckets` | opp-policy `s3CaInjector` |
| `drpartner-minimal` | none | none | none | n/a |

Example — set the variant in [`values-global.yaml`](values-global.yaml):

```yaml
main:
  variant: drpartner-s4
```

Control-test chart pins (until published on charts.validatedpatterns.io):

| Chart | Target version | Fork branch |
|-------|----------------|-------------|
| opp-policy-chart | 0.0.5 | `vp-manage-proxy-cluster-ca` |
| odf-dr-chart | 0.0.4 | `vp-manage-proxy-cluster-ca` |
| regionaldr-with-virt | 0.1.0 | `conditionalize_resources` |
| vp-manage-proxy-cluster-ca | 0.2.1 | `eso-externalsecret-argocd-sync` |

`drpartner-s4` expectations after sync: s3-ssl/CA via **opp-policy** (Submariner disabled in `values-opp-policy.yaml`), hub **vp-s4-storage** (buckets via `s4Role.buckets`), preview RHDR (catalog + IDMS + `rhdr-multicluster-operator`; testing only), CNV, and OADP present;
no odf-dr, MirrorPeer, or ODF StorageSystem; regionaldr with `ramen.infrastructureEnabled` creates DRClusters, a single `2m-novm` DRPolicy (no `2m-vm`), and upserts hub
s3StoreProfiles only (`ensureBuckets: false`; no DRPC/VMs); opp-policy injects `caCertificates` only; `byoc: true`.

`drpartner-minimal` expectations after sync: same preview RHDR catalog/IDMS/subscription and partner operators/plumbing without **vp-s4-storage** or Submariner (`submariner.enabled: false` in opp-policy); regionaldr with both
`ramen.resourcesEnabled` and `ramen.infrastructureEnabled` false (no DRPolicy, DRClusters, validation, or S3 profile/bucket work); `byoc: true`.

### Secrets for `drpartner-s4` (`values-secret`)

Copy [`values-secret.yaml.template`](values-secret.yaml.template) to `values-secret.yaml` (gitignored) and load secrets before/with install. In addition to the shared pattern secrets (`aws`, `openshiftPullSecret`, `vm-ssh`, `cloud-init`), **`drpartner-s4` requires two Vault secrets** for hub **vp-s4-storage**. Paths must match the chart overrides in `variants/drpartner-s4/values-drpartner-s4.yaml` (`s4UICredentials.vaultKey` / `s4APICredentials.vaultKey`).

| Vault secret | Keys | Purpose |
|--------------|------|---------|
| `global/s4-ui-credentials` | `UI_USERNAME`, `UI_PASSWORD` | S4 Web UI login |
| `global/s4-api-credentials` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | S3 API identity for S4, bucket Jobs, and Ramen profiles |

Defaults in the template use `s4admin` for the UI user and access key ID; password and secret key can be generated (`onMissingValue: generate` + `advancedPolicy`). External Secrets merges both Vault entries into Kubernetes Secret `s4-credentials` in `vp-s4-storage`.

`drpartner-minimal` does not deploy **vp-s4-storage** and does not need these two secrets.
