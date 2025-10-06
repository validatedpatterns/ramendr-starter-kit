#!/bin/bash

# Test script to validate CA extraction approach
# This script simulates what the dynamic policies will do

set -euo pipefail

echo "Testing dynamic CA extraction approach..."
echo "========================================"

# Function to test managed cluster discovery
test_managed_cluster_discovery() {
    echo "1. Testing managed cluster discovery..."
    
    if oc get managedclusters >/dev/null 2>&1; then
        MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        echo "   ✓ Found managed clusters: $MANAGED_CLUSTERS"
        return 0
    else
        echo "   ✗ No managed clusters found or ACM not available"
        return 1
    fi
}

# Function to test hub cluster CA extraction
test_hub_ca_extraction() {
    echo "2. Testing hub cluster CA extraction..."
    
    if oc get configmap -n openshift-config-managed trusted-ca-bundle >/dev/null 2>&1; then
        echo "   ✓ Hub cluster CA bundle ConfigMap exists"
        
        # Test extraction
        if oc get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" >/dev/null 2>&1; then
            echo "   ✓ Hub cluster CA extraction successful"
            return 0
        else
            echo "   ✗ Hub cluster CA extraction failed"
            return 1
        fi
    else
        echo "   ✗ Hub cluster CA bundle ConfigMap not found"
        return 1
    fi
}

# Function to test ManagedClusterInfo CA extraction
test_managedclusterinfo_ca_extraction() {
    echo "3. Testing ManagedClusterInfo CA extraction..."
    
    local clusters_found=0
    local ca_extracted=0
    
    if oc get managedclusters >/dev/null 2>&1; then
        MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        for cluster in $MANAGED_CLUSTERS; do
            if [[ "$cluster" == "local-cluster" ]]; then
                continue
            fi
            
            ((clusters_found++))
            echo "   Checking cluster: $cluster"
            
            if oc get managedclusterinfo -n "$cluster" >/dev/null 2>&1; then
                local ca_data
                ca_data=$(oc get managedclusterinfo -n "$cluster" -o jsonpath='{.items[0].spec.loggingCA}' 2>/dev/null || echo "")
                
                if [[ -n "$ca_data" && "$ca_data" != "null" ]]; then
                    echo "     ✓ CA found in ManagedClusterInfo for $cluster"
                    ((ca_extracted++))
                else
                    echo "     ✗ No CA data in ManagedClusterInfo for $cluster"
                fi
            else
                echo "     ✗ ManagedClusterInfo not found for $cluster"
            fi
        done
        
        echo "   Summary: $ca_extracted/$clusters_found clusters have CA data in ManagedClusterInfo"
        return 0
    else
        echo "   ✗ No managed clusters found"
        return 1
    fi
}

# Function to test cluster secret CA extraction
test_cluster_secret_ca_extraction() {
    echo "4. Testing cluster secret CA extraction..."
    
    local clusters_found=0
    local ca_extracted=0
    
    if oc get managedclusters >/dev/null 2>&1; then
        MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        for cluster in $MANAGED_CLUSTERS; do
            if [[ "$cluster" == "local-cluster" ]]; then
                continue
            fi
            
            ((clusters_found++))
            echo "   Checking secrets for cluster: $cluster"
            
            # Check for import secret
            if oc get secret -n "$cluster" -o jsonpath='{.items[?(@.metadata.name=="'$cluster'-import")].data.ca\.crt}' 2>/dev/null | base64 -d >/dev/null 2>&1; then
                echo "     ✓ CA found in import secret for $cluster"
                ((ca_extracted++))
                continue
            fi
            
            # Check for bootstrap secret
            if oc get secret -n "$cluster" -o jsonpath='{.items[?(@.metadata.name=="'$cluster'-bootstrap")].data.ca\.crt}' 2>/dev/null | base64 -d >/dev/null 2>&1; then
                echo "     ✓ CA found in bootstrap secret for $cluster"
                ((ca_extracted++))
                continue
            fi
            
            # Check for TLS secrets
            if oc get secret -n "$cluster" -o jsonpath='{.items[?(@.type=="kubernetes.io/tls")].data.ca\.crt}' 2>/dev/null | base64 -d >/dev/null 2>&1; then
                echo "     ✓ CA found in TLS secret for $cluster"
                ((ca_extracted++))
                continue
            fi
            
            echo "     ✗ No CA found in secrets for $cluster"
        done
        
        echo "   Summary: $ca_extracted/$clusters_found clusters have CA data in secrets"
        return 0
    else
        echo "   ✗ No managed clusters found"
        return 1
    fi
}

# Function to test RBAC permissions
test_rbac_permissions() {
    echo "5. Testing RBAC permissions..."
    
    # Test if we can access managed clusters
    if oc auth can-i get managedclusters >/dev/null 2>&1; then
        echo "   ✓ Can access managedclusters"
    else
        echo "   ✗ Cannot access managedclusters"
        return 1
    fi
    
    # Test if we can access managedclusterinfos
    if oc auth can-i get managedclusterinfos >/dev/null 2>&1; then
        echo "   ✓ Can access managedclusterinfos"
    else
        echo "   ✗ Cannot access managedclusterinfos"
        return 1
    fi
    
    # Test if we can access secrets
    if oc auth can-i get secrets >/dev/null 2>&1; then
        echo "   ✓ Can access secrets"
    else
        echo "   ✗ Cannot access secrets"
        return 1
    fi
    
    # Test if we can access configmaps
    if oc auth can-i get configmaps >/dev/null 2>&1; then
        echo "   ✓ Can access configmaps"
    else
        echo "   ✗ Cannot access configmaps"
        return 1
    fi
    
    return 0
}

# Function to test proxy configuration
test_proxy_configuration() {
    echo "6. Testing proxy configuration..."
    
    if oc get proxy cluster >/dev/null 2>&1; then
        echo "   ✓ Cluster proxy resource exists"
        
        local current_trusted_ca
        current_trusted_ca=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
        
        if [[ -n "$current_trusted_ca" ]]; then
            echo "   ✓ Current trusted CA: $current_trusted_ca"
        else
            echo "   ⚠ No trusted CA currently configured"
        fi
        
        return 0
    else
        echo "   ✗ Cluster proxy resource not found"
        return 1
    fi
}

# Main test execution
main() {
    echo "Starting CA extraction validation tests..."
    echo ""
    
    local tests_passed=0
    local total_tests=6
    
    test_managed_cluster_discovery && ((tests_passed++))
    echo ""
    
    test_hub_ca_extraction && ((tests_passed++))
    echo ""
    
    test_managedclusterinfo_ca_extraction && ((tests_passed++))
    echo ""
    
    test_cluster_secret_ca_extraction && ((tests_passed++))
    echo ""
    
    test_rbac_permissions && ((tests_passed++))
    echo ""
    
    test_proxy_configuration && ((tests_passed++))
    echo ""
    
    echo "========================================"
    echo "Test Results: $tests_passed/$total_tests tests passed"
    
    if [[ $tests_passed -eq $total_tests ]]; then
        echo "✓ All tests passed! The dynamic CA extraction approach should work."
        exit 0
    else
        echo "✗ Some tests failed. Please check the issues above."
        exit 1
    fi
}

# Show usage if help requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "This script tests the dynamic CA extraction approach by validating:"
    echo "1. Managed cluster discovery"
    echo "2. Hub cluster CA extraction"
    echo "3. ManagedClusterInfo CA extraction"
    echo "4. Cluster secret CA extraction"
    echo "5. RBAC permissions"
    echo "6. Proxy configuration"
    echo ""
    echo "Options:"
    echo "  --help, -h    Show this help message"
    exit 0
fi

# Run main function
main
