#!/usr/bin/env bash

set -Eeuo pipefail

# Example: ./create-rocky9-xrdp-vm.sh --pc-host 10.55.8.7 --pc-port 9440 --pc-username admin --prism-api-version 4.3 --vm-name rocky-ws --pc-ca-cert "" --inventory-tsv-file PC-inv.tsv --cluster-name "Cluster A" --image-name "Rocky Linux 9" --storage-container-name default --subnet-name primary --userid1 rocky --userid2 rockyadmin --userid1-pw CHANGE_ME_USERID1_PASSWORD --userid2-pw CHANGE_ME_USERID2_PASSWORD --userid1-sshkey-file id_ed25519.pub --userid2-sshkey-file id_ed25519.pub --ssh-private-key-file mykey.key --vm-disk-size-gb 100 --vm-memory-size-gb 24 --vm-vcpus 2
# Replace the CHANGE_ME password examples. Command-line passwords may be visible in shell history and process listings.
# Add --insecure only when intentionally skipping Prism Central TLS certificate verification.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Defaults may be overridden with command-line options.
PC_HOST=""
PC_PORT="9440"
PC_USERNAME="admin"
PRISM_API_VERSION="4.3"
PC_CA_CERT=""
PC_TLS_INSECURE=false

VM_NAME="rocky-ws"
INVENTORY_TSV_FILE="${SCRIPT_DIR}/PC-inv.tsv"
CLUSTER_NAME=""
IMAGE_NAME=""
STORAGE_CONTAINER_NAME="default"
SUBNET_NAME="primary"

# These are the accounts and passwords rendered into cloud-init.
USERID1="rocky"
USERID2="rockyadmin"
USERID1PW=""
USERID2PW=""

# Public key files are read when this script runs. The automation SSH key
# must correspond to USERID2SSHKEY_FILE; USERID2 has passwordless sudo.
USERID1SSHKEY_FILE=""
USERID2SSHKEY_FILE=""
SSH_PRIVATE_KEY_FILE="${SCRIPT_DIR}/mykey.key"

CLOUD_CONFIG_TEMPLATE="${SCRIPT_DIR}/cloud-config-tpl.yaml"
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/hardevsanghera/xrdpOnRocky9/main/setup-rocky9-xrdp.sh"
VM_DISK_SIZE_GB=""
VM_MEMORY_SIZE_GB=""
VM_DISK_SIZE_BYTES=""
VM_MEMORY_SIZE_BYTES=""
VM_VCPUS="2"
VM_BOOT_TIMEOUT_SECONDS=3600
VM_IP_DISCOVERY_TIMEOUT_SECONDS=300
POLL_INTERVAL_SECONDS=15
SSH_CONNECT_TIMEOUT_SECONDS=8

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 --pc-host HOST --cluster-name NAME --image-name NAME
          --userid1-pw PASSWORD --userid2-pw PASSWORD
          --userid1-sshkey-file FILE --userid2-sshkey-file FILE
          --vm-disk-size-gb GB --vm-memory-size-gb GB [options]

Options:
  --pc-host HOST
  --pc-port PORT                         (default: 9440)
  --pc-username USER                     (default: admin)
  --prism-api-version VERSION            (default: 4.3; for example, 4.3)
  --vm-name NAME                         (default: rocky-ws)
  --pc-ca-cert FILE                      (default: no custom CA)
  --inventory-tsv-file FILE              (default: ${SCRIPT_DIR}/PC-inv.tsv)
  --cluster-name NAME
  --image-name NAME
  --storage-container-name NAME          (default: default)
  --subnet-name NAME                     (default: primary)
  --userid1 USER                          (default: rocky)
  --userid2 USER                          (default: rockyadmin)
  --userid1-pw PASSWORD
  --userid2-pw PASSWORD
  --userid1-sshkey-file FILE
  --userid2-sshkey-file FILE
  --ssh-private-key-file FILE            (default: ${SCRIPT_DIR}/mykey.key)
  --vm-disk-size-gb GB                    (integer; 1 GB = 1,073,741,824 bytes)
  --vm-memory-size-gb GB                  (integer; 1 GB = 1,073,741,824 bytes)
  --vm-vcpus COUNT                        (default: 2)
  --insecure                              (skip TLS verification; not recommended)
  -h, --help

Relative inventory and SSH public-key paths are resolved from the script directory.
The Prism Central password is requested interactively. Account passwords passed on
the command line may be visible in shell history and process listings.
EOF
}

resolve_script_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$SCRIPT_DIR" "$path"
    fi
}

while (($#)); do
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        exit 0
    fi
    if [[ "$1" == "--insecure" ]]; then
        PC_TLS_INSECURE=true
        shift
        continue
    fi

    if [[ "$1" == *=* ]]; then
        option="${1%%=*}"
        value="${1#*=}"
    else
        option="$1"
        (($# >= 2)) || die "${option} requires a value"
        value="$2"
        shift
    fi

    case "$option" in
        --pc-host) PC_HOST="$value" ;;
        --pc-port) PC_PORT="$value" ;;
        --pc-username) PC_USERNAME="$value" ;;
        --prism-api-version) PRISM_API_VERSION="$value" ;;
        --vm-name) VM_NAME="$value" ;;
        --pc-ca-cert) PC_CA_CERT="$value" ;;
        --inventory-tsv-file) INVENTORY_TSV_FILE="$(resolve_script_path "$value")" ;;
        --cluster-name) CLUSTER_NAME="$value" ;;
        --image-name) IMAGE_NAME="$value" ;;
        --storage-container-name) STORAGE_CONTAINER_NAME="$value" ;;
        --subnet-name) SUBNET_NAME="$value" ;;
        --userid1) USERID1="$value" ;;
        --userid2) USERID2="$value" ;;
        --userid1-pw) USERID1PW="$value" ;;
        --userid2-pw) USERID2PW="$value" ;;
        --userid1-sshkey-file) USERID1SSHKEY_FILE="$(resolve_script_path "$value")" ;;
        --userid2-sshkey-file) USERID2SSHKEY_FILE="$(resolve_script_path "$value")" ;;
        --ssh-private-key-file) SSH_PRIVATE_KEY_FILE="$(resolve_script_path "$value")" ;;
        --vm-disk-size-gb) VM_DISK_SIZE_GB="$value" ;;
        --vm-memory-size-gb) VM_MEMORY_SIZE_GB="$value" ;;
        --vm-vcpus) VM_VCPUS="$value" ;;
        *)
            usage >&2
            die "Unknown option: $option"
            ;;
    esac
    shift
done

log() {
    printf '\n==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_usable_ipv4() {
    local address="$1"
    local octet
    local -a octets

    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
    [[ "$address" != 0.* && "$address" != 127.* && "$address" != 169.254.* ]]
}

validate_username() {
    local name="$1"
    [[ "${#name}" -le 32 && "$name" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] ||
        die "Invalid Linux username: $name"
}

read_public_key() {
    local key_file="$1"
    local key_line="" key_type key_data

    [[ -r "$key_file" ]] || die "Cannot read SSH public-key file: $key_file"
    IFS= read -r key_line < "$key_file" ||
        [[ -n "$key_line" ]] ||
        die "No public key found in: $key_file"
    read -r key_type key_data _ <<< "$key_line" ||
        die "No public key found in: $key_file"
    case "$key_type" in
        ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            die "Unsupported SSH public-key type in $key_file: $key_type"
            ;;
    esac
    [[ "$key_data" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
        die "Malformed SSH public key in: $key_file"
    printf '%s %s' "$key_type" "$key_data"
}

validate_password() {
    local name="$1"
    local password="$2"
    [[ -n "$password" && "$password" != *"CHANGE_ME"* ]] ||
        die "Provide a non-placeholder value for ${name} with its command-line option"
    [[ "$password" != *:* && "$password" != *$'\n'* && "$password" != *$'\r'* ]] ||
        die "${name} must not contain colons or newline characters"
}

cluster_list_contains() {
    local remaining="$1"
    local expected="$2"
    local candidate

    while :; do
        if [[ "$remaining" == *,* ]]; then
            candidate="${remaining%%,*}"
            remaining="${remaining#*,}"
        else
            candidate="$remaining"
            remaining=""
        fi

        candidate="${candidate#"${candidate%%[![:space:]]*}"}"
        candidate="${candidate%"${candidate##*[![:space:]]}"}"
        [[ "$candidate" == "$expected" ]] && return 0
        [[ -n "$remaining" ]] || break
    done
    return 1
}

lookup_inventory_ext_id() {
    local object="$1"
    local name="$2"
    local cluster="${3:-}"
    local item row_object row_name row_ext_id row_cluster
    local match_count=0
    local matched_ext_id=""

    while IFS=$'\t' read -r item row_object row_name row_ext_id row_cluster; do
        [[ "$item" =~ ^[0-9]+$ ]] || continue
        [[ "$row_object" == "$object" && "$row_name" == "$name" ]] || continue
        if [[ "$object" != "Cluster" ]] &&
            ! cluster_list_contains "$row_cluster" "$cluster"; then
            continue
        fi
        [[ -n "$row_ext_id" ]] ||
            die "Inventory row for ${object} '${name}' has an empty ExtID"
        match_count=$((match_count + 1))
        matched_ext_id="$row_ext_id"
    done < "$INVENTORY_TSV_FILE"

    if ((match_count == 0)); then
        if [[ "$object" == "Cluster" ]]; then
            die "No cluster named '${name}' was found in ${INVENTORY_TSV_FILE}"
        fi
        die "No ${object} named '${name}' was found for cluster '${cluster}' in ${INVENTORY_TSV_FILE}"
    fi
    ((match_count == 1)) ||
        die "Found ${match_count} ${object} entries named '${name}' for the selected cluster; make the inventory selection unambiguous"
    printf '%s\n' "$matched_ext_id"
}

[[ -n "$PC_HOST" ]] || die "--pc-host is required"
[[ -n "$PC_USERNAME" ]] || die "--pc-username cannot be empty"
[[ -n "$CLUSTER_NAME" ]] || die "--cluster-name is required"
[[ -n "$IMAGE_NAME" ]] || die "--image-name is required"
[[ -n "$STORAGE_CONTAINER_NAME" ]] || die "--storage-container-name cannot be empty"
[[ -n "$SUBNET_NAME" ]] || die "--subnet-name cannot be empty"
[[ -n "$USERID1SSHKEY_FILE" ]] || die "--userid1-sshkey-file is required"
[[ -n "$USERID2SSHKEY_FILE" ]] || die "--userid2-sshkey-file is required"
[[ "$VM_DISK_SIZE_GB" =~ ^[0-9]{1,9}$ ]] &&
    (( 10#$VM_DISK_SIZE_GB > 0 )) ||
    die "--vm-disk-size-gb must be a positive whole number"
[[ "$VM_MEMORY_SIZE_GB" =~ ^[0-9]{1,9}$ ]] &&
    (( 10#$VM_MEMORY_SIZE_GB > 0 )) ||
    die "--vm-memory-size-gb must be a positive whole number"
VM_DISK_SIZE_BYTES=$((10#$VM_DISK_SIZE_GB * 1073741824))
VM_MEMORY_SIZE_BYTES=$((10#$VM_MEMORY_SIZE_GB * 1073741824))
[[ -r "$INVENTORY_TSV_FILE" ]] ||
    die "Cannot read inventory TSV file: $INVENTORY_TSV_FILE"
IFS= read -r INVENTORY_HEADER < "$INVENTORY_TSV_FILE" ||
    die "Inventory TSV file is empty: $INVENTORY_TSV_FILE"
[[ "$INVENTORY_HEADER" == $'Item\tObject\tName\tExtID\tCluster' ]] ||
    die "Inventory TSV must have the header: Item, Object, Name, ExtID, Cluster"
[[ -n "$VM_NAME" ]] || die "Set VM_NAME"
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${#VM_NAME}" -le 63 ]] ||
    die "VM_NAME must be at most 63 letters, digits, dots, underscores, or hyphens"
[[ "$PC_PORT" =~ ^[0-9]+$ && "${#PC_PORT}" -le 5 ]] &&
    (( 10#$PC_PORT > 0 && 10#$PC_PORT <= 65535 )) ||
    die "PC_PORT must be a valid TCP port number"
[[ "$VM_VCPUS" =~ ^[0-9]{1,3}$ ]] && (( 10#$VM_VCPUS > 0 )) ||
    die "--vm-vcpus must be a positive whole number"
VM_VCPUS=$((10#$VM_VCPUS))
[[ "$PRISM_API_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] ||
    die "--prism-api-version must look like 4.3"
[[ -r "$SSH_PRIVATE_KEY_FILE" ]] || die "Cannot read SSH private-key file: $SSH_PRIVATE_KEY_FILE"
[[ -r "$CLOUD_CONFIG_TEMPLATE" ]] || die "Cannot read cloud-init template: $CLOUD_CONFIG_TEMPLATE"
[[ "$PC_TLS_INSECURE" == true || "$PC_TLS_INSECURE" == false ]] ||
    die "PC_TLS_INSECURE must be true or false"
if [[ -n "$PC_CA_CERT" && ! -r "$PC_CA_CERT" ]]; then
    die "Cannot read Prism Central CA certificate: $PC_CA_CERT"
fi

validate_username "$USERID1"
validate_username "$USERID2"
[[ "$USERID1" != "$USERID2" ]] || die "USERID1 and USERID2 must be different"
validate_password USERID1PW "$USERID1PW"
validate_password USERID2PW "$USERID2PW"
[[ "$PC_USERNAME" != *:* && "$PC_USERNAME" != *$'\n'* ]] ||
    die "PC_USERNAME must not contain colons or newline characters"

require_command curl
require_command jq
require_command base64
require_command ssh
require_command uuidgen

CLUSTER_EXT_ID="$(lookup_inventory_ext_id "Cluster" "$CLUSTER_NAME")"
IMAGE_EXT_ID="$(lookup_inventory_ext_id "Image" "$IMAGE_NAME" "$CLUSTER_NAME")"
STORAGE_CONTAINER_EXT_ID="$(lookup_inventory_ext_id \
    "Storage Container" "$STORAGE_CONTAINER_NAME" "$CLUSTER_NAME")"
SUBNET_EXT_ID="$(lookup_inventory_ext_id "Subnet" "$SUBNET_NAME" "$CLUSTER_NAME")"
log "Resolved resource extIds from ${INVENTORY_TSV_FILE}"
printf 'Cluster: %s (%s)\n' "$CLUSTER_NAME" "$CLUSTER_EXT_ID"
printf 'Image: %s (%s)\n' "$IMAGE_NAME" "$IMAGE_EXT_ID"
printf 'Storage container: %s (%s)\n' "$STORAGE_CONTAINER_NAME" "$STORAGE_CONTAINER_EXT_ID"
printf 'Subnet: %s (%s)\n' "$SUBNET_NAME" "$SUBNET_EXT_ID"

USERID1SSHKEY="$(read_public_key "$USERID1SSHKEY_FILE")"
USERID2SSHKEY="$(read_public_key "$USERID2SSHKEY_FILE")"

PC_PASSWORD=""
read -r -s -p "Prism Central password for ${PC_USERNAME}: " PC_PASSWORD
printf '\n'
[[ -n "$PC_PASSWORD" ]] || die "Prism Central password cannot be empty"
[[ "$PC_USERNAME" != *$'\n'* && "$PC_PASSWORD" != *$'\n'* ]] ||
    die "Prism Central credentials must not contain newline characters"
[[ "$PC_USERNAME" != *:* ]] ||
    die "PC_USERNAME must not contain a colon"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rocky9-xrdp.XXXXXX")"
chmod 700 "$WORK_DIR"
cleanup() {
    rm -f "$WORK_DIR/cloud-config.yaml" \
        "$WORK_DIR/user-data.b64" \
        "$WORK_DIR/vm-request.json" \
        "$WORK_DIR/curl-auth.conf" \
        "$WORK_DIR/response.json"
    rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

jq -nr \
    --rawfile template "$CLOUD_CONFIG_TEMPLATE" \
    --arg user1 "$USERID1" \
    --arg user2 "$USERID2" \
    --arg key1 "$USERID1SSHKEY" \
    --arg key2 "$USERID2SSHKEY" \
    --arg password1 "$USERID1PW" \
    --arg password2 "$USERID2PW" '
      $template
      | split("{{USERID1}}") | join($user1)
      | split("{{USERID2}}") | join($user2)
      | split("{{USERID1SSHKEY}}") | join($key1)
      | split("{{USERID2SSHKEY}}") | join($key2)
      | split("{{USERID1PW}}") | join($password1)
      | split("{{USERID2PW}}") | join($password2)
    ' > "$WORK_DIR/cloud-config.yaml"

if grep -Eq '\{\{[^}]+\}\}' "$WORK_DIR/cloud-config.yaml"; then
    die "Unrecognized placeholder remains in rendered cloud-init data"
fi

base64 < "$WORK_DIR/cloud-config.yaml" | tr -d '\r\n' > "$WORK_DIR/user-data.b64"
USER_DATA_B64="$(<"$WORK_DIR/user-data.b64")"

jq -n \
    --arg name "$VM_NAME" \
    --arg cluster "$CLUSTER_EXT_ID" \
    --arg image "$IMAGE_EXT_ID" \
    --arg storage "$STORAGE_CONTAINER_EXT_ID" \
    --arg subnet "$SUBNET_EXT_ID" \
    --arg userData "$USER_DATA_B64" \
    --argjson diskSize "$VM_DISK_SIZE_BYTES" \
    --argjson memorySize "$VM_MEMORY_SIZE_BYTES" \
    --argjson vcpus "$VM_VCPUS" '
    {
      "name": $name,
      "numSockets": 1,
      "numCoresPerSocket": $vcpus,
      "numThreadsPerCore": 1,
      "memorySizeBytes": $memorySize,
      "cluster": {
        "extId": $cluster
      },
      "guestCustomization": {
        "config": {
          "$objectType": "vmm.v4.ahv.config.CloudInit",
          "cloudInitScript": {
            "value": $userData,
            "$objectType": "vmm.v4.ahv.config.Userdata"
          }
        }
      },
      "disks": [
        {
          "diskAddress": {
            "busType": "SATA",
            "index": 0
          },
          "backingInfo": {
            "$objectType": "vmm.v4.ahv.config.VmDisk",
            "diskSizeBytes": $diskSize,
            "storageContainer": {
              "extId": $storage
            },
            "dataSource": {
              "reference": {
                "$objectType": "vmm.v4.ahv.config.ImageReference",
                "imageExtId": $image
              }
            }
          }
        }
      ],
      "nics": [
        {
          "networkInfo": {
            "subnet": {
              "extId": $subnet
            }
          }
        }
      ]
    }
    ' > "$WORK_DIR/vm-request.json"

PC_BASE_URL="https://${PC_HOST}:${PC_PORT}"
AUTH_JSON="$(jq -nr --arg credentials "${PC_USERNAME}:${PC_PASSWORD}" '$credentials | @json')"
printf 'user = %s\n' "$AUTH_JSON" > "$WORK_DIR/curl-auth.conf"
chmod 600 "$WORK_DIR/curl-auth.conf"
unset PC_PASSWORD AUTH_JSON

CURL_OPTIONS=(--silent --show-error --config "$WORK_DIR/curl-auth.conf")
if [[ -n "$PC_CA_CERT" ]]; then
    CURL_OPTIONS+=(--cacert "$PC_CA_CERT")
elif [[ "$PC_TLS_INSECURE" == true ]]; then
    CURL_OPTIONS+=(--insecure)
fi

api_request() {
    local method="$1"
    local path="$2"
    local request_file="${3:-}"
    local status
    local curl_args=("${CURL_OPTIONS[@]}" --request "$method" \
        --header "Accept: application/json" \
        --header "Content-Type: application/json" \
        --header "NTNX-Request-Id: $(uuidgen | tr '[:upper:]' '[:lower:]')" \
        --output "$WORK_DIR/response.json" \
        --write-out '%{http_code}')

    if [[ -n "$request_file" ]]; then
        curl_args+=(--data-binary "@${request_file}")
    fi

    if ! status="$(curl "${curl_args[@]}" "${PC_BASE_URL}${path}")"; then
        die "Prism Central API request failed: ${method} ${path}"
    fi
    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        printf 'Prism Central returned HTTP %s for %s %s:\n' \
            "$status" "$method" "$path" >&2
        cat "$WORK_DIR/response.json" >&2
        die "Prism Central API request failed"
    fi
    cat "$WORK_DIR/response.json"
}

VM_NAME_FILTER="$(jq -rn --arg name "$VM_NAME" '"name eq \u0027" + $name + "\u0027" | @uri')"
VM_LIST_PATH="/api/vmm/v${PRISM_API_VERSION}/ahv/config/vms?\$page=0&\$limit=100&\$filter=${VM_NAME_FILTER}"
EXISTING_VM="$(api_request GET "$VM_LIST_PATH")"
if jq -e --arg name "$VM_NAME" '.data[]? | select(.name == $name)' \
    <<< "$EXISTING_VM" >/dev/null; then
    die "A VM named ${VM_NAME} already exists; choose a unique VM_NAME"
fi

log "Creating VM ${VM_NAME} in Prism Central"
CREATE_RESPONSE="$(api_request POST "/api/vmm/v${PRISM_API_VERSION}/ahv/config/vms" "$WORK_DIR/vm-request.json")"
TASK_ID="$(jq -er '.data.extId' <<< "$CREATE_RESPONSE")" ||
    die "Create VM response did not contain the task ID in data.extId"
TASK_ID_ENCODED="$(jq -rn --arg value "$TASK_ID" '$value | @uri')"

log "Waiting for VM creation task ${TASK_ID}"
deadline=$(( $(date +%s) + VM_BOOT_TIMEOUT_SECONDS ))
TASK_STATUS=""
while (( $(date +%s) < deadline )); do
    TASK_INFO="$(api_request GET "/api/prism/v${PRISM_API_VERSION}/config/tasks/${TASK_ID_ENCODED}")"
    TASK_STATUS="$(jq -r '.data.status // empty' <<< "$TASK_INFO")"
    case "$TASK_STATUS" in
        QUEUED|RUNNING)
            sleep "$POLL_INTERVAL_SECONDS"
            ;;
        SUCCEEDED|COMPLETED)
            break
            ;;
        *)
            die "VM creation task ${TASK_ID} ended with status '${TASK_STATUS:-unknown}'"
            ;;
    esac
done
[[ "$TASK_STATUS" == "SUCCEEDED" || "$TASK_STATUS" == "COMPLETED" ]] ||
    die "VM creation task did not complete within ${VM_BOOT_TIMEOUT_SECONDS} seconds"

VM_LIST="$(api_request GET "$VM_LIST_PATH")"
VM_EXT_ID="$(jq -er --arg name "$VM_NAME" \
    '.data[] | select(.name == $name) | .extId' <<< "$VM_LIST")" ||
    die "Could not find the created VM named ${VM_NAME}"
VM_EXT_ID_ENCODED="$(jq -rn --arg value "$VM_EXT_ID" '$value | @uri')"
VM_PATH="/api/vmm/v${PRISM_API_VERSION}/ahv/config/vms/${VM_EXT_ID_ENCODED}"
printf 'Created VM extId: %s\n' "$VM_EXT_ID"

log "Powering on VM ${VM_NAME}"
api_request POST "${VM_PATH}/\$actions/power-on" >/dev/null

log "Waiting for the VM to become powered on"
deadline=$(( $(date +%s) + VM_BOOT_TIMEOUT_SECONDS ))
VM_POWER_STATE=""
while (( $(date +%s) < deadline )); do
    VM_INFO="$(api_request GET "$VM_PATH")"
    VM_POWER_STATE="$(jq -r '.data.powerState // empty' <<< "$VM_INFO")"
    if [[ "$VM_POWER_STATE" == "ON" ]]; then
        break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
done
[[ "$VM_POWER_STATE" == "ON" ]] ||
    die "VM did not reach powerState ON within ${VM_BOOT_TIMEOUT_SECONDS} seconds"

log "Waiting for Prism Central to report the VM's IPv4 address"
VM_IP=""
deadline=$(( $(date +%s) + VM_IP_DISCOVERY_TIMEOUT_SECONDS ))
while (( $(date +%s) < deadline )); do
    VM_INFO="$(api_request GET "$VM_PATH")"
    VM_IP="$(jq -r '
      [
        .data.nics[]?
        | (
            .nicNetworkInfo.ipv4Info.learnedIpAddresses[]?.value?,
            .networkInfo.ipv4Info.learnedIpAddresses[]?.value?,
            .nicNetworkInfo.ipv4Config.ipAddress.value?,
            .networkInfo.ipv4Config.ipAddress.value?
          )
        | select(type == "string")
      ][0] // empty
    ' <<< "$VM_INFO")"
    if is_usable_ipv4 "$VM_IP"; then
        break
    fi
    VM_IP=""
    sleep "$POLL_INTERVAL_SECONDS"
done
if [[ -z "$VM_IP" ]]; then
    read -r -p "Prism Central did not report an IPv4 address. Enter the VM's reachable IPv4 address to continue (or press Enter to stop): " VM_IP
    is_usable_ipv4 "$VM_IP" ||
        die "No usable IPv4 address was found or entered"
fi
printf 'VM address: %s\n' "$VM_IP"

log "Waiting for SSH on ${VM_IP}"
deadline=$(( $(date +%s) + VM_BOOT_TIMEOUT_SECONDS ))
while (( $(date +%s) < deadline )); do
    if ssh -i "$SSH_PRIVATE_KEY_FILE" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" \
        "${USERID2}@${VM_IP}" true >/dev/null 2>&1; then
        break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
done
ssh -i "$SSH_PRIVATE_KEY_FILE" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" \
    "${USERID2}@${VM_IP}" true >/dev/null 2>&1 ||
    die "SSH did not become available within ${VM_BOOT_TIMEOUT_SECONDS} seconds"

log "Waiting for cloud-init to finish before starting XRDP setup"
ssh -i "$SSH_PRIVATE_KEY_FILE" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" \
    "${USERID2}@${VM_IP}" \
    "sudo -n timeout ${VM_BOOT_TIMEOUT_SECONDS} cloud-init status --wait" ||
    die "cloud-init did not complete successfully; refusing to start XRDP setup"

log "Downloading and starting the Rocky XRDP setup script"
REMOTE_COMMAND="sudo -n systemd-run --unit=rocky-xrdp-bootstrap --collect --no-block /bin/bash -c 'curl -fL ${SETUP_SCRIPT_URL} -o /var/tmp/setup-rocky9-xrdp.sh && chmod 0755 /var/tmp/setup-rocky9-xrdp.sh && /bin/bash /var/tmp/setup-rocky9-xrdp.sh'"
ssh -i "$SSH_PRIVATE_KEY_FILE" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" \
    "${USERID2}@${VM_IP}" "$REMOTE_COMMAND"

printf '\nVM %s (%s) is up; the XRDP setup script has been launched.\n' "$VM_NAME" "$VM_IP"
printf 'The setup reboots once and continues automatically after startup.\n'
