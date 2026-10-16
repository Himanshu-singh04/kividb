#!/usr/bin/env bash
# Deletes everything create.sh made for a run: every resource in
# $RESOURCE_GROUP whose name contains "kvb-<RUN_PREFIX>-". RUN_PREFIX is the
# GitHub run id alone, so one call also clears what earlier attempts of the
# same run left behind ("kvb-<run>-<attempt>-...").
set -euo pipefail

: "${RUN_PREFIX:?RUN_PREFIX is required}"
RESOURCE_GROUP="${RESOURCE_GROUP:-kividb-benchmark}"
MATCH="kvb-$RUN_PREFIX-"
export AZURE_CORE_ONLY_SHOW_ERRORS=true

# The Azure CLI on GitHub's runners sometimes dies on its own import race
# ("deadlock detected by _ModuleLock"). Every call here is safe to repeat.
az() {
  local i
  for i in 1 2 3; do
    command az "$@" && return 0
    echo "az $1 $2 failed (attempt $i of 3)" >&2
    sleep 10
  done
  return 1
}

# Dependents before what they depend on: a machine holds its card, a card its
# address and subnet, a subnet its security group.
ORDER=(
  Microsoft.Compute/virtualMachines
  Microsoft.DevTestLab/schedules
  Microsoft.Compute/disks
  Microsoft.Network/networkInterfaces
  Microsoft.Network/publicIPAddresses
  Microsoft.Compute/proximityPlacementGroups
  Microsoft.Network/virtualNetworks
  Microsoft.Network/networkSecurityGroups
)

# "type id" per line. tr: the Windows CLI ends lines with \r.
leftovers() {
  az resource list -g "$RESOURCE_GROUP" \
    --query "[?contains(name, '$MATCH')].[type, id]" -o tsv | tr -d '\r'
}

for pass in 1 2 3 4; do
  list=$(leftovers)
  if [[ -z "$list" ]]; then
    echo "Nothing left for $MATCH."
    exit 0
  fi
  echo "Pass $pass:"
  for type in "${ORDER[@]}" ""; do
    while IFS=$'\t' read -r t id; do
      [[ -z "$id" ]] && continue
      if [[ -n "$type" && "${t,,}" != "${type,,}" ]]; then continue; fi
      if [[ -z "$type" ]] && printf '%s\n' "${ORDER[@]}" | grep -qix "$t"; then continue; fi
      echo "  $id"
      az resource delete --ids "$id" -o none || true
    done <<< "$list"
  done
  sleep 10
done

if [[ -z "$(leftovers)" ]]; then
  echo "Nothing left for $MATCH."
  exit 0
fi
echo "::error::Resources still present after teardown:"
leftovers
exit 1
