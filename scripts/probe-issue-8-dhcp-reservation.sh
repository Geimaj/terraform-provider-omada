#!/usr/bin/env bash
# Compatible with bash 3.2 (macOS default).
# Issue #8 probe: capture the Omada DHCP reservation API contract.
#
# The default run is read-only and captures the reservation list. Pass
# --apply to create one temporary reservation, edit it, disable it, enable it,
# and delete it. The temporary reservation is also deleted on early failure.
#
# The endpoint and update verb are intentionally overridable because they vary
# across Omada controller generations and are the subject of this probe.
#
# Usage:
#   export OMADA_URL='https://192.168.68.136'
#   export OMADA_USERNAME='...'
#   export OMADA_PASSWORD='...'
#   export OMADA_SITE='Yggdrasil'
#   ./scripts/probe-issue-8-dhcp-reservation.sh
#
#   export OMADA_DHCP_NETWORK_ID='...'
#   export OMADA_DHCP_PROBE_MAC='02:00:00:00:08:01'
#   export OMADA_DHCP_PROBE_IP='10.10.70.253' # must be unused
#   ./scripts/probe-issue-8-dhcp-reservation.sh --apply
#
# Optional controller-specific overrides:
#   OMADA_DHCP_RESERVATION_PATH=/sites/{site_id}/setting/service/dhcp
#   OMADA_DHCP_UPDATE_METHOD=PUT       # PATCH on controllers that use PATCH
#   OMADA_DHCP_ENABLE_METHOD=PUT       # PATCH on controllers that use PATCH
#   OMADA_DHCP_DELETE_METHOD=DELETE
#   OMADA_DHCP_IP_START=3232235520     # otherwise derived from gatewaySubnet
#   OMADA_DHCP_IP_END=3232235775
#
# Output: dist/issue-8-dhcp-reservation/*.request.json,
#         *.response.json, and SUMMARY.md. Request artifacts contain API paths
#         but never the token, password, cookie, or Authorization headers.

set -euo pipefail

: "${OMADA_URL:?missing OMADA_URL}"
: "${OMADA_USERNAME:?missing OMADA_USERNAME}"
: "${OMADA_PASSWORD:?missing OMADA_PASSWORD}"
: "${OMADA_SITE:?missing OMADA_SITE}"

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=1
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--apply]" >&2
    exit 2
fi

if [[ "$APPLY" == "1" ]]; then
    : "${OMADA_DHCP_NETWORK_ID:?missing OMADA_DHCP_NETWORK_ID for --apply}"
    : "${OMADA_DHCP_PROBE_MAC:?missing OMADA_DHCP_PROBE_MAC for --apply}"
    : "${OMADA_DHCP_PROBE_IP:?missing OMADA_DHCP_PROBE_IP for --apply}"
fi

command -v curl >/dev/null || { echo "error: curl not in PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not in PATH" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/dist/issue-8-dhcp-reservation"
mkdir -p "$OUT_DIR"

JAR=$(mktemp -t omada-issue8.XXXXXX)
CREATED_ID=""
DELETE_CAPTURED=0
REQUEST_FAILURE_COUNT=0
CURL=(curl -sk -H "Accept: application/json")

api() {
    local path="$1"
    local sep="?"
    [[ "$path" == *"?"* ]] && sep="&"
    echo "$OMADA_URL/$OMADAC_ID/api/v2${path}${sep}token=$TOKEN"
}

write_request_artifact() {
    local outfile="$1" method="$2" path="$3" body="${4:-}"
    if [[ -n "$body" ]]; then
        jq -n --arg method "$method" --arg path "$path" --argjson body "$body" \
            '{method:$method, path:$path, body:$body}' > "$outfile"
    else
        jq -n --arg method "$method" --arg path "$path" \
            '{method:$method, path:$path}' > "$outfile"
    fi
}

request() {
    local label="$1" method="$2" path="$3" body="${4:-}"
    local req_file="$OUT_DIR/${label}.request.json"
    local resp_file="$OUT_DIR/${label}.response.json"

    write_request_artifact "$req_file" "$method" "$path" "$body"
    echo "  $method $path" >&2
    if [[ -n "$body" ]]; then
        "${CURL[@]}" -X "$method" "$(api "$path")" \
            -H 'Content-Type: application/json' -d "$body" > "$resp_file"
    else
        "${CURL[@]}" -X "$method" "$(api "$path")" > "$resp_file"
    fi

    local code msg
    code=$(jq -r '.errorCode // "?"' "$resp_file")
    msg=$(jq -r '.msg // ""' "$resp_file")
    echo "    errorCode=$code msg=\"$msg\"" >&2
    if [[ "$code" != "0" ]]; then
        REQUEST_FAILURE_COUNT=$((REQUEST_FAILURE_COUNT + 1))
    fi
}

cleanup() {
    local exit_code=$?
    if [[ -n "$CREATED_ID" && "$DELETE_CAPTURED" == "0" ]]; then
        echo "Cleanup: deleting temporary reservation $PROBE_MAC" >&2
        local detail_path="$RESERVATION_BASE/$PROBE_MAC"
        write_request_artifact "$OUT_DIR/99-cleanup-delete.request.json" \
            "$DELETE_METHOD" "$detail_path"
        "${CURL[@]}" -X "$DELETE_METHOD" "$(api "$detail_path")" \
            > "$OUT_DIR/99-cleanup-delete.response.json" || true
    fi
    rm -f "$JAR"
    exit "$exit_code"
}
trap cleanup EXIT

echo "[1/8] Fetching controller information" >&2
INFO=$("${CURL[@]}" "$OMADA_URL/api/info")
OMADAC_ID=$(echo "$INFO" | jq -r '.result.omadacId')
CONTROLLER_VER=$(echo "$INFO" | jq -r '.result.controllerVer // "unknown"')
[[ -n "$OMADAC_ID" && "$OMADAC_ID" != "null" ]] || { echo "FAIL: no omadacId" >&2; exit 1; }
echo "  omadacId=$OMADAC_ID controllerVer=$CONTROLLER_VER" >&2

echo "[2/8] Logging in" >&2
LOGIN_BODY=$(jq -nc --arg u "$OMADA_USERNAME" --arg p "$OMADA_PASSWORD" \
    '{username:$u,password:$p}')
LOGIN_RESP=$("${CURL[@]}" -c "$JAR" -X POST \
    "$OMADA_URL/$OMADAC_ID/api/v2/login" \
    -H 'Content-Type: application/json' -d "$LOGIN_BODY")
TOKEN=$(echo "$LOGIN_RESP" | jq -r '.result.token // empty')
[[ -n "$TOKEN" ]] || { echo "FAIL: login failed" >&2; echo "$LOGIN_RESP" | jq '.' >&2; exit 1; }
CURL+=(-H "Csrf-Token: $TOKEN" -b "$JAR")

echo "[3/8] Resolving site '$OMADA_SITE'" >&2
SITES=$("${CURL[@]}" "$(api "/sites?currentPage=1&currentPageSize=100")")
SITE_ID=$(echo "$SITES" | jq -r --arg name "$OMADA_SITE" \
    '.result.data[]? | select(.name==$name) | .id' | head -1)
[[ -n "$SITE_ID" && "$SITE_ID" != "null" ]] || { echo "FAIL: site not found" >&2; exit 1; }
echo "  siteId=$SITE_ID" >&2

if [[ -n "${OMADA_DHCP_RESERVATION_PATH:-}" ]]; then
    PATH_TEMPLATE="$OMADA_DHCP_RESERVATION_PATH"
else
    # Keep this outside ${var:-default}: the } in {site_id} would terminate
    # that parameter expansion early on Bash 3.2.
    PATH_TEMPLATE='/sites/{site_id}/setting/service/dhcp'
fi
# Bash pattern replacement treats braces as pattern syntax on some versions.
# Use sed so the literal placeholder cannot turn into a malformed site path.
RESERVATION_BASE=$(printf '%s' "$PATH_TEMPLATE" | sed "s|{site_id}|$SITE_ID|g")
if [[ "$RESERVATION_BASE" == *"{"* || "$RESERVATION_BASE" == *"}"* ]]; then
    echo "FAIL: malformed reservation path: $RESERVATION_BASE" >&2
    echo "Unset OMADA_DHCP_RESERVATION_PATH to use the verified default." >&2
    exit 1
fi
UPDATE_METHOD="${OMADA_DHCP_UPDATE_METHOD:-PUT}"
ENABLE_METHOD="${OMADA_DHCP_ENABLE_METHOD:-$UPDATE_METHOD}"
DELETE_METHOD="${OMADA_DHCP_DELETE_METHOD:-DELETE}"

jq -n \
    --arg generated "$(date -u +%FT%TZ)" \
    --arg controllerVersion "$CONTROLLER_VER" \
    --arg omadacId "$OMADAC_ID" \
    --arg siteName "$OMADA_SITE" \
    --arg siteId "$SITE_ID" \
    --arg reservationPath "$RESERVATION_BASE" \
    --arg updateMethod "$UPDATE_METHOD" \
    --arg enableMethod "$ENABLE_METHOD" \
    --arg deleteMethod "$DELETE_METHOD" \
    '{generated:$generated, controllerVersion:$controllerVersion, omadacId:$omadacId,
      siteName:$siteName, siteId:$siteId, reservationPath:$reservationPath,
      methods:{update:$updateMethod, enableDisable:$enableMethod, delete:$deleteMethod}}' \
    > "$OUT_DIR/00-metadata.json"

echo "[4/8] Capturing reservation list" >&2
LIST_PATH="$RESERVATION_BASE?currentPage=1&currentPageSize=10&searchKey="
request "01-list" GET "$LIST_PATH"

if [[ "$APPLY" == "0" ]]; then
    LIST_CODE=$(jq -r '.errorCode // "?"' "$OUT_DIR/01-list.response.json")
    {
        echo "# Issue #8 — DHCP reservation API probe"
        echo
        printf '%s\n' "- Controller version: \`$CONTROLLER_VER\`"
        printf '%s\n' "- Site: \`$OMADA_SITE\` (\`$SITE_ID\`)"
        printf '%s\n' "- Candidate endpoint: \`$RESERVATION_BASE\`"
        echo "- Mode: read-only list"
        printf '%s\n' "- List response errorCode: \`$LIST_CODE\`"
        echo
        echo "Run again with \`--apply\` and the documented probe variables to capture the"
        echo "create, edit, disable, enable, and delete contracts."
    } > "$OUT_DIR/SUMMARY.md"
    if [[ "$LIST_CODE" != "0" ]]; then
        echo "FAIL: list request returned errorCode=$LIST_CODE; inspect 01-list.response.json" >&2
        exit 1
    fi
    echo "Read-only probe complete: $OUT_DIR" >&2
    exit 0
fi

PROBE_HOSTNAME="${OMADA_DHCP_PROBE_HOSTNAME:-tf-issue-8-probe}"
PROBE_DESCRIPTION="${OMADA_DHCP_PROBE_DESCRIPTION:-terraform-provider-omada issue 8 probe}"
EDITED_HOSTNAME="${OMADA_DHCP_EDITED_HOSTNAME:-tf-issue-8-probe-edited}"
EDITED_DESCRIPTION="${OMADA_DHCP_EDITED_DESCRIPTION:-terraform-provider-omada issue 8 edited probe}"

MAC_HEX=$(printf '%s' "$OMADA_DHCP_PROBE_MAC" | tr -d ':-.' | tr '[:lower:]' '[:upper:]')
if [[ ! "$MAC_HEX" =~ ^[0-9A-F]{12}$ ]]; then
    echo "FAIL: OMADA_DHCP_PROBE_MAC must contain exactly 12 hexadecimal digits" >&2
    exit 1
fi
PROBE_MAC=$(printf '%s' "$MAC_HEX" | sed -E 's/(..)(..)(..)(..)(..)(..)/\1-\2-\3-\4-\5-\6/')

if [[ -n "${OMADA_DHCP_IP_START:-}" || -n "${OMADA_DHCP_IP_END:-}" ]]; then
    : "${OMADA_DHCP_IP_START:?set both OMADA_DHCP_IP_START and OMADA_DHCP_IP_END}"
    : "${OMADA_DHCP_IP_END:?set both OMADA_DHCP_IP_START and OMADA_DHCP_IP_END}"
    IP_START="$OMADA_DHCP_IP_START"
    IP_END="$OMADA_DHCP_IP_END"
else
    NETWORKS_PATH="/sites/$SITE_ID/setting/lan/networks?currentPage=1&currentPageSize=100"
    echo "  deriving ipStart/ipEnd from network gatewaySubnet" >&2
    request "01-network-list" GET "$NETWORKS_PATH"
    NETWORK_CIDR=$(jq -r --arg id "$OMADA_DHCP_NETWORK_ID" '
        (.result.data // .result // [])[]?
        | select(.id == $id)
        | .gatewaySubnet // empty
    ' "$OUT_DIR/01-network-list.response.json" | head -1)
    if [[ -z "$NETWORK_CIDR" || "$NETWORK_CIDR" != */* ]]; then
        echo "FAIL: network $OMADA_DHCP_NETWORK_ID has no gatewaySubnet; set OMADA_DHCP_IP_START and OMADA_DHCP_IP_END explicitly" >&2
        exit 1
    fi
    BOUNDS=$(jq -nr --arg cidr "$NETWORK_CIDR" '
        def ipnum:
            split(".") | map(tonumber)
            | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
        ($cidr | split("/")) as $parts
        | ($parts[0] | ipnum) as $ip
        | ($parts[1] | tonumber) as $prefix
        | (reduce range(0; 32 - $prefix) as $unused (1; . * 2)) as $size
        | (($ip / $size | floor) * $size) as $start
        | [$start, ($start + $size - 1)] | @tsv
    ')
    IFS=$'\t' read -r IP_START IP_END <<< "$BOUNDS"
    echo "    gatewaySubnet=$NETWORK_CIDR ipStart=$IP_START ipEnd=$IP_END" >&2
fi

CREATE_BODY=$(jq -nc \
    --arg netId "$OMADA_DHCP_NETWORK_ID" \
    --arg mac "$PROBE_MAC" \
    --arg ip "$OMADA_DHCP_PROBE_IP" \
    --arg clientName "$PROBE_HOSTNAME" \
    --argjson ipStart "$IP_START" \
    --argjson ipEnd "$IP_END" \
    --arg description "$PROBE_DESCRIPTION" \
    '{netId:$netId, mac:$mac, clientName:$clientName, ip:$ip,
      ipStart:$ipStart, ipEnd:$ipEnd, description:$description, status:true}')

echo "[5/8] Creating temporary reservation" >&2
request "02-create" POST "$RESERVATION_BASE" "$CREATE_BODY"
CREATE_CODE=$(jq -r '.errorCode // "?"' "$OUT_DIR/02-create.response.json")
if [[ "$CREATE_CODE" != "0" ]]; then
    echo "FAIL: create was rejected; inspect 02-create.*.json" >&2
    exit 1
fi
CREATED_ID=$(jq -r '
    .result as $result
    | if ($result | type) == "string" then
        $result
      elif ($result | type) == "object" then
        $result.id // $result.reservationId // $result.data.id // empty
      else
        empty
      end
' "$OUT_DIR/02-create.response.json")
if [[ -z "$CREATED_ID" || "$CREATED_ID" == "null" ]]; then
    CREATED_ID=$("${CURL[@]}" "$(api "$LIST_PATH")" | jq -r \
        --arg mac "$PROBE_MAC" --arg ip "$OMADA_DHCP_PROBE_IP" '
        (.result.data // .result // [])[]?
        | select((.mac // .macAddress // "" | ascii_upcase) == ($mac | ascii_upcase)
                 or (.ip // .ipAddress // "") == $ip)
        | .id // .reservationId // empty
    ' | head -1)
fi
[[ -n "$CREATED_ID" && "$CREATED_ID" != "null" ]] || {
    echo "FAIL: create succeeded but no reservation ID could be found" >&2
    exit 1
}
echo "  reservationId=$CREATED_ID" >&2

# Omada returns an internal record ID from create, but the UI-observed CRUD
# contract addresses an existing DHCP reservation by its dash-separated MAC.
DETAIL_PATH="$RESERVATION_BASE/$PROBE_MAC"
EDIT_BODY=$(echo "$CREATE_BODY" | jq \
    --arg clientName "$EDITED_HOSTNAME" --arg description "$EDITED_DESCRIPTION" \
    '.clientName=$clientName | .description=$description')

echo "[6/8] Editing temporary reservation" >&2
request "03-edit" "$UPDATE_METHOD" "$DETAIL_PATH" "$EDIT_BODY"

DISABLED_BODY=$(echo "$EDIT_BODY" | jq '.status=false')
ENABLED_BODY=$(echo "$EDIT_BODY" | jq '.status=true')

echo "[7/8] Disabling then enabling temporary reservation" >&2
request "04-disable" "$ENABLE_METHOD" "$DETAIL_PATH" "$DISABLED_BODY"
request "05-enable" "$ENABLE_METHOD" "$DETAIL_PATH" "$ENABLED_BODY"

echo "[8/8] Reading final state and deleting temporary reservation" >&2
READ_PATH="$RESERVATION_BASE?currentPage=1&currentPageSize=10&searchKey=$PROBE_MAC"
request "06-read-after-enable" GET "$READ_PATH"
request "07-delete" "$DELETE_METHOD" "$DETAIL_PATH"
DELETE_CODE=$(jq -r '.errorCode // "?"' "$OUT_DIR/07-delete.response.json")
if [[ "$DELETE_CODE" == "0" ]]; then
    DELETE_CAPTURED=1
    CREATED_ID=""
else
    echo "  delete failed; cleanup trap will retry and capture its response" >&2
fi
request "08-list-after-delete" GET "$LIST_PATH"

{
    echo "# Issue #8 — DHCP reservation API probe"
    echo
    printf '%s\n' "- Controller version: \`$CONTROLLER_VER\`"
    printf '%s\n' "- Site: \`$OMADA_SITE\` (\`$SITE_ID\`)"
    printf '%s\n' "- Endpoint: \`$RESERVATION_BASE\`"
    echo "- Create method: \`POST\`"
    printf '%s\n' "- Update method: \`$UPDATE_METHOD\`"
    printf '%s\n' "- Enable/disable method: \`$ENABLE_METHOD\`"
    printf '%s\n' "- Delete method: \`$DELETE_METHOD\`"
    echo
    echo "| Operation | errorCode | Message |"
    echo "|---|---:|---|"
    for label in 01-list 02-create 03-edit 04-disable 05-enable 06-read-after-enable 07-delete 08-list-after-delete; do
        code=$(jq -r '.errorCode // "?"' "$OUT_DIR/$label.response.json")
        msg=$(jq -r '.msg // "" | gsub("\\|"; "\\\\|")' "$OUT_DIR/$label.response.json")
        echo "| $label | $code | $msg |"
    done
    echo
    echo "Inspect the paired \`*.request.json\` and \`*.response.json\` artifacts to map"
    echo "the exact wire fields and response envelope into the provider client."
} > "$OUT_DIR/SUMMARY.md"

echo "Summary: $OUT_DIR/SUMMARY.md" >&2
if [[ "$REQUEST_FAILURE_COUNT" -ne 0 ]]; then
    echo "FAIL: $REQUEST_FAILURE_COUNT API operation(s) returned a non-zero errorCode; inspect SUMMARY.md" >&2
    exit 1
fi
echo "Probe complete: $OUT_DIR" >&2
