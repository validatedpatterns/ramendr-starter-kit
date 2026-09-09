# Change history for significant pattern releases

v1.3 - September 2026

* Drop the ODF-MCO `drpartner-s4` variant and rename `rhdr-s4` to `drpartner-s4`.
* `drpartner-minimal` uses the same preview RHDR catalog/IDMS/subscription.
* Patterns are now defaulted to `byoc: true`.

v1.3 - August 2026

* BYOC validation (`ansible/playbooks/validate_byoc.yml`): remove worker metal /
  OpenShift Virtualization instance-type checks; keep reachability, matching OCP
  minor version, and non-overlapping pod/service CIDR validation.
* Pattern documentation: the repository readme links to the
  [Validated Patterns docsite](https://validatedpatterns.io/patterns/ramendr-starter-kit/)
  (Getting Started, Installation Details, Architecture, Connectivity). Remove duplicate
  `docs/` content from this repository (assets and prose live in validatedpatterns/docs).
* regional-dr PostSync autosync disable: require `regionaldr-with-virt` >= 0.1.1 so
  `argocd-sync-disable` targets `pattern`-`clusterGroup.name` (Application CR NS;
  not destination `$ARGOCD_APP_NAMESPACE` / `regional-dr`) and installs hub
  Application `ignoreDifferences` on `Application/regional-dr`
  `/spec/syncPolicy/automated` (parent selfHeal cannot re-enable autosync from Git).
* Rename install variants: `hub` → `odf`, `partner` → `drpartner`.
* Split partner install: `drpartner` → `drpartner-s4`; add `drpartner-minimal`
  (no vp-s4-storage; `ramen.infrastructureEnabled: false`; `submariner.enabled: false`
  in opp-policy).
* S3 / DRCluster ownership: for `drpartner-s4`, **vp-s4-storage** creates buckets
  (`s4Role.buckets`); regionaldr upserts hub s3StoreProfiles with `ensureBuckets: false`
  and creates DRClusters (`infrastructureEnabled`). Off for `drpartner-minimal`.
  `odf` relies on MirrorPeer. opp-policy injects `caCertificates` only.
* Default `main.variant: odf` for regression control vs previous full ODF install.
* `drpartner-s4` uses opp-policy for Submariner/s3-ssl/CA (no odf-dr app); regionaldr
  with `ramen.infrastructureEnabled` for DRClusters, `2m-novm` only (no `2m-vm`), and hub
  s3StoreProfiles upsert (`ensureBuckets: false`); **vp-s4-storage** owns bucket create
  without DRPC/VMs.
* Adopt clustergroup/ACM `variants/` folder layout (`global.vpNewFolderDir`):
  * `variants/hub/` — baseline hub + `values-resilient.yaml` (full ODF spoke)
  * `variants/partner/` — partner hub + partner `values-resilient.yaml` (no ODF)
    and chart deltas (`values-regional-dr.yaml`) that disable DRPC/VM workloads;
    Submariner and s3-ssl/CA live in opp-policy (no odf-dr app)
* Declare install-time variants in `pattern-metadata.yaml` (`hub` default, `partner`).
* Prefer `main.variant` in `values-global.yaml` (requires clustergroup chart >= 0.9.57).
* Partner: Submariner, OADP, OCP-V, and ODF Multicluster Orchestrator (Ramen) without
  ODF StorageSystem, MirrorPeer, odf-dr, or Ramen DR CRs. Select with `main.variant: partner`.
* Partner leaves a commented subscription hook for an alternate (non-ODF) Ramen productization.
* Requires `regionaldr-with-virt` chart >= 0.1.0 (`ramen.resourcesEnabled` / `edgeGitopsVms.enabled`).
* Disable submariner by default on drpartner-s4 (since we expect native array replication in this case).
* Update to ODF chart v0.3 to support GCP and Azure

v1.2 - June 2026

* Move cluster CA management stuff to a new namespace (cluster-ca-mgt)
* Use productized OpenShift External Secrets operator
* Default to OCP 4.22
* Update to ACM chart v0.2.*
* Use versioned charts for opp-policy, regionaldr, and application data protection

v1.1 - April 2026

* Change submariner to use vxlan mode by default, for compatibility reasons
* Default to OCP 4.20+. The subscription for OADP requires "stable" channel not "stable-1.4".
* Numerous small changes to deal with race conditions and other potential issues
* Introduce "BYOC" (bring-your-own-cluster) as an option for cluster provisioning (thanks @darkdoc)

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release
* Updated workload deployment script to check both clusters for workload instead of just the primary, in case
a failover was in progress at the time.
* Update ACM to 2.15 and golang-external-secrets. Move to 0.2 golang-secrets chart to allow use of v1 API. This is
in prep to move to OCP 4.20 as the default.
* Change machine instance type for submariner to allow deployment on 4.20.
* rdr chart previously used hardcoded and undocumented Vault secrets. Exposed these as variables and referenced
previously documented AWS secret instead of creating a new one with the same material).
* When OCP 4.20+ support is ready, there will be a v1.1 branch to use it.
* Externalize all charts to prep for subsequent demo pattern.
* Pass values-egv-dr into edge-gitops-vms chart. It used to use a symlink when it was local.
