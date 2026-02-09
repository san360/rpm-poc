#!/bin/bash
#===============================================================================
# Random RPM Package Generator
# Generates fun, randomly-named RPM packages for testing the repository workflow
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

# Default values
COUNT=3
DO_BUILD=false
DO_UPLOAD=false
DO_CLEANUP=false

# Word lists for generating fun package names
ANIMALS=(
    penguin dolphin falcon tiger panda koala otter fox
    wolf hawk eagle raven bear lynx moose badger
    beaver owl heron crane seal walrus jaguar panther
    gecko cobra bison osprey condor chameleon
)

COLORS=(
    crimson azure golden silver emerald cobalt amber scarlet
    violet coral jade copper bronze ivory onyx ruby
    sapphire topaz pearl obsidian
)

ADJECTIVES=(
    swift mighty cosmic stellar thunder storm lightning mystic
    ancient noble brave clever grand epic super ultra
    mega hyper turbo quantum
)

# ASCII art templates indexed by animal category
ascii_bird() {
    cat << 'ART'
      ___
     (o o)
    (  V  )
   /--m-m--\
ART
}

ascii_cat() {
    cat << 'ART'
    /\_/\
   ( o.o )
    > ^ <
   /|   |\
ART
}

ascii_fish() {
    cat << 'ART'
    ><(((('>
      ><('>
    ><(((('>
ART
}

ascii_bear() {
    cat << 'ART'
     .--.
    ( oo )
    _\  /_
   / '  ' \
ART
}

ascii_generic() {
    cat << 'ART'
   +--------+
   | ^    ^ |
   |   <>   |
   |  \__/  |
   +--------+
ART
}

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generates fun, randomly-named RPM packages for testing the repository workflow.
Each package installs a shell script with ASCII art and version info.

Options:
  -n, --count N      Number of packages to generate (default: 3)
  -c, --cleanup      Remove all previously generated random specs and RPMs
  -b, --build        Also build packages after generation
  -u, --upload       Also upload to Azure after building
  --all              Generate + build + create repo + upload
  -h, --help         Show this help message

Examples:
  $0                           # Generate 3 random packages
  $0 -n 5                     # Generate 5 random packages
  $0 -n 5 --build             # Generate 5 and build them
  $0 --all -n 5               # Generate, build, create repo, and upload
  $0 --cleanup                # Remove all generated random specs/RPMs

EOF
    exit 0
}

# Pick a random element from an array
random_element() {
    local -n arr=$1
    echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}

# Generate a unique package name
generate_name() {
    local color adjective animal name
    local attempts=0

    while true; do
        color=$(random_element COLORS)
        adjective=$(random_element ADJECTIVES)
        animal=$(random_element ANIMALS)
        name="${color}-${adjective}-${animal}"

        # Check for uniqueness against existing specs
        if [[ ! -f "$SPECS_DIR/random-${name}.spec" ]]; then
            echo "$name"
            return
        fi

        attempts=$((attempts + 1))
        if [[ $attempts -ge 50 ]]; then
            # Add a random number suffix as fallback
            echo "${name}-${RANDOM}"
            return
        fi
    done
}

# Generate a random semantic version
generate_version() {
    local major=$((RANDOM % 9 + 1))
    local minor=$((RANDOM % 10))
    local patch=$((RANDOM % 10))
    echo "${major}.${minor}.${patch}"
}

# Get ASCII art function name based on animal
get_ascii_art() {
    local animal="$1"
    case "$animal" in
        falcon|hawk|eagle|raven|owl|heron|crane|osprey|condor)
            ascii_bird ;;
        fox|tiger|jaguar|panther|lynx|panda|koala|chameleon|gecko)
            ascii_cat ;;
        dolphin|seal|walrus)
            ascii_fish ;;
        bear|moose|bison|badger|beaver|wolf)
            ascii_bear ;;
        *)
            ascii_generic ;;
    esac
}

# Title-case a word
titlecase() {
    echo "$1" | sed 's/./\U&/'
}

# Generate a spec file for a random package
generate_spec() {
    local name="$1"
    local version="$2"
    local pkg_name="random-${name}"
    local spec_file="$SPECS_DIR/${pkg_name}.spec"

    # Extract components from name
    local color adjective animal
    color=$(echo "$name" | cut -d- -f1)
    adjective=$(echo "$name" | cut -d- -f2)
    animal=$(echo "$name" | cut -d- -f3)

    local tc_color tc_adjective tc_animal
    tc_color=$(titlecase "$color")
    tc_adjective=$(titlecase "$adjective")
    tc_animal=$(titlecase "$animal")

    local display_name="${tc_color} ${tc_adjective} ${tc_animal}"
    local ascii_art
    ascii_art=$(get_ascii_art "$animal")

    cat > "$spec_file" << SPEC
# Auto-generated by generate-random-rpms.sh — do not edit manually
Name:           ${pkg_name}
Version:        ${version}
Release:        1%{?dist}
Summary:        The ${display_name} - A randomly generated test package

License:        MIT
URL:            https://github.com/example/random-rpms
BuildArch:      noarch

%description
Meet the ${display_name}!
A whimsical test package generated for RPM repository testing.
Package: ${pkg_name} v${version}

%install
mkdir -p %{buildroot}%{_bindir}

cat > %{buildroot}%{_bindir}/${pkg_name} << 'SCRIPT'
#!/bin/bash
# ${pkg_name} v${version}
# Auto-generated test package

VERSION="${version}"
DISPLAY_NAME="${display_name}"
PKG_NAME="${pkg_name}"

show_art() {
    echo ""
    echo "  ${display_name}"
    echo "  v${version}"
    echo ""
    cat << 'ART'
${ascii_art}
ART
    echo ""
    echo "  Installed from: Azure Blob Storage RPM Repository"
    echo ""
}

case "\$1" in
    --version|-v)
        echo "\${PKG_NAME} v\${VERSION}"
        ;;
    --info|-i)
        echo "Package:   \${PKG_NAME}"
        echo "Version:   \${VERSION}"
        echo "Name:      \${DISPLAY_NAME}"
        echo "Type:      Random test package"
        echo "Source:    Azure Blob Storage"
        echo "Hostname:  \$(hostname)"
        echo "OS:        \$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
        echo "Date:      \$(date)"
        ;;
    --help|-h)
        echo "Usage: \${PKG_NAME} [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --version, -v    Show version"
        echo "  --info,    -i    Show detailed info"
        echo "  --help,    -h    Show this help"
        echo ""
        echo "With no options, displays ASCII art."
        ;;
    *)
        show_art
        ;;
esac
SCRIPT

chmod +x %{buildroot}%{_bindir}/${pkg_name}

%files
%{_bindir}/${pkg_name}

%changelog
* $(date "+%a %b %d %Y") Random Generator <random@example.com> - ${version}-1
- Auto-generated random test package: ${display_name}
SPEC

    log_success "  ${pkg_name}-${version} -> specs/${pkg_name}.spec"
}

# Remove previously generated random specs and RPMs
cleanup_generated() {
    log_info "Cleaning up generated random packages..."

    local spec_count=0 rpm_count=0

    for f in "$SPECS_DIR"/random-*.spec; do
        [[ -f "$f" ]] || continue
        rm "$f"
        spec_count=$((spec_count + 1))
    done

    for f in "$PROJECT_ROOT/packages"/random-*.rpm; do
        [[ -f "$f" ]] || continue
        rm "$f"
        rpm_count=$((rpm_count + 1))
    done

    if [[ $spec_count -eq 0 && $rpm_count -eq 0 ]]; then
        log_info "No generated random packages found"
    else
        log_success "Removed $spec_count spec file(s) and $rpm_count RPM(s)"
    fi
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--count)
                COUNT="$2"
                shift 2
                ;;
            -c|--cleanup)
                DO_CLEANUP=true
                shift
                ;;
            -b|--build)
                DO_BUILD=true
                shift
                ;;
            -u|--upload)
                DO_UPLOAD=true
                shift
                ;;
            --all)
                DO_BUILD=true
                DO_UPLOAD=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

main() {
    echo ""
    echo "======================================================="
    echo "Random RPM Package Generator"
    echo "======================================================="
    echo ""

    parse_args "$@"

    # Handle cleanup
    if [[ "$DO_CLEANUP" == "true" ]]; then
        cleanup_generated
        echo ""
        if [[ "$DO_BUILD" == "true" ]]; then
            log_info "Rebuilding repository without random packages..."
            "$SCRIPT_DIR/build-rpm-local.sh" all
        fi
        return 0
    fi

    # Generate packages
    mkdir -p "$SPECS_DIR"

    log_info "Generating $COUNT random RPM package spec(s)..."
    echo ""

    local generated_names=()
    for ((i = 1; i <= COUNT; i++)); do
        local name version
        name=$(generate_name)
        version=$(generate_version)
        generate_spec "$name" "$version"
        generated_names+=("random-${name}")
    done

    echo ""
    log_success "Generated $COUNT package spec(s) in specs/"

    # Build if requested
    if [[ "$DO_BUILD" == "true" ]]; then
        echo ""
        log_info "Building all packages (including generated ones)..."
        "$SCRIPT_DIR/build-rpm-local.sh" all
    fi

    # Upload if requested
    if [[ "$DO_UPLOAD" == "true" ]]; then
        echo ""
        log_info "Uploading packages to Azure Blob Storage..."
        "$SCRIPT_DIR/upload-to-azure.sh"
    fi

    # Summary
    echo ""
    echo "======================================================="
    echo -e "${GREEN}Generation Complete${NC}"
    echo "======================================================="
    echo ""
    echo "  Generated packages:"
    for name in "${generated_names[@]}"; do
        echo "    - $name"
    done
    echo ""

    if [[ "$DO_BUILD" != "true" ]]; then
        echo "  Next steps:"
        echo "    ./scripts/build-rpm-local.sh all       # Build all packages"
        echo "    ./scripts/upload-to-azure.sh           # Upload to Azure"
        echo ""
    elif [[ "$DO_UPLOAD" != "true" ]]; then
        echo "  Next step:"
        echo "    ./scripts/upload-to-azure.sh           # Upload to Azure"
        echo ""
    fi

    echo "  Test on VM:"
    echo "    ssh azureuser@<VM_IP>"
    echo "    sudo dnf makecache"
    echo "    sudo dnf install ${generated_names[0]}"
    echo ""
    echo "  Cleanup:"
    echo "    $0 --cleanup                             # Remove generated specs"
    echo ""
    echo "======================================================="
}

main "$@"
