#!/bin/bash
# VM wrapper script for Goobits - supports both Vagrant and Docker
# Usage: ./packages/vm/vm.sh [command] [args...]

set -e

# Default port configuration
DEFAULT_POSTGRES_PORT=5432
DEFAULT_REDIS_PORT=6379
DEFAULT_MONGODB_PORT=27017

# Get the directory where this script is located (packages/vm)
# Handle both direct execution and npm link scenarios
if [ -L "$0" ]; then
	# If this is a symlink (npm link), resolve the real path
	REAL_SCRIPT="$(readlink -f "$0")"
	SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
else
	# Direct execution
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Get the current working directory (where user ran the command)
CURRENT_DIR="$(pwd)"

# Function to find vm.json by searching upward from current directory
find_vm_json() {
	local dir="$1"
	local max_levels=3  # Search up to 3 levels
	local level=0
	
	while [ "$level" -lt "$max_levels" ] && [ "$dir" != "/" ]; do
		if [ -f "$dir/vm.json" ]; then
			echo "$dir/vm.json"
			return 0
		fi
		dir="$(dirname "$dir")"
		level=$((level + 1))
	done
	
	return 1
}

# Show usage information
show_usage() {
	echo "Usage: $0 [--config PATH] [command] [args...]"
	echo ""
	echo "Options:"
	echo "  --config PATH        Use specific vm.json file"
	echo ""
	echo "Commands:"
	echo "  validate              Validate VM configuration"
	echo "  up [args]            Start VM"
	echo "  ssh [args]           SSH into VM"
	echo "  halt [args]          Stop VM"
	echo "  destroy [args]       Destroy VM"
	echo "  status [args]        Check VM status"
	echo "  reload [args]        Reload VM"
	echo "  provision [args]     Reprovision VM"
	echo "  logs [args]          View VM logs (Docker only)"
	echo "  exec [args]          Execute command in VM (Docker only)"
	echo "  kill                 Force kill VM processes"
	echo ""
	echo "Examples:"
	echo "  $0 validate                    # Check configuration"
	echo "  $0 --config ./prod.json up     # Start VM with specific config"
	echo "  $0 up                          # Start the VM (auto-find vm.json)"
	echo "  $0 ssh                         # Connect to VM"
	echo "  $0 halt                        # Stop the VM"
	echo "  $0 kill                        # Kill stuck VM processes"
	echo ""
	echo "The provider (Vagrant or Docker) is determined by the 'provider' field in vm.json"
}

# Function to kill VirtualBox processes
kill_virtualbox() {
	echo "🔄 Terminating all VirtualBox processes..."
	
	# Clean up vagrant state first
	echo "🧹 Cleaning up Vagrant state..."
	if [ -d .vagrant ]; then
		rm -rf .vagrant
	fi
	
	# Force kill VirtualBox and ALL related processes
	echo "🔪 Force killing ALL VirtualBox processes..."
	pkill -9 -f "VBoxHeadless" || true
	pkill -9 -f "VBoxSVC" || true
	pkill -9 -f "VBoxXPCOMIPCD" || true
	pkill -9 -f "VirtualBox" || true
	
	echo "⏳ Waiting for VirtualBox services to terminate..."
	sleep 3
	
	echo "✅ All VirtualBox processes terminated!"
	echo ""
	echo "ℹ️ You may now need to manually clean up in the VirtualBox application"
	echo "ℹ️ or run 'vagrant up' to start your VM again."
}

# Function to load and parse config
load_config() {
	local config_path="$1"
	# Use the unified validation script with --get-config flag
	node "$SCRIPT_DIR/validate-config.js" --get-config "$config_path"
}

# Get provider from config
get_provider() {
	local config="$1"
	echo "$config" | jq -r '.provider // "docker"'
}

# Docker helper function to reduce duplication
docker_run() {
	local action="$1"
	local config="$2"
	local project_dir="$3"
	shift 3
	
	# Extract project name once
	local project_name=$(echo "$config" | jq -r '.project.name' | tr -cd '[:alnum:]')
	local container_name="${project_name}-dev"
	
	case "$action" in
		"compose")
			cd "$project_dir"
			docker compose "$@"
			;;
		"exec")
			docker exec "${container_name}" "$@"
			;;
		"exec-it")
			docker exec -it "${container_name}" "$@"
			;;
		*)
			cd "$project_dir"
			docker compose "$action" "$@"
			;;
	esac
}

# Docker functions
docker_up() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	echo "🐳 Starting Docker environment..."
	
	# Generate docker-compose.yml
	echo "$config" > /tmp/vm-config.json
	node "$SCRIPT_DIR/providers/docker/docker-provisioning-simple.cjs" /tmp/vm-config.json "$project_dir"
	
	# Build and start containers
	docker_run "compose" "$config" "$project_dir" build
	docker_run "compose" "$config" "$project_dir" up -d "$@"
	
	# Get container name
	local project_name=$(echo "$config" | jq -r '.project.name' | tr -cd '[:alnum:]')
	local container_name="${project_name}-dev"
	
	# Copy config file to container
	docker cp /tmp/vm-config.json "${container_name}:/tmp/vm-config.json"
	
	# Copy VM tool directory to container for Ansible playbook access
	docker_run "exec" "$config" "$project_dir" mkdir -p /vm-tool
	docker cp "$SCRIPT_DIR/." "${container_name}:/vm-tool/"
	
	# Run Ansible playbook inside the container
	echo "🔧 Running Ansible provisioning..."
	docker_run "exec" "$config" "$project_dir" ansible-playbook \
		-i localhost, \
		-c local \
		/vm-tool/providers/vagrant/ansible/playbook.yml
	
	# Ensure supervisor services are started
	echo "🔄 Starting services..."
	docker_run "exec" "$config" "$project_dir" bash -c "supervisorctl reread && supervisorctl update"
	
	echo "✅ Docker environment is running and provisioned!"
	echo "Run 'vm ssh' to connect"
}

docker_ssh() {
	local config="$1"
	shift
	
	docker_run "exec-it" "$config" "" /bin/zsh
}

docker_halt() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	docker_run "stop" "$config" "$project_dir" "$@"
}

docker_destroy() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	docker_run "down" "$config" "$project_dir" -v "$@"
}

docker_status() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	docker_run "ps" "$config" "$project_dir" "$@"
}

docker_reload() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	docker_halt "$config" "$project_dir"
	docker_up "$config" "$project_dir" "$@"
}

docker_provision() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	echo "🔄 Rebuilding Docker environment..."
	docker_run "compose" "$config" "$project_dir" build --no-cache
	docker_run "compose" "$config" "$project_dir" up -d "$@"
}

docker_logs() {
	local config="$1"
	local project_dir="$2"
	shift 2
	
	docker_run "logs" "$config" "$project_dir" "$@"
}

docker_exec() {
	local config="$1"
	shift
	
	docker_run "exec" "$config" "" "$@"
}

docker_kill() {
	echo "🔄 Stopping all Docker containers for this project..."
	local config="$1"
	local project_name=$(echo "$config" | jq -r '.project.name' | tr -cd '[:alnum:]')
	
	docker stop "${project_name}-dev" 2>/dev/null || true
	docker stop "${project_name}-postgres" 2>/dev/null || true
	docker stop "${project_name}-redis" 2>/dev/null || true
	docker stop "${project_name}-mongodb" 2>/dev/null || true
	
	echo "✅ All Docker containers stopped!"
}

# Parse --config flag
CUSTOM_CONFIG=""
if [ "$1" = "--config" ]; then
	if [ -z "$2" ]; then
		echo "❌ Error: --config requires a path argument"
		show_usage
		exit 1
	fi
	CUSTOM_CONFIG="$2"
	shift 2  # Remove --config and path from arguments
fi

# Change to the VM directory for loading configs
cd "$SCRIPT_DIR"

# Handle special commands
case "${1:-}" in
	"validate")
		echo "🔍 Validating VM configuration..."
		if [ -n "$CUSTOM_CONFIG" ]; then
			# Convert relative path to absolute path
			if [[ "$CUSTOM_CONFIG" = /* ]]; then
				# Already absolute path
				FULL_CONFIG_PATH="$CUSTOM_CONFIG"
			else
				# Relative path, make it absolute from current directory
				FULL_CONFIG_PATH="$CURRENT_DIR/$CUSTOM_CONFIG"
			fi
			
			if [ -f "$FULL_CONFIG_PATH" ]; then
				echo "📍 Using custom config: $FULL_CONFIG_PATH"
				node "$SCRIPT_DIR/validate-config.js" "$FULL_CONFIG_PATH"
			else
				echo "❌ Error: Config file not found: $FULL_CONFIG_PATH"
				exit 1
			fi
		else
			# Search for vm.json in current directory and upward
			VM_JSON_PATH=$(find_vm_json "$CURRENT_DIR")
			if [ $? -eq 0 ]; then
				echo "📍 Found vm.json at: $VM_JSON_PATH"
				node "$SCRIPT_DIR/validate-config.js" "$VM_JSON_PATH"
			else
				echo "⚠️  No vm.json found, using defaults only"
				node "$SCRIPT_DIR/validate-config.js"
			fi
		fi
		;;
	"kill")
		# Load config to determine provider
		if [ -n "$CUSTOM_CONFIG" ]; then
			if [[ "$CUSTOM_CONFIG" = /* ]]; then
				FULL_CONFIG_PATH="$CUSTOM_CONFIG"
			else
				FULL_CONFIG_PATH="$CURRENT_DIR/$CUSTOM_CONFIG"
			fi
		else
			VM_JSON_PATH=$(find_vm_json "$CURRENT_DIR")
			if [ $? -eq 0 ]; then
				FULL_CONFIG_PATH="$VM_JSON_PATH"
			else
				FULL_CONFIG_PATH="$SCRIPT_DIR/vm.json"
			fi
		fi
		
		CONFIG=$(load_config "$FULL_CONFIG_PATH")
		PROVIDER=$(get_provider "$CONFIG")
		
		if [ "$PROVIDER" = "docker" ]; then
			docker_kill "$CONFIG"
		else
			kill_virtualbox
		fi
		;;
	"help"|"-h"|"--help"|"")
		show_usage
		;;
	*)
		# Determine config path
		if [ -n "$CUSTOM_CONFIG" ]; then
			if [[ "$CUSTOM_CONFIG" = /* ]]; then
				FULL_CONFIG_PATH="$CUSTOM_CONFIG"
			else
				FULL_CONFIG_PATH="$CURRENT_DIR/$CUSTOM_CONFIG"
			fi
			
			if [ ! -f "$FULL_CONFIG_PATH" ]; then
				echo "❌ Error: Config file not found: $FULL_CONFIG_PATH"
				exit 1
			fi
			echo "📍 Using custom config: $FULL_CONFIG_PATH"
			PROJECT_DIR="$(dirname "$FULL_CONFIG_PATH")"
		else
			# Search for vm.json
			VM_JSON_PATH=$(find_vm_json "$CURRENT_DIR")
			if [ $? -eq 0 ]; then
				echo "📍 Using vm.json from: $VM_JSON_PATH"
				FULL_CONFIG_PATH="$VM_JSON_PATH"
				PROJECT_DIR="$(dirname "$VM_JSON_PATH")"
			else
				echo "⚠️  No vm.json found, using defaults only"
				FULL_CONFIG_PATH="$SCRIPT_DIR/vm.json"
				PROJECT_DIR="$CURRENT_DIR"
			fi
		fi
		
		# Load config and determine provider
		CONFIG=$(load_config "$FULL_CONFIG_PATH")
		PROVIDER=$(get_provider "$CONFIG")
		
		echo "🔧 Using provider: $PROVIDER"
		
		# Route command to appropriate provider
		COMMAND="$1"
		shift
		
		if [ "$PROVIDER" = "docker" ]; then
			case "$COMMAND" in
				"up")
					docker_up "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"ssh")
					docker_ssh "$CONFIG" "$@"
					;;
				"halt")
					docker_halt "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"destroy")
					docker_destroy "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"status")
					docker_status "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"reload")
					docker_reload "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"provision")
					docker_provision "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"logs")
					docker_logs "$CONFIG" "$PROJECT_DIR" "$@"
					;;
				"exec")
					docker_exec "$CONFIG" "$@"
					;;
				*)
					echo "❌ Unknown command for Docker provider: $COMMAND"
					exit 1
					;;
			esac
		else
			# Vagrant provider
			case "$COMMAND" in
				"exec")
					# Execute command in Vagrant VM
					VAGRANT_CWD="$SCRIPT_DIR/providers/vagrant" vagrant ssh -c "$@"
					;;
				"logs")
					# Show service logs in Vagrant VM
					echo "📋 Showing service logs (Ctrl+C to stop)..."
					VAGRANT_CWD="$SCRIPT_DIR/providers/vagrant" vagrant ssh -c "sudo journalctl -u postgresql -u redis-server -u mongod -f"
					;;
				*)
					# Pass through to vagrant command
					VM_PROJECT_DIR="$PROJECT_DIR" VM_CONFIG="$FULL_CONFIG_PATH" VAGRANT_CWD="$SCRIPT_DIR/providers/vagrant" vagrant "$COMMAND" "$@"
					;;
			esac
		fi
		;;
esac