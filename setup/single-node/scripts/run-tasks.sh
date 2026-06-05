#!/bin/bash
# Generic task runner - executes JSON task definitions
# Maintains idempotency and supports resuming from a failed task

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Show usage help
usage() {
    cat << EOF
Generic Task Runner - Execute JSON task definitions

Usage: $0 [OPTIONS]

Options:
    -i, --instance-id ID        Target EC2 instance ID (required)
    -r, --region REGION         AWS region (default: sa-east-1)
    -f, --task-file FILE        Task definition JSON file (required)
    -v, --variables JSON        Variable definitions (JSON format)
    -s, --start-from TASK_ID    Resume from the specified task ID
    --state-file FILE           Path to state file (default: /tmp/task-state-<instance-id>.json)
    --clean-state               Clear state file and run from the beginning
    --dry-run                   Display tasks without actually executing them
    -h, --help                  Show this help message

Examples:
    # Basic usage
    $0 -i i-1234567890abcdef0 -f tasks/code-server-setup.json

    # With variables
    $0 -i i-1234567890abcdef0 -f tasks/code-server-setup.json \\
       -v '{"USER":"developer","PASSWORD":"secret123"}'

    # Resume from a specific task
    $0 -i i-1234567890abcdef0 -f tasks/code-server-setup.json \\
       -s 03-install-code-server

    # Dry run (preview what will be executed)
    $0 -i i-1234567890abcdef0 -f tasks/code-server-setup.json --dry-run
EOF
}

# Default values
INSTANCE_ID=""
REGION="sa-east-1"
TASK_FILE=""
VARIABLES_JSON="{}"
START_FROM=""
STATE_FILE=""
CLEAN_STATE=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -f|--task-file)
            TASK_FILE="$2"
            shift 2
            ;;
        -v|--variables)
            VARIABLES_JSON="$2"
            shift 2
            ;;
        -s|--start-from)
            START_FROM="$2"
            shift 2
            ;;
        --state-file)
            STATE_FILE="$2"
            shift 2
            ;;
        --clean-state)
            CLEAN_STATE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

# Required parameter checks
if [[ -z "$INSTANCE_ID" ]]; then
    echo -e "${RED}Error: Instance ID is required${NC}"
    usage
    exit 1
fi

if [[ -z "$TASK_FILE" ]]; then
    echo -e "${RED}Error: Task file is required${NC}"
    usage
    exit 1
fi

if [[ ! -f "$TASK_FILE" ]]; then
    echo -e "${RED}Error: Task file not found: $TASK_FILE${NC}"
    exit 1
fi

# Set default state file path
if [[ -z "$STATE_FILE" ]]; then
    STATE_FILE="/tmp/task-state-${INSTANCE_ID}.json"
fi

# Clear state file if requested
if [[ "$CLEAN_STATE" == true ]] && [[ -f "$STATE_FILE" ]]; then
    echo -e "${YELLOW}Clearing state file: $STATE_FILE${NC}"
    rm -f "$STATE_FILE"
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}Generic Task Runner${NC}"
echo -e "${BLUE}=========================================${NC}"
echo "Instance ID:  $INSTANCE_ID"
echo "Region:       $REGION"
echo "Task file:    $TASK_FILE"
echo "State file:   $STATE_FILE"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}Mode: Dry run${NC}"
fi
echo -e "${BLUE}=========================================${NC}"
echo ""

# Export environment variables so the Python script can read them
export INSTANCE_ID
export REGION
export TASK_FILE
export VARIABLES_JSON
export START_FROM
export STATE_FILE
export DRY_RUN

# Execute tasks
python3 << 'PYTHON_EOF'
import hashlib
import json
import re
import subprocess
import sys
import time
import os
from datetime import datetime
from urllib.parse import urlparse, parse_qs

# Read parameters from environment
instance_id = os.environ.get('INSTANCE_ID')
region = os.environ.get('REGION')
task_file = os.environ.get('TASK_FILE')
variables_json = os.environ.get('VARIABLES_JSON', '{}')
start_from = os.environ.get('START_FROM', '')
state_file = os.environ.get('STATE_FILE')
dry_run = os.environ.get('DRY_RUN', 'false') == 'true'

# Color codes
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
NC = '\033[0m'

def log_info(msg):
    print(f"{BLUE}[INFO]{NC} {msg}")

def log_success(msg):
    print(f"{GREEN}[SUCCESS]{NC} {msg}")

def log_warning(msg):
    print(f"{YELLOW}[WARNING]{NC} {msg}")

def log_error(msg):
    print(f"{RED}[ERROR]{NC} {msg}")

def log_task(msg):
    print(f"{CYAN}[TASK]{NC} {msg}")

# Load task definition
log_info(f"Loading task definition: {task_file}")
with open(task_file, 'r') as f:
    task_definition = json.load(f)

# Load variables
user_variables = json.loads(variables_json)

# Merge task definition variables with user-provided ones (user values take priority)
variables = task_definition.get('variables', {})
variables.update(user_variables)

log_info(f"Task name: {task_definition.get('name', 'Unnamed')}")
log_info(f"Description: {task_definition.get('description', 'No description')}")
log_info(f"Number of tasks: {len(task_definition['tasks'])}")
print("")

# Load state file
state = {}
if os.path.exists(state_file):
    log_info(f"Loading existing state file: {state_file}")
    with open(state_file, 'r') as f:
        state = json.load(f)
    print(f"  Completed tasks: {len([t for t in state.get('tasks', {}).values() if t.get('status') == 'success'])}")
    print(f"  Failed tasks:    {len([t for t in state.get('tasks', {}).values() if t.get('status') == 'failed'])}")
    print("")

# Initialize state
if 'tasks' not in state:
    state['tasks'] = {}
if 'last_run' not in state:
    state['last_run'] = None

# Variable substitution function
def replace_variables(text, variables):
    for key, value in variables.items():
        text = text.replace(f"{{{{{key}}}}}", str(value))
    return text

# Normalise S3 presigned URLs into a content-addressed identifier so that
# fingerprints invalidate when the underlying object actually changes,
# but stay stable across re-presigns of the SAME object.
#
# Earlier versions collapsed presigned URLs to just "s3://bucket/key"; that
# was strictly safer than hashing the raw URL (which always changed thanks
# to per-request signatures + X-Amz-Date), but it also masked legitimate
# updates: a deploy that uploads a fresh tarball under the SAME key kept
# the same fingerprint and the task was incorrectly skipped. We now reach
# out to S3 once per URL we see and fold the object's ETag (typically the
# MD5, or a marker hash for multipart uploads) into the fingerprint, so:
#   - Fresh deploy with new tarball   -> ETag changes -> fingerprint flips -> task runs
#   - Re-run with same tarball        -> ETag stable  -> fingerprint stable -> task skipped
#   - Two presigned URLs to same key  -> share ETag   -> share fingerprint
# When the ETag lookup fails (network blip, transient IAM denial) we fall
# back to the URL-key-only behaviour rather than blowing up the deploy.
_S3_PRESIGN_RE = re.compile(
    r"https?://([a-z0-9.\-]+)\.s3[.\-][a-z0-9\-]+\.amazonaws\.com(/[^\s\"']*)"
)

# Cache: (bucket, key) -> etag string. Avoids re-hitting S3 once per
# command in a task list (the URL appears in many rendered commands).
_etag_cache = {}

def _s3_etag(bucket, key):
    cache_key = (bucket, key)
    if cache_key in _etag_cache:
        return _etag_cache[cache_key]
    try:
        result = subprocess.run(
            ["aws", "s3api", "head-object", "--bucket", bucket, "--key", key,
             "--query", "ETag", "--output", "text"],
            capture_output=True, text=True, timeout=20,
        )
        if result.returncode == 0:
            etag = (result.stdout or "").strip().strip('"')
        else:
            etag = ""
    except (subprocess.TimeoutExpired, FileNotFoundError):
        etag = ""
    _etag_cache[cache_key] = etag
    return etag

def _stabilise_url_match(match):
    bucket, key = match.group(1), match.group(2)
    if "?" in key:
        key = key.split("?", 1)[0]
    key = key.lstrip("/")
    etag = _s3_etag(bucket, key)
    if etag:
        return f"s3://{bucket}/{key}#etag={etag}"
    return f"s3://{bucket}/{key}"

def stabilise_for_fingerprint(text):
    return _S3_PRESIGN_RE.sub(_stabilise_url_match, text)

def task_fingerprint(replaced_commands):
    """Hash the rendered commands for cache invalidation.

    Two runs of the same task with identical variables AND the same
    underlying S3 objects hash to the same digest; uploading a new
    tarball under the same key flips the ETag and re-executes the task.
    """
    h = hashlib.sha256()
    for cmd in replaced_commands:
        h.update(stabilise_for_fingerprint(cmd).encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()

# SSM send-command execution function
def execute_task(task_id, commands):
    """Execute a task"""
    log_task(f"Executing task: {task_id}")

    # Join commands into a script
    script = '\n'.join(commands)

    if dry_run:
        print(f"{YELLOW}[DRY-RUN] Commands to be executed:{NC}")
        print("---")
        print(script)
        print("---")
        return {
            'status': 'success',
            'command_id': 'DRY-RUN',
            'output': 'Dry run - not executed'
        }

    # Save to a temporary file
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.sh') as f:
        f.write(script)
        script_file = f.name

    try:
        # Build JSON input
        params = {
            "InstanceIds": [instance_id],
            "DocumentName": "AWS-RunShellScript",
            "Parameters": {
                "commands": [script]
            }
        }

        # Run SSM send-command
        result = subprocess.run(
            ['aws', 'ssm', 'send-command', '--region', region, '--cli-input-json', json.dumps(params), '--output', 'json'],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            log_error(f"SSM send-command failed: {result.stderr}")
            return {
                'status': 'failed',
                'error': result.stderr
            }

        command_data = json.loads(result.stdout)
        command_id = command_data['Command']['CommandId']

        log_info(f"Command ID: {command_id}")
        log_info("Waiting for execution to complete...")

        # Wait for completion
        # Default 30 minutes (heavy tasks like setup-persistence require 15-20 min for apt install + EFS mount)
        # Override with env var TASK_MAX_WAIT_SECONDS (per-task override via tasks/*.json is not supported)
        max_wait = int(os.environ.get('TASK_MAX_WAIT_SECONDS', '1800'))
        wait_interval = 5
        elapsed = 0

        while elapsed < max_wait:
            time.sleep(wait_interval)
            elapsed += wait_interval

            # Check status
            status_result = subprocess.run(
                ['aws', 'ssm', 'get-command-invocation',
                 '--command-id', command_id,
                 '--instance-id', instance_id,
                 '--region', region,
                 '--output', 'json'],
                capture_output=True,
                text=True
            )

            if status_result.returncode == 0:
                invocation = json.loads(status_result.stdout)
                status = invocation.get('Status', 'Pending')

                if status == 'Success':
                    output = invocation.get('StandardOutputContent', '')
                    log_success(f"Task completed: {task_id}")
                    return {
                        'status': 'success',
                        'command_id': command_id,
                        'output': output
                    }
                elif status in ['Failed', 'Cancelled', 'TimedOut']:
                    error = invocation.get('StandardErrorContent', '')
                    log_error(f"Task failed: {task_id}")
                    print(f"Error output:\n{error}")
                    return {
                        'status': 'failed',
                        'command_id': command_id,
                        'error': error
                    }
                else:
                    print(f"  Status: {status} (elapsed: {elapsed}s)")

        log_error(f"Timeout: {task_id}")
        return {
            'status': 'failed',
            'command_id': command_id,
            'error': 'Timeout waiting for command completion'
        }

    finally:
        # Remove temporary file
        if os.path.exists(script_file):
            os.unlink(script_file)

# Execute tasks
start_execution = not start_from
total_tasks = len(task_definition['tasks'])
completed_tasks = 0
failed_tasks = 0

for idx, task in enumerate(task_definition['tasks'], 1):
    task_id = task['id']
    task_name = task.get('name', task_id)
    task_desc = task.get('description', '')

    # Skip tasks until the start task is reached
    if not start_execution:
        if task_id == start_from:
            start_execution = True
            # When --start-from is specified, reset the state of that task to force re-execution.
            # Since the intent is to re-run, clear the "completed" status (assumes idempotent tasks).
            if task_id in state['tasks']:
                state['tasks'][task_id]['status'] = 'pending-rerun'
                log_info(f"Resetting state for task '{task_id}' and re-executing")
            else:
                log_info(f"Resuming from task '{task_id}'")
        else:
            log_info(f"[{idx}/{total_tasks}] Skipping: {task_id} - {task_name}")
            continue

    # Compute the per-task fingerprint up front so we can use it in the
    # skip check below. This intentionally includes *every* rendered
    # command so changes to commands, variable values, or task ordering
    # all cause the digest to change and the task to re-execute.
    commands = task.get('commands', [])
    replaced_commands = [replace_variables(cmd, variables) for cmd in commands]
    current_fp = task_fingerprint(replaced_commands)

    # Skip tasks that have already succeeded *with the same fingerprint*.
    # Tasks reset by --start-from fall through (status was rewritten to
    # 'pending-rerun' above). Tasks whose rendered commands changed --
    # for example a new tarball URL with a different S3 key, a bumped
    # port, or a re-staged source -- fall through and execute again.
    if task_id in state['tasks'] and state['tasks'][task_id].get('status') == 'success':
        prev_fp = state['tasks'][task_id].get('fingerprint')
        if prev_fp == current_fp:
            log_success(f"[{idx}/{total_tasks}] Already completed: {task_id} - {task_name}")
            completed_tasks += 1
            continue
        else:
            log_info(
                f"[{idx}/{total_tasks}] Re-running: {task_id} - {task_name} "
                f"(fingerprint changed: {(prev_fp or 'none')[:8]}..{current_fp[:8]})"
            )

    print("")
    print(f"{CYAN}{'='*80}{NC}")
    log_task(f"[{idx}/{total_tasks}] {task_id}")
    print(f"  Name:        {task_name}")
    print(f"  Description: {task_desc}")
    print(f"{CYAN}{'='*80}{NC}")

    # Execute task
    result = execute_task(task_id, replaced_commands)

    # Update state. The fingerprint we computed above is what the next
    # run will compare against, so two consecutive successful runs with
    # identical inputs will short-circuit the second time.
    state['tasks'][task_id] = {
        'name': task_name,
        'status': result['status'],
        'timestamp': datetime.now().isoformat(),
        'command_id': result.get('command_id', ''),
        'fingerprint': current_fp,
    }

    if result['status'] == 'success':
        completed_tasks += 1
        if not dry_run and result.get('output'):
            print(f"\n{GREEN}Output:{NC}")
            print(result['output'][:500])  # Display only the first 500 characters
    else:
        failed_tasks += 1
        state['tasks'][task_id]['error'] = result.get('error', '')

    # Save state file
    state['last_run'] = datetime.now().isoformat()
    with open(state_file, 'w') as f:
        json.dump(state, f, indent=2)

    # Stop on failure
    if result['status'] == 'failed' and not dry_run:
        log_error("Stopping due to task execution failure")
        log_info(f"To resume: --start-from {task_id}")
        sys.exit(1)

# Display summary
print("")
print(f"{GREEN}{'='*80}{NC}")
print(f"{GREEN}Task execution complete{NC}")
print(f"{GREEN}{'='*80}{NC}")
print(f"Total tasks:  {total_tasks}")
print(f"Completed:    {completed_tasks}")
print(f"Failed:       {failed_tasks}")
print(f"Skipped:      {total_tasks - completed_tasks - failed_tasks}")
print(f"State file:   {state_file}")
print(f"{GREEN}{'='*80}{NC}")

if failed_tasks == 0:
    sys.exit(0)
else:
    sys.exit(1)

PYTHON_EOF

exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}✅ All tasks completed successfully${NC}"
else
    echo ""
    echo -e "${RED}❌ An error occurred during task execution${NC}"
fi

exit $exit_code
