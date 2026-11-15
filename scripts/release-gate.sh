#!/usr/bin/env bash
# release-gate.sh — Release gate and deploy steps for `promotion: manual` workflows.
#
# generate-workflow.sh inlines this file into the generated deploy.yml, promote.yml
# and rollback.yml: the first step of a job writes it to $RUNNER_TEMP/release-gate.sh
# and sources it, later steps source that copy. The target repo needs no extra file,
# and test/test-release-gate.sh runs this same text against recorded API answers
# with stub gh, curl and docker on PATH.
#
# Environment (set by the generated workflow):
#   REPO                owner/name (github.repository)
#   GH_TOKEN            token for `gh api` (github.token)
#   COOLIFY_URL         Coolify root URL; COOLIFY_API_KEY its Bearer token
#   RUN_URL             link to the workflow run, kept in each deployment record
#   SMOKE_COMMAND       optional smoke command; {url} is replaced by the app URL
#   GITHUB_OUTPUT       step outputs (optional outside Actions)
#   GITHUB_STEP_SUMMARY run summary (optional outside Actions)
#   RG_NOW              epoch seconds to use as "now" (tests only)
#
# Each gate function prints what it decided, writes step outputs with rg_out, and
# returns 1 after a REFUSED line when the release must stop. A superseded commit is
# not an error: the function writes proceed=false and returns 0.
#
# This file must never contain a dollar sign followed by two opening braces: GitHub
# Actions would expand it as an expression inside the generated workflows.

set -euo pipefail

# The record payload, whether GitHub returns it as an object or a JSON string.
RG_PAYLOAD='(.payload | if type == "string" then (try fromjson catch {}) else (. // {}) end)'
RG_TAG=""
RG_SHA=""
export RG_TAG RG_SHA   # read by the generated rollback.yml after gate_rollback

# ── Output helpers ─────────────────────────────────────────────────────────────

rg_out() {  # rg_out KEY VALUE — a step output, echoed to the log too
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

rg_note() {  # rg_note TEXT — a line in the log and in the run summary
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

rg_refuse() {  # rg_refuse TEXT — explain why the release stops; the caller returns 1
  echo "REFUSED: $*" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "**Refused:** $*" >> "$GITHUB_STEP_SUMMARY"; fi
  return 0
}

rg_now() { echo "${RG_NOW:-$(date -u +%s)}"; }

rg_valid_tag() { [[ "$1" =~ ^[0-9a-f]{7}$ ]]; }

# ── Deployment records (GitHub Deployments API) ────────────────────────────────

record_list() {  # record_list ENV — the newest 100 deployment records of ENV, newest first
  gh api "repos/$REPO/deployments?environment=$1&per_page=100"
}

record_state() {  # record_state ID — newest status that is not "inactive", or "none"
  gh api "repos/$REPO/deployments/$1/statuses?per_page=100" \
    | jq -r '[.[] | select(.state != "inactive")][0].state // "none"'
}

record_success_at() {  # record_success_at ID — time of the newest success status
  gh api "repos/$REPO/deployments/$1/statuses?per_page=100" \
    | jq -r '[.[] | select(.state == "success")][0].created_at // empty'
}

records_successful() {  # records_successful ENV — "id<TAB>tag<TAB>replaced_tag" per successful record, newest first
  local env="$1" list id tag replaced state
  list=$(record_list "$env") || return 1
  while IFS=$'\t' read -r id tag replaced; do
    [ -n "$id" ] || continue
    state=$(record_state "$id") || return 1
    if [ "$state" = "success" ]; then
      printf '%s\t%s\t%s\n' "$id" "$tag" "$replaced"
    fi
  done < <(jq -r "limit(30; .[]) | [.id, ($RG_PAYLOAD.image_tag // \"\"), ($RG_PAYLOAD.replaced_tag // \"\")] | @tsv" <<< "$list")
}

record_create() {  # record_create ENV SHA KIND TAG DIGEST REPLACED STARTED_BY — prints the new record id
  local body id
  body=$(jq -n --arg ref "$2" --arg env "$1" --arg kind "$3" --arg tag "$4" \
    --arg digest "$5" --arg replaced "$6" --arg by "$7" --arg run "${RUN_URL:-}" '{
      ref: $ref, environment: $env, auto_merge: false, required_contexts: [],
      production_environment: ($env == "production"), transient_environment: false,
      description: ($kind + " " + $tag + " to " + $env),
      payload: {image_tag: $tag, digest: $digest, kind: $kind, started_by: $by,
                replaced_tag: $replaced, run_url: $run}}')
  id=$(gh api -X POST "repos/$REPO/deployments" --input - <<< "$body" | jq -r '.id // empty') || id=""
  if [ -z "$id" ]; then
    rg_refuse "GitHub did not create the $1 deployment record for $4. Nothing was deployed."
    return 1
  fi
  echo "$id"
}

record_status() {  # record_status ID STATE DESCRIPTION — success statuses keep older records "success"
  local body
  body=$(jq -n --arg s "$2" --arg d "$3" --arg log "${RUN_URL:-}" \
    '{state: $s, description: ($d | .[0:140]), auto_inactive: false}
     + (if $log == "" then {} else {log_url: $log} end)')
  gh api -X POST "repos/$REPO/deployments/$1/statuses" --input - <<< "$body" >/dev/null
  echo "record $1: $2 ($3)"
}

release_begin() {  # release_begin ENV SHA KIND TAG DIGEST REPLACED STARTED_BY — record in_progress
  local id
  id=$(record_create "$@") || return 1
  record_status "$id" in_progress "Deploying $4 to $1" >/dev/null
  echo "OK   $1 record $id created (kind $3, tag $4, replaced ${6:-none})"
  rg_out record_id "$id"
}

# ── Gate checks ────────────────────────────────────────────────────────────────

gate_tip() {  # gate_tip SHA BRANCH — 0 if SHA is the tip of BRANCH, 10 if superseded, 1 on error
  local sha="$1" branch="$2" tip
  tip=$(gh api "repos/$REPO/branches/$branch" | jq -r '.commit.sha // empty') || tip=""
  if [ -z "$tip" ]; then
    rg_refuse "could not read the tip of $branch from GitHub. Nothing was deployed; re-run later."
    return 1
  fi
  if [ "$tip" != "$sha" ]; then
    rg_note "Superseded by ${tip:0:7}: ${sha:0:7} is no longer the tip of $branch. Nothing was deployed."
    return 10
  fi
  echo "OK   ${sha:0:7} is the tip of $branch"
}

gate_ci() {  # gate_ci EVENT HEAD_BRANCH CONCLUSION SHA CI_URL BRANCH — CI passed on a push to BRANCH
  local event="$1" head_branch="$2" conclusion="$3" sha="$4" url="$5" branch="$6"
  if [ "$event" != "push" ] || [ "$head_branch" != "$branch" ]; then
    rg_refuse "the CI run for ${sha:0:7} was a '$event' on '$head_branch', not a push to $branch ($url). Nothing was deployed."
    return 1
  fi
  if [ "$conclusion" != "success" ]; then
    rg_refuse "CI concluded '$conclusion' for ${sha:0:7} ($url). Nothing was deployed."
    return 1
  fi
  echo "OK   CI succeeded for ${sha:0:7} ($url)"
}

gate_merged_pr() {  # gate_merged_pr SHA BRANCH — SHA is the merge commit of a merged pull request
  local sha="$1" branch="$2" pulls pr
  if ! pulls=$(gh api "repos/$REPO/commits/$sha/pulls"); then
    rg_refuse "could not ask GitHub which pull request introduced ${sha:0:7}. Nothing was deployed; re-run later."
    return 1
  fi
  pr=$(jq -r --arg sha "$sha" \
    '[.[] | select(.merged_at != null and .merge_commit_sha == $sha)][0].number // empty' <<< "$pulls")
  if [ -z "$pr" ]; then
    rg_refuse "${sha:0:7} was pushed to $branch directly, not merged from a pull request. Revert it, or open a PR with the change. Nothing was deployed."
    return 1
  fi
  echo "OK   ${sha:0:7} is the merge commit of PR #$pr"
}

gate_merge() {  # gate_merge BRANCH — the deploy.yml gate: tip of BRANCH first, then CI, then merged PR
  # Reads EVENT_NAME, HEAD_SHA, CI_EVENT, CI_HEAD_BRANCH, CI_CONCLUSION, CI_URL.
  local branch="$1" rc=0
  if [ "${EVENT_NAME:-}" != "workflow_run" ]; then
    echo "Event '${EVENT_NAME:-}': drift check only. Nothing is built or deployed."
    rg_out proceed false
    return 0
  fi
  # The tip check comes first: CI cancels an older run on BRANCH when a newer one starts,
  # and that cancelled run must end as superseded, not as a failed deploy.
  gate_tip "$HEAD_SHA" "$branch" || rc=$?
  if [ "$rc" -eq 10 ]; then rg_out proceed false; return 0; fi
  if [ "$rc" -ne 0 ]; then return 1; fi
  gate_ci "${CI_EVENT:-}" "${CI_HEAD_BRANCH:-}" "${CI_CONCLUSION:-}" "$HEAD_SHA" "${CI_URL:-}" "$branch" || return 1
  gate_merged_pr "$HEAD_SHA" "$branch" || return 1
  rg_out proceed true
  rg_out sha "$HEAD_SHA"
  rg_out tag "${HEAD_SHA:0:7}"
}

stage_begin() {  # stage_begin SHA BRANCH TAG DIGEST REPLACED STARTED_BY — tip re-check, then the staging record
  local sha="$1" branch="$2" rc=0
  gate_tip "$sha" "$branch" || rc=$?
  if [ "$rc" -eq 10 ]; then rg_out proceed false; return 0; fi
  if [ "$rc" -ne 0 ]; then return 1; fi
  release_begin staging "$sha" merge "$3" "$4" "$5" "$6" || return 1
  rg_out proceed true
}

gate_actor() {  # gate_actor ACTOR "OWNER..." — the person who started the run is a release owner
  local actor="$1" owner
  for owner in $2; do
    if [ "$owner" = "$actor" ]; then
      echo "OK   $actor is a release owner"
      return 0
    fi
  done
  rg_refuse "$actor is not a release owner (release_owners: $2). Only a release owner can promote or roll back. Nothing was deployed."
  return 1
}

coolify_app_tag() {  # coolify_app_tag UUID — the image tag a Coolify app is set to run
  local tag
  tag=$(curl -sfS --retry 3 --retry-delay 2 "$COOLIFY_URL/api/v1/applications/$1" \
    -H "Authorization: Bearer $COOLIFY_API_KEY" | jq -r '.docker_registry_image_tag // empty') || tag=""
  if [ -z "$tag" ]; then
    rg_refuse "could not read the image tag of Coolify app $1. Nothing was deployed."
    return 1
  fi
  echo "$tag"
}

resolve_sha() {  # resolve_sha TAG — the full commit SHA for a 7-character tag
  local sha
  sha=$(gh api "repos/$REPO/commits/$1" | jq -r '.sha // empty') || sha=""
  if [ -z "$sha" ]; then
    rg_refuse "no commit $1 in $REPO. Nothing was deployed."
    return 1
  fi
  echo "$sha"
}

gate_promote() {  # gate_promote STAGING_TAG INPUT_TAG PROD_TAG — the image staging runs, verified there
  local staging_tag="$1" input="$2" prod_tag="$3" list rec id state at age smoke=true
  if [ -n "$input" ]; then
    if ! rg_valid_tag "$input"; then
      rg_refuse "tag '$input' is not a 7-character commit tag. Nothing was deployed."
      return 1
    fi
    if [ "$input" != "$staging_tag" ]; then
      rg_refuse "$input is not the image staging runs now ($staging_tag). Promotion takes the staging image; to put an older image on production, run Roll back with that tag. Nothing was deployed."
      return 1
    fi
  fi
  if [ "$staging_tag" = "$prod_tag" ]; then
    rg_refuse "production already runs $staging_tag. Nothing to promote."
    return 1
  fi
  if ! list=$(record_list staging); then
    rg_refuse "could not read the staging deployment records. Nothing was deployed; re-run later."
    return 1
  fi
  rec=$(jq -c --arg t "$staging_tag" "[.[] | select($RG_PAYLOAD.image_tag == \$t)][0] // empty" <<< "$list")
  if [ -z "$rec" ]; then
    rg_refuse "$staging_tag has no staging deployment record, so deploy.yml did not deploy and check it on staging. Nothing was deployed."
    return 1
  fi
  id=$(jq -r '.id' <<< "$rec")
  state=$(record_state "$id") || return 1
  if [ "$state" != "success" ]; then
    rg_refuse "the staging record for $staging_tag is '$state', not success. Nothing was deployed."
    return 1
  fi
  at=$(record_success_at "$id")
  age=$(( $(rg_now) - $(date -u -d "$at" +%s) ))
  if [ "$age" -lt 86400 ]; then smoke=false; fi
  RG_TAG="$staging_tag"
  RG_SHA=$(jq -r '.sha' <<< "$rec")
  echo "OK   $staging_tag runs on staging and its staging record $id succeeded at $at"
  rg_out tag "$staging_tag"
  rg_out sha "$RG_SHA"
  rg_out digest "$(jq -r "$RG_PAYLOAD.digest // \"\"" <<< "$rec")"
  rg_out replaced_tag "$prod_tag"
  rg_out smoke_staging "$smoke"
}

gate_rollback() {  # gate_rollback ENV CURRENT_TAG INPUT_TAG — an image ENV ran before
  local env="$1" current="$2" input="$3" ok newest newest_tag newest_replaced target
  if [ "$env" != "staging" ] && [ "$env" != "production" ]; then
    rg_refuse "environment '$env' is not staging or production. Nothing was deployed."
    return 1
  fi
  if ! ok=$(records_successful "$env"); then
    rg_refuse "could not read the $env deployment records. Nothing was deployed; re-run later."
    return 1
  fi
  if [ -z "$ok" ]; then
    rg_refuse "no successful $env release is recorded, so there is nothing to roll back to. Nothing was deployed."
    return 1
  fi
  newest=$(head -n 1 <<< "$ok")
  newest_tag=$(cut -f2 <<< "$newest")
  newest_replaced=$(cut -f3 <<< "$newest")
  if [ -z "$input" ]; then
    if [ "$newest_tag" != "$current" ]; then
      # A release after the newest successful one failed part-way: go back to that success.
      target="$newest_tag"
      echo "$env runs $current, which has no successful record; going back to the last successful release"
    else
      target="$newest_replaced"
    fi
    if [ -z "$target" ]; then
      rg_refuse "the current $env record for $current names no image it replaced. Run Roll back with a tag. Nothing was deployed."
      return 1
    fi
  else
    if ! rg_valid_tag "$input"; then
      rg_refuse "tag '$input' is not a 7-character commit tag. Nothing was deployed."
      return 1
    fi
    if ! awk -F'\t' -v t="$input" '$2 == t || $3 == t { found = 1 } END { exit !found }' <<< "$ok"; then
      rg_refuse "$input never ran on $env: no successful $env record has it or replaced it. Nothing was deployed."
      return 1
    fi
    target="$input"
  fi
  if [ "$target" = "$current" ]; then
    rg_refuse "$env already runs $target. Nothing to roll back."
    return 1
  fi
  RG_TAG="$target"
  RG_SHA=$(resolve_sha "$target") || return 1
  echo "OK   roll $env back from $current to $target"
  rg_out tag "$target"
  rg_out sha "$RG_SHA"
  rg_out replaced_tag "$current"
}

drift_production() {  # drift_production PROD_TAG — production runs its newest successful release
  local ok newest
  if ! ok=$(records_successful production); then
    rg_refuse "could not read the production deployment records."
    return 1
  fi
  if [ -z "$ok" ]; then
    echo "SKIP drift: no production release recorded yet"
    return 0
  fi
  newest=$(head -n 1 <<< "$ok" | cut -f2)
  if [ "$newest" != "$1" ]; then
    rg_refuse "production runs $1, but its newest successful release is $newest: someone changed production outside promote.yml and rollback.yml. Promote or roll back to put it right."
    return 1
  fi
  echo "OK   production runs $1, its newest successful release"
}

# ── Registry (GHCR) ────────────────────────────────────────────────────────────

image_digest() {  # image_digest IMAGE TAG — the digest of IMAGE:TAG; fails if it is not in the registry
  local digest
  digest=$(docker buildx imagetools inspect "$1:$2" --format '{{json .Manifest}}' 2>/dev/null \
    | jq -r '.digest // empty') || digest=""
  if [ -z "$digest" ]; then
    rg_refuse "image $1:$2 is not in the registry (deleted by clean-up?). Nothing was deployed."
    return 1
  fi
  echo "$digest"
}

retag() {  # retag IMAGE SOURCE_TAG NEW_TAG — add a tag; the digest does not change
  docker buildx imagetools create -t "$1:$3" "$1:$2"
}

keep_regex() {  # keep_regex IMAGE TAG... — anchored regex of every digest the kept tags need
  # A container package version is named by its digest, not its tags. An image index
  # also holds platform and attestation manifests, listed as untagged versions; deleting
  # one of those breaks the image, so they are kept too.
  local image="$1" tag manifest digests="" list
  shift
  for tag in "$@"; do
    if ! manifest=$(docker buildx imagetools inspect "$image:$tag" --format '{{json .Manifest}}'); then
      rg_refuse "$image:$tag is not in the registry, so clean-up cannot tell what to keep. Nothing was deleted."
      return 1
    fi
    digests+=$(jq -r '.digest, ((.manifests // [])[] | .digest)' <<< "$manifest")$'\n'
  done
  list=$(printf '%s' "$digests" | grep -E '^sha256:[0-9a-f]{64}$' | sort -u | paste -sd '|' -) || list=""
  if [ -z "$list" ]; then
    rg_refuse "no digest to keep was found. Nothing was deleted."
    return 1
  fi
  echo "^($list)$"
}

# ── Coolify deploy and checks ──────────────────────────────────────────────────

coolify_set_tag() {  # coolify_set_tag UUID TAG
  echo "Setting image tag $2 on Coolify app $1"
  curl -sfS -X PATCH "$COOLIFY_URL/api/v1/applications/$1" \
    -H "Authorization: Bearer $COOLIFY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"docker_registry_image_tag\":\"$2\"}" >/dev/null
}

coolify_deploy_wait() {  # coolify_deploy_wait UUID LABEL — deploy and wait up to 6 minutes
  local response deployment status i
  response=$(curl -sfS "$COOLIFY_URL/api/v1/deploy?uuid=$1&force=false" \
    -H "Authorization: Bearer $COOLIFY_API_KEY")
  deployment=$(jq -r '.deployments[0].deployment_uuid' <<< "$response")
  echo "Triggered $2 deploy: deployment_uuid=$deployment"
  sleep 5
  for i in $(seq 1 36); do
    status=$(curl -sfS "$COOLIFY_URL/api/v1/deployments/$deployment" \
      -H "Authorization: Bearer $COOLIFY_API_KEY" | jq -r '.status' 2>/dev/null || echo "unknown")
    echo "[$i/36] status=$status"
    if [ "$status" = "finished" ]; then
      echo "Coolify deploy finished"
      return 0
    elif [ "$status" = "failed" ] || [ "$status" = "cancelled" ]; then
      echo "Coolify deploy $status: deployment_uuid=$deployment (see $COOLIFY_URL)" >&2
      return 1
    fi
    sleep 10
  done
  echo "Coolify deploy timed out after 6 minutes: deployment_uuid=$deployment (see $COOLIFY_URL)" >&2
  return 1
}

wait_healthy() {  # wait_healthy URL LABEL — URL answers within 6 minutes
  local i
  for i in $(seq 1 12); do
    sleep 30
    if curl -sfS "$1" -o /dev/null; then
      echo "$2 healthy on attempt $i"
      return 0
    fi
    echo "Wait $i/12 ..."
  done
  echo "$2 did not respond within 6min" >&2
  return 1
}

assert_version() {  # assert_version URL TAG — the health body's version is sha-TAG (skipped if absent)
  local version
  version=$(curl -sfS "$1" | jq -r '.version // empty')
  if [ -z "$version" ]; then
    echo "SKIP version-assert: health response has no 'version' field"
  elif [ "$version" = "sha-$2" ]; then
    echo "OK   version-assert: version=$version"
  else
    echo "FAIL version-assert: expected=sha-$2 actual=$version" >&2
    return 1
  fi
}

run_smoke() {  # run_smoke URL — SMOKE_COMMAND with {url} replaced by URL; skipped when unset
  local cmd
  if [ -z "${SMOKE_COMMAND:-}" ]; then
    echo "SKIP smoke: no smoke_command in coolify.yaml"
    return 0
  fi
  cmd="${SMOKE_COMMAND//\{url\}/$1}"
  echo "Running smoke: $cmd"
  bash -euo pipefail -c "$cmd"
}
