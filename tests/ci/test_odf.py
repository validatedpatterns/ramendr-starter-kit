import pytest
import validatedpatterns_tests.interop.application as application
import validatedpatterns_tests.interop.components as components
import validatedpatterns_tests.interop.subscription as subscription

# ── DR helpers ───────────────────────────────────────────────────────────────


def _get_condition(conditions, cond_type):
    for c in conditions or []:
        if c.get("type") == cond_type:
            return c
    return None


def _condition_status(conditions, cond_type):
    c = _get_condition(conditions, cond_type)
    if c is None:
        return None
    return c.get("status") == "True"


def _list_resource(client, api_version, kind):
    resource = client.resources.get(api_version=api_version, kind=kind)
    return resource.get().items


# ── Hub subscriptions ────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_subscription_status_hub(openshift_dyn_client):
    expected_subs = {
        "openshift-gitops-operator": ["openshift-gitops-operator"],
        "advanced-cluster-management": ["open-cluster-management"],
        "multicluster-engine": ["multicluster-engine"],
        # odf-multicluster-orchestrator installs into
        # openshift-operators (cluster-wide)
        "odf-multicluster-orchestrator": ["openshift-operators"],
        # cert-manager is managed by the RH operator
        # (openshift-cert-manager-operator)
        "openshift-cert-manager-operator": ["cert-manager-operator"],
    }
    subscription.assert_subscription_status(
        openshift_dyn_client,
        expected_subs,
    )


# ── Spoke subscriptions ──────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_SPOKECONFIG", "VP_SPOKECONFIG_SECONDARY"],
    indirect=True,
)
def test_subscription_status_spoke(openshift_dyn_client):
    expected_subs = {
        "openshift-gitops-operator": ["openshift-gitops-operator"],
        "odf-operator": ["openshift-storage"],
        "kubevirt-hyperconverged": ["openshift-cnv"],
        # OADP subscription name is redhat-oadp-operator on spoke
        "redhat-oadp-operator": ["openshift-adp"],
        # Ramen DR cluster operator on spoke
        "ramen-dr-cluster-subscription": ["openshift-dr-system"],
    }
    subscription.assert_subscription_status(
        openshift_dyn_client,
        expected_subs,
    )


# ── Hub pod health ───────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_pod_status_hub(openshift_dyn_client):
    # odf-multicluster-orchestrator and ramen DR hub pods
    # live in openshift-operators (cluster-wide);
    # we check that namespace for the whole operator ecosystem
    projects = [
        "patterns-operator",
        "open-cluster-management",
        "open-cluster-management-hub",
        "cert-manager",
        "cert-manager-operator",
        "cluster-ca-mgt",
        "vault",
        "vp-gitops",
        "external-secrets",
    ]
    components.assert_pod_status(openshift_dyn_client, projects, skip_check=[])


# ── Spoke pod health ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_SPOKECONFIG", "VP_SPOKECONFIG_SECONDARY"],
    indirect=True,
)
def test_pod_status_spoke(openshift_dyn_client):
    # openshift-storage is intentionally excluded: ODF spawns
    # short-lived CronJob pods (storageclient-*-status-reporter-*)
    # that get garbage-collected between list and per-pod GET,
    # causing a spurious 404. ODF health on spokes is covered by
    # test_subscription_status_spoke and
    # test_drpc_available_and_peer_ready.
    projects = [
        "open-cluster-management-agent",
        "open-cluster-management-agent-addon",
        "openshift-cnv",
        "openshift-adp",
        "openshift-dr-system",
        "vp-gitops",
        "external-secrets",
    ]
    components.assert_pod_status(openshift_dyn_client, projects, skip_check=[])


# ── ACM ManagedCluster status ────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_managed_clusters(openshift_dyn_client):
    # Both DR clusters must be imported and available in ACM
    components.assert_managed_clusters(
        openshift_dyn_client,
        ["ocp-primary", "ocp-secondary"],
    )


# ── ArgoCD reachability ──────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG", "VP_SPOKECONFIG", "VP_SPOKECONFIG_SECONDARY"],
    indirect=True,
)
def test_argocd_reachable(openshift_dyn_client):
    components.assert_argocd_reachable(openshift_dyn_client)


# ── ArgoCD application health ────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_argocd_applications_health_hub(openshift_dyn_client):
    # vp-gitops: top-level hub app.
    # ramendr-starter-kit-odf: component apps.
    # vp-manage-proxy-cluster-ca OutOfSync: ESO schema defaults
    # (nullBytePolicy, deletionPolicy, engineVersion, mergePolicy)
    # not emitted by the chart; fixed via
    # ignoreDifferences in values-odf.yaml.
    projects = ["vp-gitops", "ramendr-starter-kit-odf"]
    application.assert_argocd_applications(openshift_dyn_client, projects)


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_SPOKECONFIG", "VP_SPOKECONFIG_SECONDARY"],
    indirect=True,
)
def test_argocd_applications_health_spoke(openshift_dyn_client):
    projects = ["vp-gitops"]
    application.assert_argocd_applications(openshift_dyn_client, projects)


# ── DR control-plane health ──────────────────────────────────────────────────


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_drpolicy_validated(openshift_dyn_client):
    """All DRPolicy objects must have Validated=True."""
    policies = _list_resource(
        openshift_dyn_client,
        api_version="ramendr.openshift.io/v1alpha1",
        kind="DRPolicy",
    )
    assert policies, "No DRPolicy objects found on hub"

    failures = []
    for p in policies:
        name = p.metadata.name
        conditions = (p.status or {}).get("conditions", [])
        if not _condition_status(conditions, "Validated"):
            c = _get_condition(conditions, "Validated")
            reason = c.get("reason", "unknown") if c else "condition missing"
            message = c.get("message", "") if c else ""
            failures.append(f"{name}: Validated != True ({reason}: {message})")

    msg = "DRPolicy validation failures:\n" + "\n".join(failures)
    assert not failures, msg


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_drcluster_available(openshift_dyn_client):
    """All DRClusters: phase=Available, Validated=True, not Fenced."""
    clusters = _list_resource(
        openshift_dyn_client,
        api_version="ramendr.openshift.io/v1alpha1",
        kind="DRCluster",
    )
    assert clusters, "No DRCluster objects found on hub"

    failures = []
    for c in clusters:
        name = c.metadata.name
        status = c.status or {}
        phase = status.get("phase", "")
        conditions = status.get("conditions", [])

        errors = []
        if phase != "Available":
            errors.append(f"phase={phase!r} (want 'Available')")
        if not _condition_status(conditions, "Validated"):
            cond = _get_condition(conditions, "Validated")
            if cond:
                reason = cond.get("reason", "condition missing")
            else:
                reason = "condition missing"
            errors.append(f"Validated != True ({reason})")
        # Fenced=True: cluster intentionally isolated for DR
        # testing; not expected in steady state
        if _condition_status(conditions, "Fenced") is True:
            errors.append("Fenced=True (cluster is fenced)")

        if errors:
            failures.append(f"{name}: " + "; ".join(errors))

    assert not failures, "DRCluster health failures:\n" + "\n".join(failures)


@pytest.mark.parametrize(
    "openshift_dyn_client",
    ["VP_HUBCONFIG"],
    indirect=True,
)
def test_drpc_available_and_peer_ready(openshift_dyn_client):
    """
    All DRPlacementControl objects must be Available=True and PeerReady=True.

    Protected may be False/Progressing during active replication and is not
    checked here — it reflects an in-flight state, not an error.
    """
    drpcs = _list_resource(
        openshift_dyn_client,
        api_version="ramendr.openshift.io/v1alpha1",
        kind="DRPlacementControl",
    )
    assert drpcs, "No DRPlacementControl objects found on hub"

    failures = []
    for d in drpcs:
        name = d.metadata.name
        namespace = d.metadata.namespace
        status = d.status or {}
        phase = status.get("phase", "")
        conditions = status.get("conditions", [])

        errors = []
        if phase not in (
            "Deployed",
            "Relocating",
            "FailingOver",
            "Relocated",
            "FailedOver",
        ):
            errors.append(f"phase={phase!r} (unexpected)")
        if not _condition_status(conditions, "Available"):
            cond = _get_condition(conditions, "Available")
            if cond:
                reason = cond.get("reason", "condition missing")
            else:
                reason = "condition missing"
            errors.append(f"Available != True ({reason})")
        if not _condition_status(conditions, "PeerReady"):
            cond = _get_condition(conditions, "PeerReady")
            if cond:
                reason = cond.get("reason", "condition missing")
            else:
                reason = "condition missing"
            errors.append(f"PeerReady != True ({reason})")

        if errors:
            failures.append(f"{namespace}/{name}: " + "; ".join(errors))

    assert not failures, "DRPC health failures:\n" + "\n".join(failures)
