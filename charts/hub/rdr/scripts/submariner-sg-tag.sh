#!/bin/bash
set -euo pipefail

echo "Starting Submariner security group tagging..."

# Check if AWS CLI is available, install to user-writable location if needed
AWS_CLI_PATH="/tmp/aws-cli"
if ! command -v aws &>/dev/null; then
  echo "AWS CLI is not available. Installing to $AWS_CLI_PATH..."
  # Try to install AWS CLI v2 to a user-writable location
  if command -v curl &>/dev/null && command -v unzip &>/dev/null; then
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    # Install to user-writable location (no sudo needed)
    /tmp/aws/install -i "$AWS_CLI_PATH" -b "$AWS_CLI_PATH/bin"
    rm -rf /tmp/aws /tmp/awscliv2.zip
    # Add to PATH
    export PATH="$AWS_CLI_PATH/bin:$PATH"
  else
    echo "❌ Cannot install AWS CLI - required tools (curl, unzip) not available"
    exit 1
  fi
fi

# Verify AWS CLI is working
if ! aws --version &>/dev/null; then
  echo "❌ AWS CLI is not working"
  exit 1
fi

echo "✅ AWS CLI is available: $(aws --version 2>&1)"

# Configuration
KUBECONFIG_DIR="/tmp/kubeconfigs"
MAX_ATTEMPTS=30
SLEEP_INTERVAL=10

# Create kubeconfig directory
mkdir -p "$KUBECONFIG_DIR"

# Function to download kubeconfig for a cluster
download_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="$KUBECONFIG_DIR/${cluster}-kubeconfig.yaml"
  
  echo "Downloading kubeconfig for $cluster..."
  
  # Get the kubeconfig secret name
  local kubeconfig_secret=$(oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1)
  
  if [[ -z "$kubeconfig_secret" ]]; then
    echo "  ❌ No kubeconfig secret found for cluster $cluster"
    return 1
  fi
  
  echo "  Found kubeconfig secret: $kubeconfig_secret"
  
  # Try to get the kubeconfig data
  local kubeconfig_data=""
  kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$kubeconfig_data" ]]; then
    kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.raw-kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi
  
  if [[ -z "$kubeconfig_data" ]]; then
    echo "  ❌ Could not extract kubeconfig data for cluster $cluster"
    return 1
  fi
  
  # Write the kubeconfig to file
  echo "$kubeconfig_data" > "$kubeconfig_path"
  
  # Verify the kubeconfig is valid
  if oc --kubeconfig="$kubeconfig_path" get nodes &>/dev/null; then
    echo "  ✅ Successfully downloaded and verified kubeconfig for $cluster"
    echo "$kubeconfig_path"
    return 0
  else
    echo "  ❌ Kubeconfig for $cluster is invalid"
    return 1
  fi
}

# Function to get infrastructure name from a cluster
get_infrastructure_name() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "  Getting infrastructure name for cluster $cluster..."
  
  local infra_name=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
  
  if [[ -z "$infra_name" ]]; then
    echo "  ❌ Could not get infrastructure name for cluster $cluster"
    return 1
  fi
  
  echo "  ✅ Infrastructure name: $infra_name"
  echo "$infra_name"
  return 0
}

# Function to get AWS credentials from hub cluster
get_aws_credentials() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "  Getting AWS credentials for cluster $cluster..."
  
  # Try to get AWS credentials from the cluster's AWS creds secret in the hub cluster
  local aws_secret_name="${cluster}-cluster-aws-creds"
  local aws_access_key=""
  local aws_secret_key=""
  local aws_region=""
  
  # Get AWS access key from hub cluster (secret is in the cluster's namespace on hub)
  aws_access_key=$(oc get secret "$aws_secret_name" -n "$cluster" -o jsonpath='{.data.aws_access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$aws_access_key" ]]; then
    echo "  ❌ Could not get AWS access key from secret $aws_secret_name in namespace $cluster"
    return 1
  fi
  
  # Get AWS secret key from hub cluster
  aws_secret_key=$(oc get secret "$aws_secret_name" -n "$cluster" -o jsonpath='{.data.aws_secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$aws_secret_key" ]]; then
    echo "  ❌ Could not get AWS secret key from secret $aws_secret_name in namespace $cluster"
    return 1
  fi
  
  # Get AWS region from managed cluster's infrastructure (using managed cluster kubeconfig)
  aws_region=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || echo "")
  
  if [[ -z "$aws_region" ]]; then
    echo "  ⚠️  Could not get AWS region from infrastructure, will try to detect from cluster info"
    # Try to get region from managed cluster info on hub
    aws_region=$(oc get managedclusterinfo "$cluster" -n "$cluster" -o jsonpath='{.status.clusterClaims[?(@.name=="region.open-cluster-management.io")].value}' 2>/dev/null || echo "")
  fi
  
  if [[ -z "$aws_region" ]]; then
    echo "  ❌ Could not determine AWS region"
    return 1
  fi
  
  echo "  ✅ Successfully retrieved AWS credentials (region: $aws_region)"
  
  # Export AWS credentials
  export AWS_ACCESS_KEY_ID="$aws_access_key"
  export AWS_SECRET_ACCESS_KEY="$aws_secret_key"
  export AWS_DEFAULT_REGION="$aws_region"
  
  return 0
}

# Function to find Submariner security group
find_submariner_security_group() {
  local cluster="$1"
  local infra_name="$2"
  
  echo "  Finding Submariner security group for cluster $cluster..."
  
  # Submariner security groups are typically tagged with submariner-related tags
  # Look for security groups with submariner tags or names
  local sg_id=""
  
  # Method 1: Look for security groups tagged with submariner.io/gateway
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=tag:submariner.io/gateway,Values=true" \
              "Name=tag:Name,Values=*submariner*" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")
  
  # Method 2: Look for security groups with submariner in the name
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Name,Values=*submariner*" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "")
  fi
  
  # Method 3: Look for security groups tagged with the cluster infrastructure name and submariner
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Name,Values=${infra_name}*submariner*" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "")
  fi
  
  # Method 4: Look for security groups that are part of the cluster's VPC and have submariner-related names
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    # Get VPC ID from cluster infrastructure
    local vpc_id=$(oc --kubeconfig="$KUBECONFIG_DIR/${cluster}-kubeconfig.yaml" get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.vpc}' 2>/dev/null || echo "")
    
    if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
      sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
                  "Name=group-name,Values=*submariner*" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")
    fi
  fi
  
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    echo "  ❌ Could not find Submariner security group for cluster $cluster"
    return 1
  fi
  
  echo "  ✅ Found Submariner security group: $sg_id"
  echo "$sg_id"
  return 0
}

# Function to tag security group
tag_security_group() {
  local cluster="$1"
  local infra_name="$2"
  local sg_id="$3"
  
  echo "  Tagging security group $sg_id with kubernetes.io/cluster/${infra_name}=owned..."
  
  local tag_key="kubernetes.io/cluster/${infra_name}"
  local tag_value="owned"
  
  # Check if tag already exists
  local existing_tag=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$sg_id" \
              "Name=key,Values=$tag_key" \
    --query 'Tags[0].Value' \
    --output text 2>/dev/null || echo "")
  
  if [[ "$existing_tag" == "$tag_value" ]]; then
    echo "  ✅ Tag already exists with correct value: $tag_key=$tag_value"
    return 0
  fi
  
  # Create or update the tag
  if aws ec2 create-tags \
    --resources "$sg_id" \
    --tags "Key=$tag_key,Value=$tag_value" 2>/dev/null; then
    echo "  ✅ Successfully tagged security group $sg_id with $tag_key=$tag_value"
    return 0
  else
    echo "  ❌ Failed to tag security group $sg_id"
    return 1
  fi
}

# Main execution
echo ""
echo "Discovering managed clusters (excluding local-cluster)..."
MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[?(@.metadata.name!="local-cluster")].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$MANAGED_CLUSTERS" ]]; then
  echo "❌ No managed clusters found (excluding local-cluster)"
  exit 1
fi

echo "Found managed clusters: $MANAGED_CLUSTERS"
echo ""

SUCCESS_COUNT=0
FAILED_CLUSTERS=()

# Process each managed cluster
for cluster in $MANAGED_CLUSTERS; do
  echo "=========================================="
  echo "Processing cluster: $cluster"
  echo "=========================================="
  
  # Download kubeconfig
  kubeconfig=$(download_kubeconfig "$cluster" || echo "")
  if [[ -z "$kubeconfig" ]]; then
    echo "❌ Failed to download kubeconfig for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Get infrastructure name
  infra_name=$(get_infrastructure_name "$cluster" "$kubeconfig" || echo "")
  if [[ -z "$infra_name" ]]; then
    echo "❌ Failed to get infrastructure name for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Get AWS credentials (need kubeconfig for region detection)
  if ! get_aws_credentials "$cluster" "$kubeconfig"; then
    echo "❌ Failed to get AWS credentials for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Find Submariner security group
  sg_id=$(find_submariner_security_group "$cluster" "$infra_name" || echo "")
  if [[ -z "$sg_id" ]]; then
    echo "❌ Failed to find Submariner security group for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Tag security group
  if tag_security_group "$cluster" "$infra_name" "$sg_id"; then
    echo "✅ Successfully processed cluster $cluster"
    ((SUCCESS_COUNT++))
  else
    echo "❌ Failed to tag security group for $cluster"
    FAILED_CLUSTERS+=("$cluster")
  fi
  
  echo ""
done

# Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Successfully processed: $SUCCESS_COUNT cluster(s)"
if [[ ${#FAILED_CLUSTERS[@]} -gt 0 ]]; then
  echo "Failed clusters: ${FAILED_CLUSTERS[*]}"
  exit 1
else
  echo "✅ All clusters processed successfully"
  exit 0
fi

