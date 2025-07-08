#!/bin/bash
# Unified Test Runner - Consolidates all test functionality
# Usage: ./test-runner.sh [--suite <suite>] [--list] [--help]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/test/configs"

# Test state
TEST_DIR=""
TEST_NAME=""
TEST_PROVIDER=""
CLEANUP_COMMANDS=()

# Test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
FAILED_TEST_NAMES=()

# Available test suites
AVAILABLE_SUITES="framework minimal services languages cli lifecycle"

# Parse command line arguments
SUITE_FILTER=""
LIST_SUITES=false
PROVIDER="docker"
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)
            SUITE_FILTER="$2"
            shift 2
            ;;
        --list)
            LIST_SUITES=true
            shift
            ;;
        --provider)
            PROVIDER="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --suite <suite>      Run specific test suite"
            echo "  --list              List available test suites"
            echo "  --provider <type>   Test provider (docker|vagrant) [default: docker]"
            echo "  --verbose           Enable verbose output"
            echo ""
            echo "Available test suites:"
            for suite in $AVAILABLE_SUITES; do
                echo "  $suite"
            done
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# List available suites
if [ "$LIST_SUITES" = true ]; then
    echo "Available test suites:"
    for suite in $AVAILABLE_SUITES; do
        echo "  $suite"
    done
    exit 0
fi

# ============================================================================
# Test Framework Helper Functions
# ============================================================================

# Initialize test environment
setup_test_env() {
    local test_name="$1"
    local provider="${2:-docker}"
    
    TEST_NAME="$test_name"
    TEST_PROVIDER="$provider"
    TEST_DIR="/workspace/.test_artifacts/vm-test-${test_name}-$$"
    
    # Ensure test runs directory exists
    mkdir -p "/workspace/.test_artifacts"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Register cleanup
    trap cleanup_test_env EXIT
    
    echo -e "${BLUE}Setting up test: $test_name (provider: $provider)${NC}"
}

# Cleanup test environment
cleanup_test_env() {
    echo -e "${BLUE}Cleaning up test environment...${NC}"
    
    # Run any registered cleanup commands
    for cmd in "${CLEANUP_COMMANDS[@]}"; do
        eval "$cmd" 2>/dev/null || true
    done
    
    # Destroy VM if it exists
    if [ -f "$TEST_DIR/vm.json" ]; then
        cd "$TEST_DIR"
        # Destroy VM without sudo
        vm destroy -f 2>/dev/null || true
        
        # Extract project name and ensure container is removed
        local project_name=$(jq -r '.project.name' vm.json 2>/dev/null | tr -cd '[:alnum:]')
        if [ -n "$project_name" ]; then
            local container_name="${project_name}-dev"
            # Force stop and remove container with both docker and sudo docker
            docker stop "$container_name" 2>/dev/null || sudo docker stop "$container_name" 2>/dev/null || true
            docker rm "$container_name" 2>/dev/null || sudo docker rm "$container_name" 2>/dev/null || true
        fi
    fi
    
    # Remove test directory
    rm -rf "$TEST_DIR"
}

# Register a cleanup command
register_cleanup() {
    CLEANUP_COMMANDS+=("$1")
}

# Create a test VM with given config
create_test_vm() {
    local config_path="$1"
    local timeout="${2:-600}"  # 10 minute default timeout
    
    echo -e "${BLUE}Creating test VM with config: $config_path${NC}"
    
    # Copy config to test directory
    if [ -f "$config_path" ]; then
        cp "$config_path" "$TEST_DIR/vm.json"
    else
        echo -e "${RED}Config file not found: $config_path${NC}"
        return 1
    fi
    
    # Pre-emptively clean up any existing container with the same name
    local project_name=$(jq -r '.project.name' "$TEST_DIR/vm.json" 2>/dev/null | tr -cd '[:alnum:]')
    if [ -n "$project_name" ]; then
        local container_name="${project_name}-dev"
        echo -e "${BLUE}Cleaning up any existing container: $container_name${NC}"
        docker stop "$container_name" 2>/dev/null || sudo docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || sudo docker rm "$container_name" 2>/dev/null || true
    fi
    
    # Start VM with timeout
    cd "$TEST_DIR"
    # Try without sudo first since docker-compose is now available
    cd /workspace && npm link && cd "$TEST_DIR" && timeout "$timeout" vm up || {
        echo -e "${RED}Failed to create VM within ${timeout}s${NC}"
        return 1
    }
    
    # Give VM a moment to stabilize
    sleep 5
    
    # Verify VM is running
    assert_vm_running
}

# Run command in VM
run_in_vm() {
    local command="$1"
    local expected_exit="${2:-0}"
    
    cd "$TEST_DIR"
    # Execute command in VM
    vm exec "$command"
    local exit_code=$?
    
    if [ "$expected_exit" != "any" ] && [ $exit_code -ne $expected_exit ]; then
        echo -e "${RED}Command failed with exit code $exit_code (expected $expected_exit): $command${NC}"
        return 1
    fi
    
    return $exit_code
}

# Get output from VM command
get_vm_output() {
    local command="$1"
    cd "$TEST_DIR"
    vm exec "$command" 2>/dev/null
}

# Check if VM is running
is_vm_running() {
    cd "$TEST_DIR"
    # Check VM status directly
    vm status 2>/dev/null | grep -q "running"
}

# Assert VM is running
assert_vm_running() {
    if is_vm_running; then
        echo -e "${GREEN}✓ VM is running${NC}"
        return 0
    else
        echo -e "${RED}✗ VM is not running${NC}"
        return 1
    fi
}

# Assert VM is stopped
assert_vm_stopped() {
    if ! is_vm_running; then
        echo -e "${GREEN}✓ VM is stopped${NC}"
        return 0
    else
        echo -e "${RED}✗ VM is still running${NC}"
        return 1
    fi
}

# Assert command succeeds
assert_command_succeeds() {
    local command="$1"
    local description="${2:-Command should succeed}"
    
    if run_in_vm "$command" 0; then
        echo -e "${GREEN}✓ $description${NC}"
        return 0
    else
        echo -e "${RED}✗ $description${NC}"
        return 1
    fi
}

# Assert command fails
assert_command_fails() {
    local command="$1"
    local description="${2:-Command should fail}"
    
    if run_in_vm "$command" any; then
        if [ $? -ne 0 ]; then
            echo -e "${GREEN}✓ $description${NC}"
            return 0
        fi
    fi
    
    echo -e "${RED}✗ $description (command succeeded unexpectedly)${NC}"
    return 1
}

# Assert file exists in VM
assert_file_exists() {
    local file="$1"
    local description="${2:-File should exist: $file}"
    
    if run_in_vm "test -f $file" 0; then
        echo -e "${GREEN}✓ $description${NC}"
        return 0
    else
        echo -e "${RED}✗ $description${NC}"
        return 1
    fi
}

# Assert file does not exist in VM
assert_file_not_exists() {
    local file="$1"
    local description="${2:-File should not exist: $file}"
    
    if run_in_vm "test -f $file" any && [ $? -ne 0 ]; then
        echo -e "${GREEN}✓ $description${NC}"
        return 0
    else
        echo -e "${RED}✗ $description${NC}"
        return 1
    fi
}

# Assert output contains string
assert_output_contains() {
    local command="$1"
    local expected="$2"
    local description="${3:-Output should contain: $expected}"
    
    local output=$(get_vm_output "$command")
    if echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}✓ $description${NC}"
        return 0
    else
        echo -e "${RED}✗ $description${NC}"
        echo "  Output: $output"
        return 1
    fi
}

# Assert output does not contain string
assert_output_not_contains() {
    local command="$1"
    local unexpected="$2"
    local description="${3:-Output should not contain: $unexpected}"
    
    local output=$(get_vm_output "$command")
    if echo "$output" | grep -q "$unexpected"; then
        echo -e "${RED}✗ $description${NC}"
        echo "  Output: $output"
        return 1
    else
        echo -e "${GREEN}✓ $description${NC}"
        return 0
    fi
}

# Assert service is enabled
assert_service_enabled() {
    local service="$1"
    local description="${2:-Service should be enabled: $service}"
    
    case "$service" in
        postgresql)
            assert_command_succeeds "which psql" "$description"
            ;;
        redis)
            assert_command_succeeds "which redis-cli" "$description"
            ;;
        mongodb)
            assert_command_succeeds "which mongosh" "$description"
            ;;
        docker)
            assert_command_succeeds "which docker" "$description"
            ;;
        *)
            echo -e "${YELLOW}⚠ Unknown service: $service${NC}"
            return 1
            ;;
    esac
}

# Assert service is not enabled
assert_service_not_enabled() {
    local service="$1"
    local description="${2:-Service should not be enabled: $service}"
    
    case "$service" in
        postgresql)
            assert_command_fails "which psql" "$description"
            ;;
        redis)
            assert_command_fails "which redis-cli" "$description"
            ;;
        mongodb)
            assert_command_fails "which mongosh" "$description"
            ;;
        docker)
            assert_command_fails "which docker" "$description"
            ;;
        *)
            echo -e "${YELLOW}⚠ Unknown service: $service${NC}"
            return 1
            ;;
    esac
}

# Run a test and track results
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    echo -e "\n${BLUE}Running test: $test_name${NC}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # Run test in a subshell to isolate failures
    if (
        set -e
        setup_test_env "${test_name}" "$PROVIDER"
        $test_function
    ); then
        echo -e "${GREEN}✓ Test passed: $test_name${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}✗ Test failed: $test_name${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
}

# Generate a test report
generate_test_report() {
    local passed=$1
    local failed=$2
    local total=$((passed + failed))
    
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Total tests: $total"
    echo -e "${GREEN}Passed: $passed${NC}"
    echo -e "${RED}Failed: $failed${NC}"
    
    if [ $failed -eq 0 ]; then
        echo -e "\n${GREEN}✓ All tests passed!${NC}"
        return 0
    else
        echo -e "\n${RED}✗ Some tests failed${NC}"
        return 1
    fi
}

# Generate test configurations
generate_all_configs() {
    echo "Generating test configurations..."
    
    # Create configs directory
    mkdir -p "$CONFIG_DIR"
    
    # Generate minimal config
    cat > "$CONFIG_DIR/minimal.json" << EOF
{
  "project": {
    "name": "test-minimal",
    "hostname": "dev.minimal.local",
    "workspace_path": "/workspace"
  },
  "provider": "docker",
  "terminal": {
    "emoji": "🧪",
    "username": "test-dev"
  },
  "services": {},
  "aliases": {}
}
EOF
    
    # Generate service configs
    for service in postgresql redis mongodb docker; do
        cat > "$CONFIG_DIR/$service.json" << EOF
{
  "project": {
    "name": "test-$service",
    "hostname": "dev.$service.local",
    "workspace_path": "/workspace"
  },
  "provider": "docker",
  "terminal": {
    "emoji": "🧪",
    "username": "test-dev"
  },
  "services": {
    "$service": {
      "enabled": true
    }
  },
  "aliases": {}
}
EOF
    done
    
    echo "✓ Test configurations generated"
}

# ============================================================================
# Test Suite: Framework Tests
# ============================================================================

# Test configuration generator
test_config_generator() {
    echo "Testing configuration generator..."
    
    # Test that configs directory exists
    if [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${RED}✗ Config directory not found: $CONFIG_DIR${NC}"
        return 1
    fi
    
    # Test minimal config exists and is valid
    if [ -f "$CONFIG_DIR/minimal.json" ]; then
        echo -e "${GREEN}✓ Minimal config exists${NC}"
        
        # Validate it has correct structure
        local project_name=$(jq -r '.project.name' "$CONFIG_DIR/minimal.json")
        if [ "$project_name" = "test-minimal" ]; then
            echo -e "${GREEN}✓ Config has correct project name${NC}"
        else
            echo -e "${RED}✗ Config has wrong project name: $project_name${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ Minimal config not found${NC}"
        return 1
    fi
    
    # Test service configs exist
    for service in postgresql redis mongodb docker; do
        if [ -f "$CONFIG_DIR/$service.json" ]; then
            local enabled=$(jq -r ".services.$service.enabled" "$CONFIG_DIR/$service.json")
            if [ "$enabled" = "true" ]; then
                echo -e "${GREEN}✓ $service config is valid${NC}"
            else
                echo -e "${RED}✗ $service not enabled in config${NC}"
                return 1
            fi
        else
            echo -e "${RED}✗ $service config not found${NC}"
            return 1
        fi
    done
}

# Test vm.sh availability
test_vm_command() {
    echo "Testing vm.sh availability..."
    
    if [ -f "/workspace/vm.sh" ]; then
        echo -e "${GREEN}✓ vm.sh exists${NC}"
        
        # Test vm.sh is executable
        if [ -x "/workspace/vm.sh" ]; then
            echo -e "${GREEN}✓ vm.sh is executable${NC}"
        else
            echo -e "${RED}✗ vm.sh is not executable${NC}"
            return 1
        fi
        
        # Test vm init command exists
        /workspace/vm.sh help 2>&1 | grep -q "init"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ vm init command is available${NC}"
        else
            echo -e "${RED}✗ vm init command not found in help${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ vm.sh not found${NC}"
        return 1
    fi
}

# Test validation functionality
test_validation() {
    echo "Testing configuration validation..."
    
    # Create a test directory
    local test_dir="/tmp/vm-validation-test-$$"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Test with no config
    /workspace/vm.sh validate 2>&1 | grep -q "No vm.json"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Validation detects missing config${NC}"
    else
        echo -e "${RED}✗ Validation should detect missing config${NC}"
        cd - > /dev/null
        rm -rf "$test_dir"
        return 1
    fi
    
    # Test with valid config
    cp /workspace/vm.json "$test_dir/"
    /workspace/vm.sh validate
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Validation passes with valid config${NC}"
    else
        echo -e "${RED}✗ Validation failed with valid config${NC}"
        cd - > /dev/null
        rm -rf "$test_dir"
        return 1
    fi
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$test_dir"
}

# Test all generated configs are valid
test_generated_configs_valid() {
    echo "Testing all generated configurations are valid..."
    
    # Validate each generated config
    local failed=0
    
    for config in $(find "$CONFIG_DIR" -name "*.json" -type f); do
        echo -n "Validating $(basename "$config")... "
        
        # Create temp dir for validation
        local temp_dir="/tmp/validate-$$"
        mkdir -p "$temp_dir"
        cp "$config" "$temp_dir/vm.json"
        
        cd "$temp_dir"
        if /workspace/vm.sh validate > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            failed=$((failed + 1))
        fi
        
        cd - > /dev/null
        rm -rf "$temp_dir"
    done
    
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ All generated configs are valid${NC}"
        return 0
    else
        echo -e "${RED}✗ $failed configs failed validation${NC}"
        return 1
    fi
}

# ============================================================================
# Test Suite: Minimal Configuration
# ============================================================================

# Test that VM boots with minimal config
test_minimal_boot() {
    echo "Testing VM boot with minimal configuration..."
    
    # Create VM with minimal config - with shorter timeout for debugging
    create_test_vm "$CONFIG_DIR/minimal.json" 180 || return 1
    
    # If we get here, the VM started successfully
    echo -e "${GREEN}✓ VM created successfully${NC}"
    
    # Basic checks - but let's simplify to avoid more recursion
    cd "$TEST_DIR"
    if vm status 2>&1 | grep -q -E "(running|up|started)"; then
        echo -e "${GREEN}✓ VM is running${NC}"
    else
        echo -e "${YELLOW}⚠ VM status unclear, but creation succeeded${NC}"
    fi
}

# Test basic functionality without services
test_minimal_functionality() {
    echo "Testing basic functionality..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    # Check basic commands work
    assert_command_succeeds "ls -la" "List files"
    assert_command_succeeds "cd /tmp && pwd" "Change directory"
    assert_command_succeeds "echo 'test' > /tmp/testfile" "Write file"
    assert_command_succeeds "cat /tmp/testfile" "Read file"
    
    # Check workspace is mounted
    assert_command_succeeds "ls /workspace" "Workspace mounted"
    assert_file_exists "/workspace/vm.sh" "VM tool available in workspace"
}

# Test that no services are installed
test_no_services_installed() {
    echo "Testing that no services are installed..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    # Check services are NOT installed
    assert_service_not_enabled "postgresql" "PostgreSQL should not be installed"
    assert_service_not_enabled "redis" "Redis should not be installed"
    assert_service_not_enabled "mongodb" "MongoDB should not be installed"
    assert_service_not_enabled "docker" "Docker should not be installed"
    
    # Check no extra packages
    assert_command_fails "which prettier" "Prettier should not be installed"
    assert_command_fails "which eslint" "ESLint should not be installed"
    assert_command_fails "which cargo" "Rust should not be installed"
}

# ============================================================================
# Test Suite: Service Configuration
# ============================================================================

# Test PostgreSQL service
test_postgresql_service() {
    echo "Testing PostgreSQL service..."
    
    create_test_vm "$CONFIG_DIR/postgresql.json" || return 1
    
    # Check PostgreSQL is installed and running
    assert_service_enabled "postgresql" "PostgreSQL should be installed"
    assert_command_succeeds "sudo systemctl status postgresql" "PostgreSQL service should be running"
    
    # Test database connectivity
    assert_command_succeeds "sudo -u postgres psql -c 'SELECT version();'" "PostgreSQL should be accessible"
}

# Test Redis service
test_redis_service() {
    echo "Testing Redis service..."
    
    create_test_vm "$CONFIG_DIR/redis.json" || return 1
    
    # Check Redis is installed and running
    assert_service_enabled "redis" "Redis should be installed"
    assert_command_succeeds "sudo systemctl status redis" "Redis service should be running"
    
    # Test Redis connectivity
    assert_command_succeeds "redis-cli ping" "Redis should respond to ping"
}

# Test MongoDB service
test_mongodb_service() {
    echo "Testing MongoDB service..."
    
    create_test_vm "$CONFIG_DIR/mongodb.json" || return 1
    
    # Check MongoDB is installed and running
    assert_service_enabled "mongodb" "MongoDB should be installed"
    assert_command_succeeds "sudo systemctl status mongod" "MongoDB service should be running"
    
    # Test MongoDB connectivity
    assert_command_succeeds "mongosh --eval 'db.runCommand({connectionStatus: 1})'" "MongoDB should be accessible"
}

# Test Docker service
test_docker_service() {
    echo "Testing Docker service..."
    
    create_test_vm "$CONFIG_DIR/docker.json" || return 1
    
    # Check Docker is installed and running
    assert_service_enabled "docker" "Docker should be installed"
    assert_command_succeeds "sudo systemctl status docker" "Docker service should be running"
    
    # Test Docker functionality
    assert_command_succeeds "sudo docker run --rm hello-world" "Docker should run containers"
}

# ============================================================================
# Test Suite: CLI Command Tests
# ============================================================================

# Test vm init command
test_vm_init() {
    echo "Testing vm init command..."
    
    # Setup test directory
    local init_dir="$TEST_DIR/init-test"
    mkdir -p "$init_dir"
    cd "$init_dir"
    
    # Run vm init
    vm init
    local exit_code=$?
    
    # Check exit code
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}✗ vm init failed with exit code $exit_code${NC}"
        return 1
    fi
    
    # Check vm.json was created
    if [ ! -f "vm.json" ]; then
        echo -e "${RED}✗ vm.json was not created${NC}"
        return 1
    fi
    
    # Check content is customized
    local project_name=$(jq -r '.project.name' vm.json)
    if [ "$project_name" != "init-test" ]; then
        echo -e "${RED}✗ Project name not customized (got: $project_name)${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ vm init creates customized config${NC}"
    
    # Test init with existing file
    vm init 2>&1 | grep -q "already exists"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ vm init prevents overwriting existing config${NC}"
    else
        echo -e "${RED}✗ vm init should prevent overwriting${NC}"
        return 1
    fi
}

# Test vm validate command
test_vm_validate() {
    echo "Testing vm validate command..."
    
    # Test with valid config
    cd "$TEST_DIR"
    cp "$CONFIG_DIR/minimal.json" vm.json
    
    vm validate
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ vm validate succeeds with valid config${NC}"
    else
        echo -e "${RED}✗ vm validate failed with valid config${NC}"
        return 1
    fi
    
    # Test with invalid config
    echo '{"invalid": "config"}' > vm.json
    vm validate 2>&1 | grep -q -E "(error|invalid|failed)"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ vm validate detects invalid config${NC}"
    else
        echo -e "${RED}✗ vm validate should detect invalid config${NC}"
        return 1
    fi
    
    # Test with missing config
    rm -f vm.json
    vm validate 2>&1 | grep -q "No vm.json"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ vm validate reports missing config${NC}"
    else
        echo -e "${RED}✗ vm validate should report missing config${NC}"
        return 1
    fi
}

# Test vm status command
test_vm_status() {
    echo "Testing vm status command..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    # Check status when running
    cd "$TEST_DIR"
    local status_output=$(vm status 2>&1)
    
    if echo "$status_output" | grep -q "running"; then
        echo -e "${GREEN}✓ vm status shows running state${NC}"
    else
        echo -e "${RED}✗ vm status should show running state${NC}"
        echo "Output: $status_output"
        return 1
    fi
    
    # Halt VM
    vm halt || return 1
    sleep 5
    
    # Check status when stopped
    status_output=$(vm status 2>&1)
    if echo "$status_output" | grep -q -E "(stopped|poweroff|halted)"; then
        echo -e "${GREEN}✓ vm status shows stopped state${NC}"
    else
        echo -e "${RED}✗ vm status should show stopped state${NC}"
        echo "Output: $status_output"
        return 1
    fi
}

# Test vm exec command
test_vm_exec() {
    echo "Testing vm exec command..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    cd "$TEST_DIR"
    
    # Test simple command
    local output=$(vm exec "echo hello" 2>&1)
    if echo "$output" | grep -q "hello"; then
        echo -e "${GREEN}✓ vm exec runs commands${NC}"
    else
        echo -e "${RED}✗ vm exec should run commands${NC}"
        echo "Output: $output"
        return 1
    fi
    
    # Test command with exit code
    vm exec "exit 0"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ vm exec preserves exit codes${NC}"
    else
        echo -e "${RED}✗ vm exec should preserve exit codes${NC}"
        return 1
    fi
}

# ============================================================================
# Test Suite: VM Lifecycle Tests
# ============================================================================

# Test VM creation and destruction
test_vm_lifecycle() {
    echo "Testing VM lifecycle..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    cd "$TEST_DIR"
    
    # Test VM is running
    assert_vm_running
    
    # Test we can execute commands
    assert_command_succeeds "echo 'lifecycle test'" "Execute command in running VM"
    
    # Test VM halt
    vm halt || return 1
    sleep 5
    assert_vm_stopped
    
    # Test VM restart
    vm up || return 1
    sleep 5
    assert_vm_running
    
    # Test VM destroy
    vm destroy -f || return 1
    
    # Check VM is gone
    vm status 2>&1 | grep -q -E "(not created|not found|no such)"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ VM destroyed successfully${NC}"
    else
        echo -e "${RED}✗ VM should be destroyed${NC}"
        return 1
    fi
}

# Test VM reload
test_vm_reload() {
    echo "Testing VM reload..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    cd "$TEST_DIR"
    
    # Create a test file in VM
    vm exec "echo 'before reload' > /tmp/reload-test"
    
    # Modify config (add an alias)
    jq '.aliases.testreload = "echo reload-success"' vm.json > vm.json.tmp
    mv vm.json.tmp vm.json
    
    # Reload VM
    vm reload || return 1
    sleep 10  # Give time for provisioning
    
    # Check VM is still running
    assert_vm_running
    
    # Check new alias is available
    vm exec "source ~/.zshrc && type testreload" 2>&1 | grep -q "alias"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ vm reload applies config changes${NC}"
    else
        echo -e "${RED}✗ vm reload should apply config changes${NC}"
        return 1
    fi
}

# ============================================================================
# Test Suite: Language Support Tests
# ============================================================================

# Test Node.js support
test_nodejs_support() {
    echo "Testing Node.js support..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    # Check Node.js is installed
    assert_command_succeeds "source ~/.zshrc && node --version" "Node.js should be available"
    assert_command_succeeds "source ~/.zshrc && npm --version" "npm should be available"
    
    # Test basic Node.js functionality
    assert_command_succeeds "source ~/.zshrc && node -e 'console.log(\"Hello Node.js\")'" "Node.js should execute code"
}

# Test Python support
test_python_support() {
    echo "Testing Python support..."
    
    create_test_vm "$CONFIG_DIR/minimal.json" || return 1
    
    # Check Python is installed
    assert_command_succeeds "python3 --version" "Python3 should be available"
    assert_command_succeeds "pip3 --version" "pip3 should be available"
    
    # Test basic Python functionality
    assert_command_succeeds "python3 -c 'print(\"Hello Python\")'" "Python should execute code"
}

# ============================================================================
# Main Test Runner
# ============================================================================

# Check prerequisites
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"
    
    # Check for vm command
    if ! command -v vm &> /dev/null; then
        # Try using the local vm.sh
        if [ -f "/workspace/vm.sh" ]; then
            export PATH="/workspace:$PATH"
        else
            echo -e "${RED}❌ vm command not found${NC}"
            exit 1
        fi
    fi
    
    # Check for required tools
    local required_tools=(jq timeout)
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${RED}❌ Required tool not found: $tool${NC}"
            exit 1
        fi
    done
    
    # Skip provider checks for framework tests
    if [[ "$SUITE_FILTER" =~ framework ]]; then
        echo -e "${YELLOW}⚠ Skipping provider checks for framework tests${NC}"
        return 0
    fi
    
    # Check provider availability
    case "$PROVIDER" in
        docker)
            if ! command -v docker &> /dev/null; then
                echo -e "${RED}❌ Docker not installed${NC}"
                exit 1
            fi
            # Check if user has Docker permissions
            if ! docker version &>/dev/null 2>&1; then
                if groups | grep -q docker; then
                    echo -e "${YELLOW}⚠ Docker socket permissions issue (in docker group but access denied)${NC}"
                    echo -e "${YELLOW}  This may be due to docker socket group mismatch${NC}"
                    echo -e "${YELLOW}  Some tests may fail due to permission issues${NC}"
                else
                    echo -e "${YELLOW}⚠ Docker requires sudo (user not in docker group)${NC}"
                    echo -e "${YELLOW}  To fix: sudo usermod -aG docker \$USER && newgrp docker${NC}"
                    echo -e "${YELLOW}  Some tests may fail due to permission issues${NC}"
                fi
            else
                echo -e "${GREEN}✓ Docker access works without sudo${NC}"
            fi
            ;;
        vagrant)
            if ! command -v vagrant &> /dev/null; then
                echo -e "${RED}❌ Vagrant not installed${NC}"
                exit 1
            fi
            ;;
    esac
    
    echo -e "${GREEN}✓ All prerequisites met${NC}"
}

# Run test suite
run_test_suite() {
    local suite_name="$1"
    
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Running Test Suite: $suite_name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    case "$suite_name" in
        framework)
            run_test "config-generator" test_config_generator
            run_test "vm-command" test_vm_command
            run_test "validation" test_validation
            run_test "generated-configs-valid" test_generated_configs_valid
            ;;
        minimal)
            run_test "minimal-boot" test_minimal_boot
            run_test "minimal-functionality" test_minimal_functionality
            run_test "no-services-installed" test_no_services_installed
            ;;
        services)
            run_test "postgresql-service" test_postgresql_service
            run_test "redis-service" test_redis_service
            run_test "mongodb-service" test_mongodb_service
            run_test "docker-service" test_docker_service
            ;;
        languages)
            run_test "nodejs-support" test_nodejs_support
            run_test "python-support" test_python_support
            ;;
        cli)
            run_test "vm-init" test_vm_init
            run_test "vm-validate" test_vm_validate
            run_test "vm-status" test_vm_status
            run_test "vm-exec" test_vm_exec
            ;;
        lifecycle)
            run_test "vm-lifecycle" test_vm_lifecycle
            run_test "vm-reload" test_vm_reload
            ;;
        *)
            echo -e "${RED}Unknown test suite: $suite_name${NC}"
            return 1
            ;;
    esac
}

# Main execution
main() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}VM Test Runner${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Testing provider: $PROVIDER"
    echo "Test suite: ${SUITE_FILTER:-all}"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Generate test configurations
    echo -e "\n${BLUE}Generating test configurations...${NC}"
    generate_all_configs
    
    # Make vm.sh available as 'vm' command
    export PATH="/workspace:$PATH"
    
    # Run test suites
    if [ -n "$SUITE_FILTER" ]; then
        # Run specific test suite
        if [[ " $AVAILABLE_SUITES " =~ " $SUITE_FILTER " ]]; then
            run_test_suite "$SUITE_FILTER"
        else
            echo -e "${RED}Unknown test suite: $SUITE_FILTER${NC}"
            echo "Available suites: $AVAILABLE_SUITES"
            exit 1
        fi
    else
        # Run all test suites
        for suite in $AVAILABLE_SUITES; do
            run_test_suite "$suite"
        done
    fi
    
    # Generate final report
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    generate_test_report $PASSED_TESTS $FAILED_TESTS
    
    # Show failed tests if any
    if [ ${#FAILED_TEST_NAMES[@]} -gt 0 ]; then
        echo -e "\n${RED}Failed tests:${NC}"
        for test_name in "${FAILED_TEST_NAMES[@]}"; do
            echo -e "  ${RED}✗ $test_name${NC}"
        done
    fi
    
    # Exit with appropriate code
    [ $FAILED_TESTS -eq 0 ]
}

# Run main function
main