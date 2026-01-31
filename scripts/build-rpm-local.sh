#!/bin/bash
#===============================================================================
# Local RPM Build Script for WSL
# Builds RPM packages locally without Docker
#===============================================================================

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SPECS_DIR="$PROJECT_ROOT/specs"
SOURCES_DIR="$PROJECT_ROOT/sources"
PACKAGES_DIR="$PROJECT_ROOT/packages"
BUILD_ROOT="$HOME/rpmbuild"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check and install prerequisites
install_prerequisites() {
    log_info "Checking RPM build prerequisites..."

    # Detect package manager
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
    elif command -v apt-get &> /dev/null; then
        PKG_MGR="apt-get"
        log_info "Debian-based system detected, installing rpm tools..."
        sudo apt-get update
        # Note: rpmbuild is included in the 'rpm' package on Debian/Ubuntu
        sudo apt-get install -y rpm createrepo-c
        log_success "Prerequisites installed"
        return
    else
        log_error "No supported package manager found (dnf, yum, or apt-get)"
        exit 1
    fi

    # Install RPM build tools (RHEL/Fedora)
    local packages="rpm-build rpmdevtools createrepo_c"
    
    for pkg in $packages; do
        if ! rpm -q "$pkg" &> /dev/null; then
            log_info "Installing $pkg..."
            sudo $PKG_MGR install -y "$pkg"
        fi
    done

    log_success "Prerequisites installed"
}

# Setup RPM build environment
setup_build_env() {
    log_info "Setting up RPM build environment..."

    # Create RPM build directory structure
    rpmdev-setuptree 2>/dev/null || {
        mkdir -p "$BUILD_ROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    }

    # Copy source files to SOURCES directory
    if [[ -d "$SOURCES_DIR" ]]; then
        log_info "Copying source files to build environment..."
        cp -r "$SOURCES_DIR"/* "$BUILD_ROOT/SOURCES/" 2>/dev/null || true
    fi

    # Create packages output directory
    mkdir -p "$PACKAGES_DIR"

    log_success "Build environment ready at: $BUILD_ROOT"
}

# Build RPM from spec file
build_rpm() {
    local spec_file="$1"
    local spec_name=$(basename "$spec_file" .spec)

    log_info "Building RPM from: $spec_file"

    # Copy spec file to build directory
    cp "$spec_file" "$BUILD_ROOT/SPECS/"

    # Build the RPM
    rpmbuild -bb "$BUILD_ROOT/SPECS/$spec_name.spec"

    # Find and copy the built RPM (look for package name pattern)
    local built_rpm
    built_rpm=$(find "$BUILD_ROOT/RPMS" -name "${spec_name}*.rpm" -type f | head -1)

    if [[ -n "$built_rpm" ]]; then
        cp "$built_rpm" "$PACKAGES_DIR/"
        log_success "Built: $(basename "$built_rpm")"
        echo "$PACKAGES_DIR/$(basename "$built_rpm")"
    else
        log_error "No RPM found after build"
        return 1
    fi
}

# Build all spec files
build_all() {
    log_info "Building all spec files in: $SPECS_DIR"

    local count=0
    for spec_file in "$SPECS_DIR"/*.spec; do
        if [[ -f "$spec_file" ]]; then
            build_rpm "$spec_file" || log_warning "Failed to build: $spec_file"
            count=$((count + 1))
        fi
    done

    if [[ $count -eq 0 ]]; then
        log_warning "No spec files found in $SPECS_DIR"
    else
        log_success "Built $count RPM package(s)"
    fi

    # List all packages
    echo ""
    log_info "Packages in $PACKAGES_DIR:"
    ls -la "$PACKAGES_DIR"/*.rpm 2>/dev/null || echo "  No RPM files found"
}

# Create repository metadata
create_repo_metadata() {
    local repo_dir="${1:-$PACKAGES_DIR}"
    
    log_info "Creating repository metadata in: $repo_dir"

    if [[ ! -d "$repo_dir" ]]; then
        log_error "Directory not found: $repo_dir"
        return 1
    fi

    # Check for RPM files
    if ! ls "$repo_dir"/*.rpm &> /dev/null; then
        log_warning "No RPM files found in $repo_dir"
        return 1
    fi

    # Create repository metadata using createrepo_c
    if command -v createrepo_c &> /dev/null; then
        createrepo_c --update "$repo_dir"
    elif command -v createrepo &> /dev/null; then
        createrepo --update "$repo_dir"
    else
        log_error "createrepo or createrepo_c not found"
        return 1
    fi

    log_success "Repository metadata created"
    
    # Show repodata contents
    echo ""
    log_info "Repodata contents:"
    ls -la "$repo_dir/repodata/"
}

# Clean build artifacts
clean() {
    log_info "Cleaning build artifacts..."

    rm -rf "$BUILD_ROOT"/{BUILD,BUILDROOT}/*
    rm -f "$PACKAGES_DIR"/*.rpm

    log_success "Clean complete"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  install       Install RPM build prerequisites
  setup         Setup RPM build environment
  build [spec]  Build RPM from spec file (or all if none specified)
  repo [dir]    Create repository metadata
  clean         Clean build artifacts
  all           Install, setup, build all, and create repo metadata

Options:
  -h, --help    Show this help message

Examples:
  $0 install                    # Install prerequisites
  $0 build specs/hello-azure.spec  # Build single spec
  $0 build                      # Build all specs
  $0 repo                       # Create repo metadata in packages/
  $0 all                        # Full build pipeline

EOF
    exit 0
}

# Main function
main() {
    local command="${1:-all}"
    shift || true

    case "$command" in
        install)
            install_prerequisites
            ;;
        setup)
            setup_build_env
            ;;
        build)
            setup_build_env
            if [[ -n "${1:-}" ]]; then
                build_rpm "$1"
            else
                build_all
            fi
            ;;
        repo)
            create_repo_metadata "${1:-$PACKAGES_DIR}"
            ;;
        clean)
            clean
            ;;
        all)
            install_prerequisites
            setup_build_env
            build_all
            create_repo_metadata "$PACKAGES_DIR"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            ;;
    esac
}

main "$@"
