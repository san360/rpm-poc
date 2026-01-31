# RPM Repository POC - Quick Start Guide

## Step-by-Step Testing Instructions

This guide walks you through the complete process of setting up and testing the Azure Blob Storage RPM repository with **Azure AD authentication**.

---

## Prerequisites

### 1. Install Required Tools

```bash
# Update system
sudo apt-get update

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Install RPM build tools (Debian/Ubuntu)
# Note: rpmbuild is included in the 'rpm' package
sudo apt-get install -y rpm createrepo-c

# Verify installations
az --version
rpmbuild --version
```

### 2. Login to Azure

```bash
az login
az account list --output table
az account set --subscription "YOUR_SUBSCRIPTION_NAME_OR_ID"
```

---

## Phase 1: Infrastructure Deployment

### Step 1.1: Create Azure Storage Account

```bash
cd /mnt/c/dev/rpm-poc

# Make scripts executable
chmod +x scripts/*.sh

# Create storage account with RBAC (Azure AD authentication)
./scripts/create-azure-storage.sh \
  --resource-group rg-rpm-poc \
  --location eastus
```

The script will:
- Create a resource group (if needed)
- Create a storage account with a unique name
- Create a blob container
- Assign **Storage Blob Data Contributor** role to your user
- Generate a `.env.generated` file with configuration

### Step 1.2: Verify Storage Account

After the script completes, you'll see output like:

```
==============================================
Storage Account Details
==============================================
Resource Group:    rg-rpm-poc
Storage Account:   rpmrepopoc37333
Container:         rpm-repo
Location:          eastus

Blob Endpoint:     https://rpmrepopoc37333.blob.core.windows.net
Repository URL:    https://rpmrepopoc37333.blob.core.windows.net/rpm-repo

Authentication:    Azure AD (RBAC)
Required Role:     Storage Blob Data Reader (for clients)
                   Storage Blob Data Contributor (for uploads)
```

### Step 1.3: Load Environment

```bash
# Source the generated environment file
source .env.generated

# Verify
echo "Storage Account: $AZURE_STORAGE_ACCOUNT"
```

---

## Phase 2: Build RPM Packages

### Step 2.1: Build All Packages

```bash
# Build hello-azure and dnf-plugin-azure-auth
./scripts/build-rpm-local.sh all
```

**Expected Output:**
```
[INFO] Setting up RPM build environment...
[INFO] Copying source files to build environment...
[SUCCESS] Build environment ready

[INFO] Building RPM from: specs/hello-azure.spec
[SUCCESS] Built: hello-azure-1.0.0-1.noarch.rpm

[INFO] Building RPM from: specs/dnf-plugin-azure-auth.spec
[SUCCESS] Built: dnf-plugin-azure-auth-0.1.0-1.noarch.rpm

[INFO] Creating repository metadata...
[SUCCESS] Repository metadata created

Package Summary:
  hello-azure-1.0.0-1.noarch.rpm
  dnf-plugin-azure-auth-0.1.0-1.noarch.rpm
```

### Step 2.2: Verify Built Packages

```bash
ls -la packages/
# Should show:
# hello-azure-1.0.0-1.noarch.rpm
# dnf-plugin-azure-auth-0.1.0-1.noarch.rpm
# repodata/
```

---

## Phase 3: Upload to Azure Blob Storage

### Step 3.1: Upload Packages

```bash
# Ensure environment is loaded
source .env.generated

# Upload packages using Azure AD authentication
./scripts/upload-to-azure.sh
```

**Expected Output:**
```
[INFO] Verifying Azure AD authentication...
[SUCCESS] Azure AD authentication verified

[INFO] Uploading RPM packages from: /mnt/c/dev/rpm-poc/packages
[INFO] Uploading: hello-azure-1.0.0-1.noarch.rpm
[INFO] Uploading: dnf-plugin-azure-auth-0.1.0-1.noarch.rpm
[SUCCESS] Uploaded 2 RPM package(s)

[INFO] Updating repository metadata...
[SUCCESS] Repository metadata updated
```

### Step 3.2: Verify Upload

```bash
# List uploaded blobs (using Azure AD)
az storage blob list \
  --account-name $AZURE_STORAGE_ACCOUNT \
  --container-name $AZURE_STORAGE_CONTAINER \
  --auth-mode login \
  --output table
```

---

## Phase 4: Test Repository Access

### Step 4.1: Run Repository Tests

```bash
./scripts/test-repository.sh -s $AZURE_STORAGE_ACCOUNT -v
```

**Expected Output:**
```
==============================================
Azure Blob RPM Repository Tests
==============================================
Storage Account: rpmrepopoc37333
Container:       rpm-repo
Repo Path:       el9/x86_64

[INFO] Getting Azure AD access token...
[SUCCESS] Azure AD token obtained

--- Testing Repository Access ---
[SUCCESS] repomd.xml accessible (HTTP 200)
[SUCCESS] Found 2 RPM package(s)
[SUCCESS] Found 4 repodata file(s)

--- Security Tests ---
[SUCCESS] Anonymous access blocked (HTTP 409) - Security OK

==============================================
Test Summary
==============================================
Passed: 5
Failed: 0

[SUCCESS] All tests passed! Repository is ready for use.
```

### Step 4.2: Test with Docker (Pre-generated Token)

```bash
# Generate Azure AD token
TOKEN=$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)

# Test with Rocky Linux container
docker run --rm -it \
  -e DNF_PLUGIN_AZURE_AUTH_TOKEN="$TOKEN" \
  -v $(pwd)/packages:/packages:ro \
  rockylinux:9 bash -c "
    # Install the Azure AD auth plugin
    dnf install -y /packages/dnf-plugin-azure-auth-*.rpm
    
    # Configure the plugin
    echo '[azure-rpm-repo]' >> /etc/dnf/plugins/azure_auth.conf
    
    # Create repo file
    cat > /etc/yum.repos.d/azure.repo << 'EOF'
[azure-rpm-repo]
name=Azure Blob RPM Repository
baseurl=https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/rpm-repo/el9/x86_64
enabled=1
gpgcheck=0
EOF
    
    # Test repository
    echo '=== Refreshing Repository Cache ==='
    dnf makecache
    
    echo ''
    echo '=== Available Packages ==='
    dnf --disablerepo='*' --enablerepo='azure-rpm-repo' list available
    
    echo ''
    echo '=== Installing hello-azure ==='
    dnf install -y hello-azure
    
    echo ''
    echo '=== Running hello-azure ==='
    hello-azure --info
"
```

---

## Phase 5: End-to-End Test

Run the complete pipeline with a single command:

```bash
# Full E2E test (builds, uploads, and tests)
./scripts/e2e-test.sh -g rg-rpm-poc

# Or with existing storage account (skip storage creation)
./scripts/e2e-test.sh -s $AZURE_STORAGE_ACCOUNT --skip-storage
```

---

## Client Configuration Guide

### For RHEL/Rocky Linux/AlmaLinux VMs

```bash
# 1. Install prerequisites
sudo dnf install -y azure-cli

# 2. Install the Azure AD auth plugin from your repository
# (First time - you'll need to manually download or have another way to get it)
# Option A: Download directly with curl + token
TOKEN=$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
curl -H "Authorization: Bearer $TOKEN" -H "x-ms-version: 2022-11-02" \
  "https://STORAGE_ACCOUNT.blob.core.windows.net/rpm-repo/el9/x86_64/Packages/dnf-plugin-azure-auth-0.1.0-1.noarch.rpm" \
  -o /tmp/dnf-plugin-azure-auth.rpm
sudo dnf install -y /tmp/dnf-plugin-azure-auth.rpm

# 3. Login to Azure
az login                      # Interactive
# OR
az login --identity           # Managed Identity on Azure VMs

# 4. Configure the plugin
sudo tee -a /etc/dnf/plugins/azure_auth.conf << 'EOF'
[azure-rpm-repo]
EOF

# 5. Create repo file
sudo tee /etc/yum.repos.d/azure-rpm.repo << 'EOF'
[azure-rpm-repo]
name=Azure Blob RPM Repository
baseurl=https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/rpm-repo/el9/x86_64
enabled=1
gpgcheck=0
EOF

# 6. Test
sudo dnf makecache
sudo dnf install -y hello-azure
hello-azure --info
```

### For Azure VMs with Managed Identity

```bash
# 1. Assign Storage Blob Data Reader role to VM's Managed Identity
VM_PRINCIPAL_ID=$(az vm show -g YOUR_RG -n YOUR_VM --query identity.principalId -o tsv)
STORAGE_ACCOUNT_ID=$(az storage account show -n YOUR_STORAGE_ACCOUNT -g YOUR_RG --query id -o tsv)

az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee-object-id $VM_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope $STORAGE_ACCOUNT_ID

# 2. On the VM, login with Managed Identity
az login --identity

# 3. Configure plugin and repo as above
# 4. dnf commands will automatically use Managed Identity tokens
```

---

## Verification Checklist

| Step | Command | Expected Result |
|------|---------|-----------------|
| Azure Login | `az account show` | Shows your subscription |
| Storage Created | `az storage account show -n $AZURE_STORAGE_ACCOUNT` | Returns account details |
| RBAC Role | `az role assignment list --scope ... --query "[?roleDefinitionName=='Storage Blob Data Contributor']"` | Shows role assignment |
| Packages Built | `ls packages/*.rpm` | Shows RPM files |
| Repo Metadata | `ls packages/repodata/` | Shows repomd.xml, etc. |
| Blobs Uploaded | `az storage blob list -c $AZURE_STORAGE_CONTAINER --account-name $AZURE_STORAGE_ACCOUNT --auth-mode login` | Shows uploaded files |
| Azure AD Token | `az account get-access-token --resource https://storage.azure.com` | Returns valid token |
| Token Access | `curl -H "Authorization: Bearer $TOKEN" -H "x-ms-version: 2022-11-02" https://...repomd.xml` | Returns XML content |

---

## Troubleshooting

### Error: "AuthorizationPermissionMismatch"

```bash
# Verify role assignment
az role assignment list \
  --scope $(az storage account show -n $AZURE_STORAGE_ACCOUNT -g $AZURE_RESOURCE_GROUP --query id -o tsv) \
  --output table

# Assign Storage Blob Data Reader/Contributor if missing
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --scope $(az storage account show -n $AZURE_STORAGE_ACCOUNT -g $AZURE_RESOURCE_GROUP --query id -o tsv)
```

### Error: "Failed to get Azure AD token"

```bash
# Check Azure CLI login status
az account show

# Re-login if needed
az login

# For Managed Identity issues
az login --identity --debug
```

### Error: "403 Forbidden" when accessing blobs

```bash
# Verify the token is valid
TOKEN=$(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)
echo $TOKEN | cut -c1-50  # Should show JWT header

# Test direct access
curl -v -H "Authorization: Bearer $TOKEN" -H "x-ms-version: 2022-11-02" \
  "https://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$AZURE_STORAGE_CONTAINER/el9/x86_64/repodata/repomd.xml"
```

### Error: "repomd.xml not found"

```bash
# Check if repository metadata was uploaded
az storage blob list \
  --account-name $AZURE_STORAGE_ACCOUNT \
  --container-name $AZURE_STORAGE_CONTAINER \
  --prefix "el9/x86_64/repodata/" \
  --auth-mode login \
  --output table

# If missing, regenerate and upload
createrepo_c packages/
./scripts/upload-to-azure.sh
```

---

## Clean Up

```bash
# Delete the resource group (removes all resources)
az group delete --name rg-rpm-poc --yes --no-wait
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `scripts/create-azure-storage.sh` | Creates Azure storage with RBAC |
| `scripts/build-rpm-local.sh` | Builds RPM packages locally |
| `scripts/upload-to-azure.sh` | Uploads to Azure Blob (Azure AD) |
| `scripts/test-repository.sh` | Tests repository access |
| `scripts/e2e-test.sh` | Full pipeline test |
| `specs/hello-azure.spec` | Sample RPM spec file |
| `specs/dnf-plugin-azure-auth.spec` | Azure AD auth plugin spec |
| `sources/azure_auth.py` | DNF plugin Python source |
| `sources/azure_auth.conf` | Plugin configuration template |
| `config/azure-blob.repo.template` | Repo configuration template |

---

## Next Steps

1. **Add GPG Signing**: Sign packages for production use
2. **Multiple Architectures**: Add support for aarch64
3. **Azure DevOps Pipeline**: See [azure-pipelines.yml](azure-pipelines.yml)
4. **Private Endpoints**: For VNet-restricted access
5. **Monitoring**: Add Azure Monitor alerts for access issues
