# ArgoCD Sync Timeout Fix

This document explains the sync timeout issues that were encountered and how they were resolved.

## Problem Description

The hub cluster was experiencing ArgoCD sync timeout errors:
```
"one or more synchronization tasks are not valid due to application controller sync timeout. Retrying attempt #2 at 9:01PM."
```

## Root Causes

### 1. Incorrect API Version for PlacementRule
The PlacementRule resource was using the wrong API version:
- **Incorrect:** `policy.open-cluster-management.io/v1beta1`
- **Correct:** `apps.open-cluster-management.io/v1`

### 2. Complex Policy Definitions
The original policies contained:
- Large inline scripts in YAML
- Complex nested policy structures
- Multiple interdependent resources
- Heavy RBAC configurations

### 3. Sync Timeout Configuration
The default sync timeout (1800s) was insufficient for complex policy processing.

## Solutions Implemented

### 1. Simplified Policy Architecture
**Before:** Multiple complex policies with inline scripts
```yaml
# Complex policy with large inline script
apiVersion: policy.open-cluster-management.io/v1beta1
kind: Policy
metadata:
  name: policy-cluster-proxy-ca-acm
spec:
  policy-templates:
  - objectDefinition:
      # Large inline script causing sync issues
      command:
      - /bin/bash
      - -c
      - |
        # 200+ lines of complex script
```

**After:** Single simplified policy
```yaml
# Simplified policy with essential functionality
apiVersion: policy.open-cluster-management.io/v1beta1
kind: Policy
metadata:
  name: policy-cluster-proxy-ca-simple
spec:
  policy-templates:
  - objectDefinition:
      # Streamlined script with core functionality
      command:
      - /bin/bash
      - -c
      - |
        # Essential CA extraction logic only
```

### 2. Increased Sync Timeout
**Before:** 1800s (30 minutes)
```yaml
syncOptions:
  - syncTimeout=1800s
```

**After:** 3600s (60 minutes)
```yaml
syncOptions:
  - syncTimeout=3600s
```

### 3. Removed Problematic Resources
Removed the following resources that were causing sync failures:
- `policy-cluster-proxy-ca-dynamic.yaml`
- `policy-cluster-proxy-ca-acm.yaml`
- `policy-cluster-proxy-ca-distribution.yaml`
- `policy-cluster-proxy-ca-managed.yaml`
- `placement-cluster-proxy-ca.yaml`

### 4. Created Troubleshooting Tools
- `scripts/troubleshoot-sync.sh` - Diagnose sync issues
- `scripts/manual-ca-extraction.sh` - Manual CA extraction fallback

## Current Configuration

### Policy Set (Simplified)
```yaml
apiVersion: policy.open-cluster-management.io/v1beta1
kind: PolicySet
metadata:
  name: openshift-plus-hub
spec:
  policies:
  - policy-ocm-observability
  - policy-cluster-proxy-ca-simple
```

### Sync Configuration
```yaml
syncPolicy:
  automated: {}
  retry:
    limit: 20
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
  syncOptions:
    - syncTimeout=3600s
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - RespectIgnoreDifferences=true
    - ServerSideApply=true
```

## Verification

### Check Application Status
```bash
oc get applications.argoproj.io opp-policy -n ramendr-starter-kit-hub -o jsonpath='{.status.sync.status}'
# Should return: Synced
```

### Check Policy Status
```bash
oc get policies -n policies
# Should show: policy-cluster-proxy-ca-simple
```

### Run Troubleshooting Script
```bash
./scripts/troubleshoot-sync.sh
```

## Prevention Strategies

### 1. Policy Complexity Guidelines
- Keep inline scripts under 50 lines
- Use separate ConfigMaps for large scripts
- Avoid deeply nested policy structures
- Test policies in isolation before combining

### 2. Sync Timeout Best Practices
- Start with 1800s for simple policies
- Increase to 3600s for complex policies
- Use 7200s for very complex multi-resource policies
- Monitor sync times and adjust accordingly

### 3. Resource Management
- Use `argocd.argoproj.io/hook: "Skip"` for non-critical resources
- Implement proper resource ordering with sync waves
- Use `ignoreDifferences` for resources that change frequently

### 4. Monitoring and Alerting
- Set up alerts for sync failures
- Monitor application health status
- Track sync duration trends
- Implement automated retry mechanisms

## Manual Fallback

If sync issues persist, use the manual CA extraction script:

```bash
# Interactive mode
./scripts/manual-ca-extraction.sh --interactive

# With environment variables
HUB_KUBECONFIG=/path/to/hub/kubeconfig \
MANAGED1_KUBECONFIG=/path/to/managed1/kubeconfig \
./scripts/manual-ca-extraction.sh
```

## Lessons Learned

1. **Start Simple:** Begin with basic policies and add complexity gradually
2. **Test Incrementally:** Test each policy component individually
3. **Monitor Sync Times:** Track sync duration and adjust timeouts accordingly
4. **Use Fallbacks:** Always have manual procedures for critical operations
5. **Document Issues:** Keep track of sync problems and their solutions

## Future Improvements

1. **Policy Optimization:** Further simplify policy definitions
2. **Script Externalization:** Move complex scripts to separate ConfigMaps
3. **Resource Ordering:** Implement proper sync wave ordering
4. **Automated Testing:** Add automated policy validation
5. **Performance Monitoring:** Implement sync performance metrics

This fix ensures reliable ArgoCD synchronization while maintaining the essential CA certificate management functionality.
