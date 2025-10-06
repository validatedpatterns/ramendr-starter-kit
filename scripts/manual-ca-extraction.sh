#!/bin/bash

# Manual CA extraction script
# This script can be run manually to extract CA certificates and create the ConfigMap

set -euo pipefail

echo "Manual CA Certificate Extraction"
echo "================================"

# Function to extract CA from a cluster
extract_ca_from_cluster() {
    local cluster_name="$1"
    local kubeconfig="$2"
    local output_file="$3"
    
    echo "Extracting CA from cluster: $cluster_name"
    
    if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
        if oc --kubeconfig="$kubeconfig" get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file" 2>/dev/null; then
            echo "✓ CA extracted from $cluster_name"
            return 0
        else
            echo "✗ Failed to extract CA from $cluster_name"
            return 1
        fi
    else
        echo "✗ Kubeconfig not found for $cluster_name: $kubeconfig"
        return 1
    fi
}

# Function to create combined CA bundle
create_combined_ca_bundle() {
    local output_file="$1"
    shift
    local ca_files=("$@")
    
    echo "Creating combined CA bundle..."
    touch "$output_file"
    
    for ca_file in "${ca_files[@]}"; do
        if [[ -f "$ca_file" && -s "$ca_file" ]]; then
            echo "Adding CA from: $ca_file"
            cat "$ca_file" >> "$output_file"
            echo "" >> "$output_file"  # Add separator
        fi
    done
    
    # Remove duplicates and empty lines
    sort "$output_file" | uniq | grep -v '^$' > "${output_file}.tmp"
    mv "${output_file}.tmp" "$output_file"
    
    echo "Combined CA bundle created: $output_file"
    echo "Bundle contains $(grep -c 'BEGIN CERTIFICATE' "$output_file" 2>/dev/null || echo "0") certificates"
}

# Function to create ConfigMap
create_configmap() {
    local ca_bundle_file="$1"
    
    echo "Creating cluster-proxy-ca-bundle ConfigMap..."
    
    if [[ -f "$ca_bundle_file" && -s "$ca_bundle_file" ]]; then
        oc create configmap cluster-proxy-ca-bundle \
            --from-file=ca-bundle.crt="$ca_bundle_file" \
            -n openshift-config \
            --dry-run=client -o yaml | oc apply -f -
        
        echo "✓ ConfigMap created successfully"
        
        # Update proxy configuration
        echo "Updating cluster proxy configuration..."
        oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"cluster-proxy-ca-bundle"}}}' || {
            echo "Warning: Could not update proxy configuration"
        }
        
        return 0
    else
        echo "✗ CA bundle file is empty or doesn't exist: $ca_bundle_file"
        return 1
    fi
}

# Main execution
main() {
    local temp_dir="/tmp/ca-extraction-$(date +%s)"
    mkdir -p "$temp_dir"
    
    echo "Using temporary directory: $temp_dir"
    echo ""
    
    # Extract hub cluster CA
    echo "1. Extracting hub cluster CA..."
    extract_ca_from_cluster "hub" "${HUB_KUBECONFIG:-}" "$temp_dir/hub-ca.crt"
    echo ""
    
    # Extract managed cluster CAs
    local ca_files=("$temp_dir/hub-ca.crt")
    local index=1
    
    while [[ -n "${!MANAGED${index}_KUBECONFIG:-}" ]]; do
        local kubeconfig_var="MANAGED${index}_KUBECONFIG"
        local kubeconfig="${!kubeconfig_var}"
        local cluster_name="managed-${index}"
        
        echo "Extracting CA from $cluster_name..."
        if extract_ca_from_cluster "$cluster_name" "$kubeconfig" "$temp_dir/${cluster_name}-ca.crt"; then
            ca_files+=("$temp_dir/${cluster_name}-ca.crt")
        fi
        echo ""
        
        ((index++))
    done
    
    # Create combined CA bundle
    echo "2. Creating combined CA bundle..."
    create_combined_ca_bundle "$temp_dir/combined-ca-bundle.crt" "${ca_files[@]}"
    echo ""
    
    # Create ConfigMap
    echo "3. Creating ConfigMap..."
    if create_configmap "$temp_dir/combined-ca-bundle.crt"; then
        echo "✓ CA extraction and configuration completed successfully"
    else
        echo "✗ Failed to create ConfigMap"
        exit 1
    fi
    
    # Cleanup
    echo ""
    echo "Cleaning up temporary files..."
    rm -rf "$temp_dir"
    
    echo ""
    echo "Manual CA extraction completed!"
    echo ""
    echo "To verify the configuration:"
    echo "  oc get configmap cluster-proxy-ca-bundle -n openshift-config"
    echo "  oc get proxy cluster -o yaml"
}

# Show usage if help requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "This script manually extracts CA certificates and creates the ConfigMap."
    echo ""
    echo "Environment variables:"
    echo "  HUB_KUBECONFIG          - Kubeconfig for hub cluster"
    echo "  MANAGED1_KUBECONFIG     - Kubeconfig for first managed cluster"
    echo "  MANAGED2_KUBECONFIG     - Kubeconfig for second managed cluster"
    echo "  ...                     - Additional managed cluster kubeconfigs"
    echo ""
    echo "Example:"
    echo "  HUB_KUBECONFIG=/path/to/hub/kubeconfig \\"
    echo "  MANAGED1_KUBECONFIG=/path/to/managed1/kubeconfig \\"
    echo "  $0"
    echo ""
    echo "Or run interactively:"
    echo "  $0 --interactive"
    exit 0
fi

# Handle interactive mode
if [[ "${1:-}" == "--interactive" ]]; then
    echo "Interactive CA extraction mode"
    echo "Please provide the kubeconfig paths:"
    echo ""
    
    read -p "Hub cluster kubeconfig path: " hub_kubeconfig
    if [[ -n "$hub_kubeconfig" && -f "$hub_kubeconfig" ]]; then
        export HUB_KUBECONFIG="$hub_kubeconfig"
    fi
    
    local index=1
    while true; do
        read -p "Managed cluster $index kubeconfig path (or press Enter to skip): " managed_kubeconfig
        if [[ -z "$managed_kubeconfig" ]]; then
            break
        fi
        if [[ -f "$managed_kubeconfig" ]]; then
            export "MANAGED${index}_KUBECONFIG"="$managed_kubeconfig"
            ((index++))
        else
            echo "File not found: $managed_kubeconfig"
        fi
    done
fi

# Run main function
main
