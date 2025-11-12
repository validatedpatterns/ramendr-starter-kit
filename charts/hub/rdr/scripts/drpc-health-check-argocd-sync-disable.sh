#!/bin/bash
set -euo pipefail

echo "Starting DRPC health check and ArgoCD sync disable job..."
echo "This job will check DRPC health (Kubernetes objects and PVCs) and disable ArgoCD sync when healthy"

# Configuration from environment variables
DRPC_NAMESPACE="${DRPC_NAMESPACE:-openshift-dr-ops}"
DRPC_NAME="${DRPC_NAME:-gitops-vm-protection}"
PROTECTED_NAMESPACE="${PROTECTED_NAMESPACE:-gitops-vms}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-regional-dr}"
ARGOCD_APP_NAMESPACE="${ARGOCD_APP_NAMESPACE:-ramendr-starter-kit-hub}"
MAX_ATTEMPTS=60  # 1 hour with 1 minute intervals
SLEEP_INTERVAL=60  # 1 minute between checks

# Function to check if DRPC exists
check_drpc_exists() {
  echo "Checking if DRPC $DRPC_NAME exists in namespace $DRPC_NAMESPACE..."
  
  if ! oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" &>/dev/null; then
    echo "❌ DRPC $DRPC_NAME not found in namespace $DRPC_NAMESPACE"
    return 1
  fi
  
  echo "✅ DRPC $DRPC_NAME exists"
  return 0
}

# Function to check DRPC status conditions
check_drpc_status() {
  echo "Checking DRPC $DRPC_NAME status conditions..."
  
  # Get DRPC status
  local drpc_status=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
  
  if [[ "$drpc_status" == "[]" || -z "$drpc_status" ]]; then
    echo "❌ DRPC status conditions not available yet"
    return 1
  fi
  
  # Check for common healthy conditions
  # DRPC typically has conditions like "Available", "Ready", "Reconciled", etc.
  local available_status=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  local ready_status=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  
  # Check overall phase if available
  local phase=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  
  echo "  DRPC Phase: ${phase:-Unknown}"
  echo "  Available Status: ${available_status:-Unknown}"
  echo "  Ready Status: ${ready_status:-Unknown}"
  
  # Consider DRPC healthy if phase is "Deployed" or if Available/Ready conditions are True
  if [[ "$phase" == "Deployed" ]]; then
    echo "✅ DRPC is in Deployed phase"
    return 0
  fi
  
  if [[ "$available_status" == "True" ]] || [[ "$ready_status" == "True" ]]; then
    echo "✅ DRPC has healthy status conditions"
    return 0
  fi
  
  # If no specific conditions match, check if there are any error conditions
  local error_conditions=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions[?(@.status=="False")]}' 2>/dev/null || echo "")
  if [[ -n "$error_conditions" ]]; then
    echo "⚠️  DRPC has some False conditions, but continuing check..."
    # Don't fail immediately, continue to check other aspects
  fi
  
  echo "⚠️  DRPC status not clearly healthy, but continuing with other checks..."
  return 0  # Continue with other checks even if status is ambiguous
}

# Function to check PVC replication health from DRPC status
check_pvcs_health() {
  echo "Checking PVC replication health from DRPC status..."
  
  # Check phase for overall health
  local phase=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  
  echo "  DRPC Phase: $phase"
  
  # If phase is Deployed, assume PVCs are healthy
  if [[ "$phase" == "Deployed" ]]; then
    echo "✅ DRPC is in Deployed phase - PVC replication appears healthy"
    return 0
  fi
  
  # Get all conditions and check for PVC/Volume/Storage related ones
  local all_conditions=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || echo "")
  
  if [[ -z "$all_conditions" ]]; then
    echo "⚠️  No conditions found in DRPC status"
    return 1
  fi
  
  # Check for PVC-related conditions
  local pvc_healthy=false
  while IFS='=' read -r type status; do
    if [[ -n "$type" && -n "$status" ]]; then
      # Check if this condition is related to PVCs/Volumes/Storage
      if [[ "$type" == *"PVC"* ]] || [[ "$type" == *"Volume"* ]] || [[ "$type" == *"Storage"* ]]; then
        echo "  PVC-related condition: $type=$status"
        if [[ "$status" == "True" ]] || [[ "$status" == "Healthy" ]] || [[ "$status" == "Replicating" ]]; then
          echo "    ✅ PVC replication is healthy"
          pvc_healthy=true
        elif [[ "$status" == "False" ]] || [[ "$status" == "Unhealthy" ]] || [[ "$status" == "Failed" ]]; then
          echo "    ❌ PVC replication is not healthy"
          return 1
        fi
      fi
    fi
  done <<< "$all_conditions"
  
  # Check for overall replication conditions
  while IFS='=' read -r type status; do
    if [[ -n "$type" && -n "$status" ]]; then
      if [[ "$type" == *"Replication"* ]] || [[ "$type" == *"Replicating"* ]]; then
        echo "  Replication condition: $type=$status"
        if [[ "$status" == "True" ]] || [[ "$status" == "Healthy" ]]; then
          echo "    ✅ Replication is healthy"
          pvc_healthy=true
        fi
      fi
    fi
  done <<< "$all_conditions"
  
  # Check for error conditions
  while IFS='=' read -r type status; do
    if [[ -n "$type" && -n "$status" ]]; then
      if [[ "$status" == "False" ]] && ([[ "$type" == *"PVC"* ]] || [[ "$type" == *"Volume"* ]] || [[ "$type" == *"Storage"* ]]); then
        echo "❌ Found error condition: $type=$status"
        return 1
      fi
    fi
  done <<< "$all_conditions"
  
  if [[ "$pvc_healthy" == "true" ]] || [[ "$phase" == "Deployed" ]]; then
    echo "✅ PVC replication appears healthy based on DRPC status"
    return 0
  else
    echo "⚠️  Could not determine PVC replication health from DRPC status"
    return 1
  fi
}

# Function to check Kubernetes object replication health from DRPC status
check_k8s_objects_health() {
  echo "Checking Kubernetes object replication health from DRPC status..."
  
  # Check phase for overall health
  local phase=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  
  echo "  DRPC Phase: $phase"
  
  # If phase is Deployed, assume Kubernetes objects are healthy
  if [[ "$phase" == "Deployed" ]]; then
    echo "✅ DRPC is in Deployed phase - Kubernetes object replication appears healthy"
    return 0
  fi
  
  # Get all conditions and check for KubeObject/Object/Replication related ones
  local all_conditions=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || echo "")
  
  if [[ -z "$all_conditions" ]]; then
    echo "⚠️  No conditions found in DRPC status"
    return 1
  fi
  
  # Check for Kubernetes object-related conditions
  local kubeobject_healthy=false
  while IFS='=' read -r type status; do
    if [[ -n "$type" && -n "$status" ]]; then
      # Check if this condition is related to KubeObjects/Objects/Replication
      if [[ "$type" == *"KubeObject"* ]] || [[ "$type" == *"Object"* ]] || [[ "$type" == *"Replication"* ]] || [[ "$type" == *"Replicating"* ]] || [[ "$type" == *"Available"* ]]; then
        echo "  Kubernetes object replication condition: $type=$status"
        if [[ "$status" == "True" ]] || [[ "$status" == "Healthy" ]] || [[ "$status" == "Replicating" ]]; then
          echo "    ✅ Kubernetes object replication is healthy"
          kubeobject_healthy=true
        elif [[ "$status" == "False" ]] || [[ "$status" == "Unhealthy" ]] || [[ "$status" == "Failed" ]]; then
          echo "    ❌ Kubernetes object replication is not healthy"
          return 1
        fi
      fi
    fi
  done <<< "$all_conditions"
  
  # Check for error conditions
  while IFS='=' read -r type status; do
    if [[ -n "$type" && -n "$status" ]]; then
      if [[ "$status" == "False" ]] && ([[ "$type" == *"KubeObject"* ]] || [[ "$type" == *"Object"* ]] || [[ "$type" == *"Replication"* ]]); then
        echo "❌ Found error condition: $type=$status"
        return 1
      fi
    fi
  done <<< "$all_conditions"
  
  if [[ "$kubeobject_healthy" == "true" ]] || [[ "$phase" == "Deployed" ]]; then
    echo "✅ Kubernetes object replication appears healthy based on DRPC status"
    return 0
  else
    echo "⚠️  Could not determine Kubernetes object replication health from DRPC status"
    return 1
  fi
}

# Function to disable ArgoCD sync for the application
disable_argocd_sync() {
  echo "Disabling ArgoCD sync for application $ARGOCD_APP_NAME in namespace $ARGOCD_APP_NAMESPACE..."
  
  # Check if the Application exists in the specified namespace
  # Using applications.argoproj.io resource type explicitly
  if ! oc get applications.argoproj.io "$ARGOCD_APP_NAME" -n "$ARGOCD_APP_NAMESPACE" &>/dev/null; then
    echo "  ❌ ArgoCD Application $ARGOCD_APP_NAME not found in namespace $ARGOCD_APP_NAMESPACE"
    return 1
  fi
  
  echo "  Found ArgoCD Application $ARGOCD_APP_NAME in namespace $ARGOCD_APP_NAMESPACE"
  local app_namespace="$ARGOCD_APP_NAMESPACE"
  
  # Check current sync policy
  local current_sync_policy=$(oc get applications.argoproj.io "$ARGOCD_APP_NAME" -n "$app_namespace" -o jsonpath='{.spec.syncPolicy}' 2>/dev/null || echo "")
  
  if [[ -z "$current_sync_policy" || "$current_sync_policy" == "null" ]]; then
    echo "  Application already has no sync policy (sync is disabled)"
    return 0
  fi
  
  # Check if automated sync is enabled
  local automated_sync=$(oc get applications.argoproj.io "$ARGOCD_APP_NAME" -n "$app_namespace" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || echo "")
  
  if [[ -z "$automated_sync" || "$automated_sync" == "null" ]]; then
    echo "  ✅ ArgoCD sync is already disabled (no automated sync policy)"
    return 0
  fi
  
  # Disable automated sync by removing the automated field
  echo "  Current sync policy has automated sync enabled, disabling it..."
  
  # Patch the Application to remove automated sync
  if oc patch applications.argoproj.io "$ARGOCD_APP_NAME" -n "$app_namespace" --type=json -p='[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' 2>/dev/null; then
    echo "  ✅ Successfully disabled ArgoCD automated sync for application $ARGOCD_APP_NAME"
    return 0
  else
    # Alternative: set automated to null
    if oc patch applications.argoproj.io "$ARGOCD_APP_NAME" -n "$app_namespace" --type=merge -p='{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null; then
      echo "  ✅ Successfully disabled ArgoCD automated sync for application $ARGOCD_APP_NAME"
      return 0
    else
      echo "  ❌ Failed to disable ArgoCD sync"
      return 1
    fi
  fi
}

# Main check loop
attempt=1

while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  echo ""
  echo "=== DRPC Health Check Attempt $attempt/$MAX_ATTEMPTS ==="
  
  all_checks_passed=true
  
  # Check DRPC exists
  if ! check_drpc_exists; then
    all_checks_passed=false
  fi
  
  # Check DRPC status
  if ! check_drpc_status; then
    all_checks_passed=false
  fi
  
  # Check PVCs
  if ! check_pvcs_health; then
    all_checks_passed=false
  fi
  
  # Check Kubernetes objects
  if ! check_k8s_objects_health; then
    all_checks_passed=false
  fi
  
  if [[ "$all_checks_passed" == "true" ]]; then
    echo ""
    echo "🎉 All health checks passed! DRPC and related resources are healthy."
    echo ""
    echo "Disabling ArgoCD sync for application $ARGOCD_APP_NAME..."
    
    if disable_argocd_sync; then
      echo ""
      echo "✅ Successfully completed:"
      echo "  - DRPC health verified (Kubernetes objects and PVCs)"
      echo "  - ArgoCD sync disabled for application $ARGOCD_APP_NAME"
      exit 0
    else
      echo ""
      echo "⚠️  Health checks passed but failed to disable ArgoCD sync"
      echo "  This may be a transient issue. The job will retry on next sync."
      exit 1
    fi
  else
    echo ""
    echo "❌ Not all health checks passed. Waiting $SLEEP_INTERVAL seconds before retry..."
    sleep $SLEEP_INTERVAL
    ((attempt++))
  fi
done

echo ""
echo "❌ DRPC health check failed after $MAX_ATTEMPTS attempts"
echo "Please ensure:"
echo "1. DRPC $DRPC_NAME exists in namespace $DRPC_NAMESPACE"
echo "2. DRPC is in a healthy state (Deployed phase or Available/Ready conditions)"
echo "3. PVC replication is healthy (check DRPC status for PVC replication conditions)"
echo "4. Kubernetes object replication is healthy (check DRPC status for KubeObject replication conditions)"
echo ""
echo "Current DRPC status:"
oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o yaml 2>/dev/null || echo "  DRPC not found or not accessible"
exit 1

