#!/bin/sh
#
# MIT License
#
# (C) Copyright 2022 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

# For debugging purposes, not advertised -eu is expected
set "${SETOPTS:--eu}"

# Helm options
INTERVAL="${INTERVAL:-60}"
VERBOSE="${VERBOSE:-false}"

# Non helm options (for testing generally)
DAEMON="${DAEMON:-true}"
PREFIX="${PREFIX:-cray-k8s-encryption}"
NAMESPACE="${NAMESPACE:-kube-system}"

# Default if not given, will likely never exist outside of a volume mount.
ENCRYPTION_CONFIGFILE="${ENCRYPTION_CONFIGFILE:-/k8s/current.yaml}"

# Current node we're running on, here for testing and as uname -n doesn't return
# the actual hostname that kubectl get nodes will. We pass in that information
# via NODE in the daemonset as well. But technically if you run this outside of
# k8s it'll work there too. Mostly.
nodename() {
  printf "%s" "${NODE:-$(uname -n)}"
}

# Here just to make annotations easier to write/update.
annotation_prefix() {
  printf "%s" "${PREFIX}"
}

# Prints out only control plane node names based on the node-role label. Only
# controlplane nodes have the encryption file so no sense in annotating anything
# that isn't a control-plane.
kubectl_get_controlplane_nodes() {
  kubectl get nodes --selector=node-role.kubernetes.io/master --no-headers=true -o custom-columns=NAME:.metadata.name
}

# Used elsewhere but this determines which daemonset does work
first_controlplane_node() {
  [ "$(kubectl_get_controlplane_nodes | head -n1)" = "$(nodename)" ]
}

# Wrapper for the crazy kubectl output to get taints and what nodes are ready.
# Not sure taints are useful though as all shasta nodes have NoSchedule anyway.
all_ready_controlplane_nodes() {
  kubectl get nodes --selector=node-role.kubernetes.io/master -o jsonpath='{range .items[*]} {.metadata.name} {.status.conditions[?(@.type=="Ready")].status} {" "} {.spec.taints} {"\n"} {end}' | awk '/True/ {print $1}'
}

# We also want to refuse updates if any control plane node isn't Ready, so
# simply check the nodes with master role and what is actually online and Ready
# via that same label.
all_controlplane_nodes_online() {
  [ "$(kubectl_get_controlplane_nodes | wc -l)" -eq "$(all_ready_controlplane_nodes | wc -l)" ]
}

# Boolean of if the node we are running on is capable of being annotated
nodename_updateable() {
  kubectl_get_controlplane_nodes | grep "$(nodename)" > /dev/null 2>&1
}

# If the encryption configfile exists use that for data otherwise act like we
# are running an identity only configuration.
read_ec_file() {
  if [ -e "${ENCRYPTION_CONFIGFILE}" ]; then
    cat "${ENCRYPTION_CONFIGFILE}"
  else
    cat << FIN
---
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - identity: {}
FIN
  fi
}

# If there are providers we don't recognize, abort, none have been
# tested/validated with this setup. Only recognize idenity aescbc and aesgcm as valid providers
ec_providers() {
  read_ec_file | yq e '(.resources[0].providers[] | keys)[]' -
}

# Validate the providers are one of identity, aesgcm, or aescbc.
valid_providers() {
  ! ec_providers | grep -Ev '(identity|aesgcm|aescbc)' > /dev/null 2>&1
}

# Get the encryption_config setup we're running with, if we have none we should
# be in an identity configuration so annotate it as that.
encryption_config_annotation() {
  out=
  for provider in $(ec_providers); do
    # identity is unique, the rest all have keys.-> name entries
    if [ "identity" = "${provider}" ]; then
      out="${out}${out:+,}${provider}"
    else
      # Handle the rest with key name appended
      for name in $(read_ec_file | yq e ".resources[0].providers[].${provider}.keys[].name" -); do
        out="${out}${out:+,}${provider}:${name}"
      done
    fi
  done
  printf "%s" "${out}"
}

# Returns all the control plane annotation values, blank lines are "no annotation", that is OK
get_controlplane_encryption_annotations() {
  kubectl get nodes --selector=node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.annotations.'"$(annotation_prefix)"'}{"\n"}'
}

# Determines if/when it is ok to update secrets on first control-plane node
can_update() {
  # Conditions that allow for rewriting data:
  # - We have 1 line that is shared amongst *ALL* control plane nodes, any difference to this is invalid thus no update
  # - All control plane nodes are online
  annotations="$(get_controlplane_encryption_annotations)"
  nannotations=$(echo "${annotations}" | sort -u | wc -l)
  if [ "${annotations}" != "" ] &&
       [ "${nannotations}" -eq 1 ] &&
       all_controlplane_nodes_online; then
    return 0
  fi

  # Default is do nothing
  return 1
}

# secret related functions

# Note nothing contained in the secret, annotations or not, is overly important,
# it could be deleted and recreated all it will cause is a rewrite of data in
# that case at worst.

# Current encryption configuration, or rather last known configuration based off last rewrite of data in k8s
secret_current() {
  kubectl get secret -n kube-system cray-k8s-encryption -o jsonpath='{range .items[*]}{.metadata.annotations.current}'
}

# The goal of encryption aka what encryption key name we want things to be rewritten with
secret_goal() {
  kubectl get secret -n kube-system cray-k8s-encryption -o jsonpath='{range .items[*]}{.metadata.annotations.goal}'
}

# How many times we have rewritten data successfully, failed attempts do not increment this number
secret_generation() {
  kubectl get secret -n kube-system cray-k8s-encryption -o jsonpath='{range .items[*]}{.metadata.annotations.generation}'
}

# Take in ^^^ first two functions and decide if rewriting is needed, simple comparison
can_update_secret() {
  if [ "$(secret_current)" = "unknown" ] ||
       [ "$(secret_current)" != "$(secret_goal)" ]; then
    return 0
  fi
  return 1
}

# Return the new encryption goal based off of node annotations
get_secret_goal() {
  get_controlplane_encryption_annotations | sort -u | sed -e 's/[,].*//' | tr -d '\n'
}

# Compare the node annotations to the secrets goal
secret_goal_check() {
  [ "$(get_secret_goal)" = "$(secret_goal)" ]
}

# Simple wrapper to set the secrets goal annotation
set_secret_goal() {
  kubectl annotate secret --overwrite -n kube-system cray-k8s-encryption "goal=${1?}"
}

# Simple wrapper to set the secrets current annotation
set_secret_current() {
  kubectl annotate secret --overwrite -n kube-system cray-k8s-encryption "current=${1?}"
}

# Simple wrapper to set the secrets generation annotation
set_secret_generation() {
  kubectl annotate secret --overwrite -n kube-system cray-k8s-encryption "generation=${1?}"
}

# Simple wrapper to set the secrets changed annotation
set_secret_changed() {
  kubectl annotate secret --overwrite -n kube-system cray-k8s-encryption "changed=${1?}"
}

set_secrets() {
  kubectl annotate secret --overwrite -n kube-system cray-k8s-encryption "$@"
}

# get/increment/set combo for the secret generation annotation
increment_secret_generation() {
  current="$(secret_generation)"
  set_secret_generation $((current + 1))
}

# Update all secret annotations, only called when all rewrites are successful
update_secret_annotations() {
  goal="$(secret_goal)"
  # Note --rfc-3339 depends on gnu date, won't work on a busybox container
  # time="$(date --rfc-3339=seconds)"
  time="$(date +%Y-%m-%d\ %H:%M:%S%z)"
  printf "Incrementing encryption generation\n"
  increment_secret_generation

  printf "Updating annotations: current=%s time=%s\n" "${goal}" "${time}"
  set_secrets "current=${goal}" "changed=${time}"
}

update_node_annotation() {
  val="${1?}"
  # This is for that $(nodename) in the if statement, it won't add much to quote
  # it so tell shellcheck in this instance be quiet.
  #shellcheck disable=SC2046
  if [ "${val}" != "$(kubectl get node $(nodename) -o jsonpath='{range .items[*]}{.metadata.annotations.cray-k8s-encryption}{"\n"}')" ]; then
    printf "Setting node encryption annotation to %s\n" "${val}"
    kubectl annotate node --overwrite "$(nodename)" "${PREFIX}=${1?}"
  fi
}

# Note: this line allows shellspec to source this script for unit testing functions above.
# DO NOT REMOVE IT!
# Ref: https://github.com/shellspec/shellspec#testing-shell-functions
${__SOURCED__:+return}

# Note: below the testing fold as there isn't much need to mock these commands
# as the functions that run commands are what is actually mocked not the
# commands proper
YQ="${YQ:-yq}"
JQ="${JQ:-jq}"
KUBECTL="${KUBECTL:-kubectl}"

YQ=$(command -v "${YQ}")
JQ=$(command -v "${JQ}")
KUBECTL=$(command -v "${KUBECTL}")

yq() {
  ${YQ} "$@"
}

jq() {
  ${JQ} "$@"
}

kubectl() {
  ${KUBECTL} "$@"
}

# especially since I am not a fan of the bash.
randint() {
  awk "BEGIN{\"date +%s\"|getline rseed;srand(rseed);close(\"date +%s\");printf \"%i\n\", (rand()*${1-10})}"
}

verbose() {
  if "${VERBOSE}"; then
    # This is acting like printf if verbose is set, so the $@ complaint is
    # pointless.
    #shellcheck disable=SC2059
    printf "$@"
  fi
}

# Effectively main() starts here:
if first_controlplane_node; then
  verbose "update node: %s\n" "$(nodename)"
else
  verbose "node: %s\n" "$(nodename)"
fi

while true; do
  # First up, as long as we're a control plane node, update annotations if they have changed.
  if nodename_updateable; then
    annotation="$(encryption_config_annotation)"
    verbose "Ensuring node %s has annotation %s\n" "$(nodename)" "${annotation}"
    update_node_annotation "${annotation}"
  fi

  # First control-plane node only
  #
  # If all the control-plane annotations agree with each other update the secret goal
  if first_controlplane_node; then
    if all_controlplane_nodes_online && can_update && [ "$(get_secret_goal)" != "$(secret_goal)" ]; then
      goal="$(get_secret_goal)"
      printf "Encryption goal differs from known write, setting goal to %s\n" "${goal}"
      set_secret_goal "${goal}"
    fi

    # If current isn't the goal, try to rewrite all secrets, starting with ours
    if all_controlplane_nodes_online && can_update && can_update_secret; then
      printf "Encryption goal %s is not current %s will update data\n" "$(secret_goal)" "$(secret_current)"

      if kubectl get secret cray-k8s-encryption -o json -n kube-system | kubectl replace -f -; then
        printf "Rewriting all secrets with current encryption key\n"
        if kubectl get secrets --all-namespaces -o json | kubectl replace -f - ; then
          printf "Success updating secret annotations\n"
          update_secret_annotations
        else
          printf "Failure\n"
        fi
      else
        printf "Couldn't rewrite this daemonset secret, not updating other data\n"
        exit 1
      fi
    fi
  fi

  # For testing purposes break out of the daemon loop if we aren't do daemonize
  if ! "${DAEMON}"; then
    break
  fi

  # Quoting this won't be very useful.
  #shellcheck disable=SC2086
  # Why not $RANDOM? That is bash only, non portable, and we run in busybox so
  # need portable options.
  tosleep="$(randint ${INTERVAL})"
  verbose "sleep %s\n" "${tosleep}"
  sleep "${tosleep}"
done
