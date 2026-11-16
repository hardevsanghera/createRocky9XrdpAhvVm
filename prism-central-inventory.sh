#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s [--host HOST] [--port PORT] [--username USER]\n' "$0"
    printf '          [--output FILE] [--insecure]\n'
    printf '  --host HOST       Prism Central IP address or hostname\n'
    printf '  --port PORT       Prism Central port (default: 9440)\n'
    printf '  --username USER   Prism Central username\n'
    printf '  --output FILE     TSV report path (default: timestamped file)\n'
    printf '  --insecure        Skip TLS certificate verification (not recommended)\n'
    printf 'The password is always requested interactively.\n'
}

PC_TLS_INSECURE=false
while (($#)); do
    case "$1" in
        --host)
            (($# >= 2)) || die "--host requires a value"
            PC_HOST="$2"
            shift
            ;;
        --host=*)
            PC_HOST="${1#*=}"
            ;;
        --port)
            (($# >= 2)) || die "--port requires a value"
            PC_PORT="$2"
            shift
            ;;
        --port=*)
            PC_PORT="${1#*=}"
            ;;
        --username)
            (($# >= 2)) || die "--username requires a value"
            PC_USERNAME="$2"
            shift
            ;;
        --username=*)
            PC_USERNAME="${1#*=}"
            ;;
        --output)
            (($# >= 2)) || die "--output requires a value"
            OUTPUT_FILE="$2"
            shift
            ;;
        --output=*)
            OUTPUT_FILE="${1#*=}"
            ;;
        --insecure)
            PC_TLS_INSECURE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac
    shift
done

command -v curl >/dev/null 2>&1 || die "Required command not found: curl"
command -v jq >/dev/null 2>&1 || die "Required command not found: jq"

if [[ -z "${PC_HOST:-}" ]]; then
    read -r -p "Prism Central IP address or hostname: " PC_HOST
fi
[[ "$PC_HOST" =~ ^[A-Za-z0-9.-]+$ ||
    "$PC_HOST" =~ ^[A-Fa-f0-9:.]+$ ||
    "$PC_HOST" =~ ^\[[A-Fa-f0-9:.]+\]$ ]] ||
    die "Enter an IP address or hostname without a URL scheme or path"

PC_PORT="${PC_PORT:-9440}"
[[ "$PC_PORT" =~ ^[0-9]+$ && "${#PC_PORT}" -le 5 ]] &&
    (( 10#$PC_PORT > 0 && 10#$PC_PORT <= 65535 )) ||
    die "Port must be a valid TCP port number"

if [[ -z "${PC_USERNAME:-}" ]]; then
    read -r -p "Prism Central username: " PC_USERNAME
fi
[[ -n "$PC_USERNAME" && "$PC_USERNAME" != *:* &&
    "$PC_USERNAME" != *$'\n'* ]] ||
    die "Prism Central username cannot be empty or contain a colon/newline"
read -r -s -p "Prism Central password: " PC_PASSWORD
printf '\n'
[[ -n "$PC_PASSWORD" && "$PC_PASSWORD" != *$'\n'* ]] ||
    die "Prism Central password cannot be empty or contain a newline"

if [[ "$PC_HOST" == \[*\] ]]; then
    PC_URL_HOST="$PC_HOST"
elif [[ "$PC_HOST" == *:* ]]; then
    PC_URL_HOST="[${PC_HOST}]"
else
    PC_URL_HOST="$PC_HOST"
fi
PC_BASE_URL="https://${PC_URL_HOST}:${PC_PORT}"
OUTPUT_FILE="${OUTPUT_FILE:-prism-central-inventory-$(date '+%Y%m%d-%H%M%S').tsv}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prism-central-inventory.XXXXXX")"
chmod 700 "$WORK_DIR"
cleanup() {
    rm -f "$WORK_DIR/curl-auth.conf" "$WORK_DIR/response.json" \
        "$WORK_DIR/inventory.tsv"
    rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

AUTH_JSON="$(jq -nr --arg credentials "${PC_USERNAME}:${PC_PASSWORD}" '$credentials | @json')"
printf 'user = %s\n' "$AUTH_JSON" > "$WORK_DIR/curl-auth.conf"
chmod 600 "$WORK_DIR/curl-auth.conf"
unset PC_PASSWORD AUTH_JSON

CURL_OPTIONS=(--silent --show-error --config "$WORK_DIR/curl-auth.conf"
    --connect-timeout 15 --max-time 120)
if [[ "$PC_TLS_INSECURE" == true ]]; then
    CURL_OPTIONS+=(--insecure)
fi

api_request() {
    local path="$1"
    local status

    if ! status="$(curl "${CURL_OPTIONS[@]}" \
        --header "Accept: application/json" \
        --output "$WORK_DIR/response.json" \
        --write-out '%{http_code}' \
        "${PC_BASE_URL}${path}")"; then
        die "Prism Central API request failed: GET ${path}"
    fi
    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        printf 'Prism Central returned HTTP %s for GET %s:\n' \
            "$status" "$path" >&2
        cat "$WORK_DIR/response.json" >&2
        die "Prism Central API request failed"
    fi
    cat "$WORK_DIR/response.json"
}

list_all() {
    local endpoint="$1"
    local id_field="${2:-extId}"
    local page=0
    local page_json
    local page_data
    local count
    local all='[]'

    while :; do
        page_json="$(api_request "${endpoint}?\$page=${page}&\$limit=100")"
        jq -e '.data | type == "array"' <<< "$page_json" >/dev/null ||
            die "Unexpected list response from ${endpoint}: expected a data array"
        jq -e --arg id_field "$id_field" \
            'all(.data[]; (.name | type == "string") and
            ((.[$id_field] // .extId) | type == "string"))' \
            <<< "$page_json" >/dev/null ||
            die "Unexpected resource fields in response from ${endpoint}"

        # Storage-container responses expose their ID as containerExtId.
        page_data="$(jq -c --arg id_field "$id_field" \
            '[.data[] | . + {extId: (.extId // .[$id_field])}]' \
            <<< "$page_json")"
        all="$(jq -cn --argjson accumulated "$all" --argjson next "$page_data" \
            '$accumulated + $next')"
        count="$(jq -r '.data | length' <<< "$page_json")"
        ((count < 100)) && break
        page=$((page + 1))
    done
    printf '%s\n' "$all"
}

log() {
    printf '\n==> %s\n' "$*"
}

log "Reading clusters"
CLUSTERS="$(list_all "/api/clustermgmt/v4.0/config/clusters")"
log "Reading images"
IMAGES="$(list_all "/api/vmm/v4.0/content/images")"
log "Reading storage containers"
STORAGE_CONTAINERS="$(list_all "/api/clustermgmt/v4.0/config/storage-containers" "containerExtId")"
log "Reading subnets"
SUBNETS="$(list_all "/api/networking/v4.0/config/subnets")"

jq -nr \
    --argjson clusters "$CLUSTERS" \
    --argjson images "$IMAGES" \
    --argjson storage "$STORAGE_CONTAINERS" \
    --argjson subnets "$SUBNETS" '
    def cluster_name($id):
      if ($id | type) != "string" or $id == "" then "Not specified"
      else
        ([$clusters[] | select(.extId == $id) | .name][0]
         // ("Unknown cluster (" + $id + ")"))
      end;
    def cluster_names($ids):
      if ($ids | type) == "array" then
        if ($ids | length) == 0 then "Not specified"
        else
          [$ids[] | if type == "object" then .extId else . end
           | cluster_name(.)]
          | unique | join(", ")
        end
      elif ($ids | type) == "string" then cluster_name($ids)
      else "Not specified"
      end;
    def as_ext_id:
      if type == "string" then .
      elif type == "object" then (.extId // empty)
      else empty
      end;
    def resource_cluster_id:
      (.clusterExtId | as_ext_id)
      // (.clusterReference | as_ext_id)
      // (.cluster | as_ext_id)
      // (if (.spec | type) == "object"
          then (.spec.clusterExtId | as_ext_id)
          else empty
          end)
      // "";
    def rows:
      ([$clusters[] | ["Cluster", .name, .extId, "-"]]) +
      ([$images[] |
        ["Image", .name, .extId,
         cluster_names(.clusterLocationExtIds // .cluster_location_ext_ids // [])]]) +
      ([$storage[] |
        ["Storage Container", .name, .extId, cluster_name(resource_cluster_id)]]) +
      ([$subnets[] |
        ["Subnet", .name, .extId, cluster_name(resource_cluster_id)]]);
    (["Item", "Object", "Name", "ExtID", "Cluster"] | @tsv),
    (rows | to_entries[] | [(.key + 1), .value[]] | @tsv)
    ' > "$WORK_DIR/inventory.tsv" ||
    die "Could not format the Prism Central inventory"

mv "$WORK_DIR/inventory.tsv" "$OUTPUT_FILE" ||
    die "Could not write inventory file: $OUTPUT_FILE"

printf '\n'
if command -v column >/dev/null 2>&1; then
    column -t -s "$(printf '\t')" "$OUTPUT_FILE"
else
    cat "$OUTPUT_FILE"
fi
printf '\nInventory written to: %s\n' "$OUTPUT_FILE"
