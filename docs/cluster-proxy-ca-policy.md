# Cluster Proxy CA Certificate Policy

This document describes the policies and scripts created to gather necessary Certificate Authority (CA) certificates from the hub cluster and managed clusters into a ConfigMap for the cluster proxy resource.

## Overview

The cluster proxy CA policy consists of three main components:

1. **Policy for CA ConfigMap Creation** (`policy-cluster-proxy-ca.yaml`)
2. **Policy for CA Extraction** (`policy-cluster-proxy-ca-extraction.yaml`) 
3. **Policy for CA Extraction Job** (`policy-cluster-proxy-ca-job.yaml`)
4. **CA Extraction Script** (`scripts/extract-cluster-cas.sh`)

## Policy Components

### 1. CA ConfigMap Policy (`policy-cluster-proxy-ca.yaml`)

This policy creates a ConfigMap named `cluster-proxy-ca-bundle` in the `openshift-config` namespace that contains the combined CA certificates from all clusters.

**Features:**
- Creates a ConfigMap with the combined CA bundle
- Supports both hub and managed cluster CA certificates
- Uses templating to include CA data from values files

### 2. CA Extraction Policy (`policy-cluster-proxy-ca-extraction.yaml`)

This policy provides a more detailed ConfigMap template with placeholders for CA certificates and instructions for manual CA extraction.

**Features:**
- Detailed template with CA extraction instructions
- Placeholder for hub cluster CA
- Support for multiple managed cluster CAs
- Comments explaining the CA extraction process

### 3. CA Extraction Job Policy (`policy-cluster-proxy-ca-job.yaml`)

This policy creates a Kubernetes Job that automatically extracts CA certificates from all clusters and updates the ConfigMap.

**Features:**
- Automated CA extraction from hub and managed clusters
- Creates the `cluster-proxy-ca-bundle` ConfigMap
- Updates the cluster proxy resource to use the CA bundle
- Includes proper RBAC permissions
- Service account and role bindings for the extraction job

### 4. CA Extraction Script (`scripts/extract-cluster-cas.sh`)

A standalone script for manually extracting CA certificates from clusters.

**Features:**
- Interactive and non-interactive modes
- Support for multiple managed clusters
- Automatic values file updates
- Environment variable configuration

## Usage

### Automatic CA Extraction (Recommended)

The policies will automatically create and run a job to extract CA certificates when deployed. This is the recommended approach as it handles the entire process automatically.

### Manual CA Extraction

If you prefer to extract CA certificates manually, you can use the provided script:

```bash
# Interactive mode
./scripts/extract-cluster-cas.sh --interactive

# Or with environment variables
HUB_KUBECONFIG=/path/to/hub/kubeconfig \
MANAGED1_KUBECONFIG=/path/to/managed1/kubeconfig \
MANAGED2_KUBECONFIG=/path/to/managed2/kubeconfig \
./scripts/extract-cluster-cas.sh
```

### Manual CA Extraction Commands

For each cluster, extract the CA certificate:

```bash
# Hub cluster
oc --kubeconfig=<hub-kubeconfig> get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > hub-ca.crt

# Managed cluster 1 (ocp-primary)
oc --kubeconfig=<primary-kubeconfig> get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > ocp-primary-ca.crt

# Managed cluster 2 (ocp-secondary)
oc --kubeconfig=<secondary-kubeconfig> get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > ocp-secondary-ca.crt
```

### Create Combined CA Bundle

```bash
# Combine all CA certificates
cat hub-ca.crt ocp-primary-ca.crt ocp-secondary-ca.crt > combined-ca-bundle.crt
```

### Create ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-proxy-ca-bundle
  namespace: openshift-config
data:
  ca-bundle.crt: |
    # Paste the content of combined-ca-bundle.crt here
```

### Update Cluster Proxy

```bash
oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"cluster-proxy-ca-bundle"}}}'
```

## Configuration

### Values File Updates

To use the CA extraction policies, you can optionally provide CA certificates in your values files:

```yaml
# In values-global.yaml
global:
  hubClusterCA: |
    -----BEGIN CERTIFICATE-----
    # Hub cluster CA certificate content
    -----END CERTIFICATE-----

# In charts/hub/rdr/values.yaml
regionalDR:
  - name: resilient
    clusters:
      primary:
        name: ocp-primary
        clusterCA: |
          -----BEGIN CERTIFICATE-----
          # Primary cluster CA certificate content
          -----END CERTIFICATE-----
      secondary:
        name: ocp-secondary
        clusterCA: |
          -----BEGIN CERTIFICATE-----
          # Secondary cluster CA certificate content
          -----END CERTIFICATE-----
```

## Verification

After the policies are applied, verify the CA bundle is working:

```bash
# Check if the ConfigMap exists
oc get configmap cluster-proxy-ca-bundle -n openshift-config

# Check the proxy configuration
oc get proxy cluster -o yaml

# Verify the CA bundle content
oc get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath="{.data['ca-bundle\.crt']}"
```

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure the service account has proper RBAC permissions
2. **CA Extraction Fails**: Verify cluster connectivity and kubeconfig validity
3. **ConfigMap Not Created**: Check the job logs for errors
4. **Proxy Not Updated**: Verify the patch command succeeded

### Debugging

```bash
# Check job status
oc get jobs -n openshift-config

# View job logs
oc logs job/extract-cluster-cas -n openshift-config

# Check service account permissions
oc auth can-i get configmaps --as=system:serviceaccount:openshift-config:ca-extractor-sa

# Verify RBAC
oc get clusterrole ca-extractor-role
oc get clusterrolebinding ca-extractor-rolebinding
```

## Security Considerations

- CA certificates are sensitive information and should be handled securely
- The ConfigMap is created in the `openshift-config` namespace which has restricted access
- RBAC permissions are minimal and only allow necessary operations
- Consider encrypting the ConfigMap at rest if your cluster supports it

## Maintenance

- CA certificates may change over time, so the extraction job should be re-run periodically
- Monitor the job completion status to ensure CA extraction is successful
- Consider setting up monitoring for the ConfigMap to detect changes
- Update the script and policies as needed for new cluster additions
