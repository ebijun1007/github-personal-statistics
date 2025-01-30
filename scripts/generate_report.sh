#!/bin/bash

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" 1>&2
}

log "Starting GitHub Activity Report script"

#------------------------------------------------------
# 1. 前提チェック
#------------------------------------------------------
if [ -z "$GITHUB_TOKEN" ]; then
  log "Error: GITHUB_TOKEN is not set."
  exit 1
fi

# Authenticate GitHub CLI with the token
if [ -n "$GITHUB_TOKEN" ]; then
  echo "$GITHUB_TOKEN" | gh auth login --with-token || {
    log "Warning: Failed to authenticate with GitHub CLI using GITHUB_TOKEN"
  }
fi

# Verify GitHub CLI authentication
gh auth status || {
  log "Error: GitHub CLI is not authenticated"
  exit 1
}

if [ -z "$SLACK_WEBHOOK_URL" ]; then
  log "Error: SLACK_WEBHOOK_URL is not set."
  exit 1
fi

for goal in "MONTHLY_CODE_CHANGES_GOAL" "MONTHLY_PR_CREATION_GOAL" "MONTHLY_PR_MERGE_GOAL"; do
  if [ -z "${!goal}" ]; then
    log "Error: $goal is not set."
    exit 1
  fi
  if ! [[ "${!goal}" =~ ^[1-9][0-9]*$ ]]; then
    log "Error: $goal must be a positive integer."
    exit 1
  fi
done

#------------------------------------------------------
# 2. OS判定＆日付ユーティリティ
#------------------------------------------------------
IS_MACOS=false
if [[ "$(uname)" == "Darwin" ]]; then
  IS_MACOS=true
fi

get_date() {
  if $IS_MACOS; then
    case "$1" in
      "24h_ago")
        date -v-24H -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
      "month_start")
        date -v1d -v0H -v0M -v0S -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
      "days_in_month")
        days=$(cal "$(date +"%m")" "$(date +"%Y")" | awk 'NF {DAYS = $NF}; END {print DAYS}')
        echo "$days"
        ;;
      *)
        date -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
    esac
  else
    case "$1" in
      "24h_ago")
        date -d '24 hours ago' -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
      "month_start")
        date -d "$(date +%Y-%m-01)" -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
      "days_in_month")
        date -d "$(date +%Y-%m-01) +1 month -1 day" +%d
        ;;
      *)
        date -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
    esac
  fi
}

FROM_DATE=$(get_date "24h_ago")
CURRENT_DATE=$(get_date)
MONTH_START=$(get_date "month_start")
DAYS_IN_MONTH=$(get_date "days_in_month")
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

log "Time Ranges:"
log "- Daily Since: $FROM_DATE"
log "- Current: $CURRENT_DATE"
log "- Month Start: $MONTH_START"
log "- Remaining Days in Month: $REMAINING_DAYS"

#------------------------------------------------------
# 3. GitHubユーザー情報取得（自分のユーザー名＆ID）
#------------------------------------------------------
# USERNAME が未設定なら gh CLI から取得
if [ -z "$USERNAME" ]; then
  USERNAME=$(gh api user --jq '.login')
fi
log "Using GitHub username: $USERNAME"

USER_ID=$(gh api user --jq '.id')
log "User ID: $USER_ID"

#------------------------------------------------------
# 4. 自分の個人リポジトリ一覧（owner=USERNAME）取得
#------------------------------------------------------
# リポジトリ数が多い場合はpaginateが必要な場合もあります
USER_REPOS_JSON=$(gh api graphql -f query='
  query($owner: String!) {
    user(login: $owner) {
      repositories(first: 100, ownerAffiliations: OWNER, isFork: false) {
        nodes {
          name
        }
      }
    }
  }
' -F owner="$USERNAME")

USER_REPOS=$(echo "$USER_REPOS_JSON" | jq -r '.data.user.repositories.nodes[].name')
log "Personal repos found under $USERNAME: $USER_REPOS"

#======================================================
# ============= 集計変数（最終的に合計する）===========
#======================================================
TOTAL_DAILY_CHANGES=0
TOTAL_MONTHLY_CHANGES=0
TOTAL_DAILY_PRS_CREATED=0
TOTAL_DAILY_PRS_MERGED=0
TOTAL_MONTHLY_PRS_CREATED=0
TOTAL_MONTHLY_PRS_MERGED=0

#------------------------------------------------------
# 6. 変更行数集計用関数
#------------------------------------------------------
fetch_and_sum_code_changes() {
  local owner="$1"
  local repo="$2"
  local dailyFrom="$3"
  local monthlyFrom="$4"

  local commits_query='
    query($owner: String!, $repo: String!, $dailyFrom: GitTimestamp!, $monthlyFrom: GitTimestamp!) {
      daily: repository(owner: $owner, name: $repo) {
        defaultBranchRef {
          target {
            ... on Commit {
              history(first: 100, since: $dailyFrom) {
                nodes {
                  additions
                  deletions
                }
              }
            }
          }
        }
      }
      monthly: repository(owner: $owner, name: $repo) {
        defaultBranchRef {
          target {
            ... on Commit {
              history(first: 100, since: $monthlyFrom) {
                nodes {
                  additions
                  deletions
                }
              }
            }
          }
        }
      }
    }'
  fi

  local JSON=$(gh api graphql \
    -F owner="$owner" \
    -F repo="$repo" \
    -F dailyFrom="$dailyFrom" \
    -F monthlyFrom="$monthlyFrom" \
    -f query="$commits_query" 2>&1 || echo "")

  if [[ "$JSON" == *"Resource not accessible by integration"* ]]; then
    log "Error: Permission denied (HTTP 403) accessing repository $owner/$repo"
    log "Hint: Set GH_PAT with 'repo' and 'read:org' scopes in repository secrets"
    return 0
  fi

  # daily
  local daily_total=$(echo "$JSON" | jq '[.data.daily.defaultBranchRef?.target.history.nodes[]? | (.additions + .deletions)] | add // 0')
  # monthly
  local monthly_total=$(echo "$JSON" | jq '[.data.monthly.defaultBranchRef?.target.history.nodes[]? | (.additions + .deletions)] | add // 0')

  echo "$daily_total,$monthly_total"
}

#------------------------------------------------------
# 7. PR数集計用関数
#------------------------------------------------------
fetch_and_sum_prs() {
  local owner="$1"
  local repo="$2"
  local dailyFrom="$3"
  local monthlyFrom="$4"

  local pr_query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes {
            createdAt
            mergedAt
          }
        }
      }
    }'
  fi

  local JSON=$(gh api graphql \
    -F owner="$owner" \
    -F repo="$repo" \
    -f query="$pr_query" 2>&1 || echo "")

  if [[ "$JSON" == *"Resource not accessible by integration"* ]]; then
    log "Error: Permission denied (HTTP 403) accessing repository $owner/$repo"
    log "Hint: Set GH_PAT with 'repo' and 'read:org' scopes in repository secrets"
    return 0
  fi

  local daily_created=$(echo "$JSON" | jq --arg from "$dailyFrom" '[.data.repository.pullRequests.nodes[]? | select(.createdAt >= $from)] | length')
  local daily_merged=$(echo "$JSON" | jq --arg from "$dailyFrom" '[.data.repository.pullRequests.nodes[]? | select(.mergedAt != null and .mergedAt >= $from)] | length')
  local monthly_created=$(echo "$JSON" | jq --arg from "$monthlyFrom" '[.data.repository.pullRequests.nodes[]? | select(.createdAt >= $from)] | length')
  local monthly_merged=$(echo "$JSON" | jq --arg from "$monthlyFrom" '[.data.repository.pullRequests.nodes[]? | select(.mergedAt != null and .mergedAt >= $from)] | length')

  echo "$daily_created,$daily_merged,$monthly_created,$monthly_merged"
}

#------------------------------------------------------
# 8. リポジトリ集計
#------------------------------------------------------
for repo in $USER_REPOS
do
  changes_csv=$(fetch_and_sum_code_changes "$USERNAME" "$repo" "$FROM_DATE" "$MONTH_START")
  IFS=',' read -r dC mC <<< "$changes_csv"

  TOTAL_DAILY_CHANGES=$((TOTAL_DAILY_CHANGES + dC))
  TOTAL_MONTHLY_CHANGES=$((TOTAL_MONTHLY_CHANGES + mC))

  prs_csv=$(fetch_and_sum_prs "$USERNAME" "$repo" "$FROM_DATE" "$MONTH_START")
  IFS=',' read -r dPRC dPRM mPRC mPRM <<< "$prs_csv"

  TOTAL_DAILY_PRS_CREATED=$((TOTAL_DAILY_PRS_CREATED + dPRC))
  TOTAL_DAILY_PRS_MERGED=$((TOTAL_DAILY_PRS_MERGED + dPRM))
  TOTAL_MONTHLY_PRS_CREATED=$((TOTAL_MONTHLY_PRS_CREATED + mPRC))
  TOTAL_MONTHLY_PRS_MERGED=$((TOTAL_MONTHLY_PRS_MERGED + mPRM))
done

#------------------------------------------------------
# 10. 目標に対する進捗率計算
#------------------------------------------------------
if ! command -v bc &>/dev/null; then
  log "Error: bc command not found"
  exit 1
fi

calc_progress() {
  local current="$1"
  local goal="$2"
  if [[ "$goal" -eq 0 ]]; then
    echo "0.00"
  else
    printf "%.2f" "$(echo "scale=2; $current * 100 / $goal" | bc)"
  fi
}

CHANGES_PROGRESS=$(calc_progress "$TOTAL_MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
PR_CREATION_PROGRESS=$(calc_progress "$TOTAL_MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
PR_MERGE_PROGRESS=$(calc_progress "$TOTAL_MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

#------------------------------------------------------
# 11. Slack通知
#------------------------------------------------------
log "Creating Slack payload..."
PAYLOAD=$(jq -n \
  --arg daily_changes "$TOTAL_DAILY_CHANGES" \
  --arg daily_prs_created "$TOTAL_DAILY_PRS_CREATED" \
  --arg daily_prs_merged "$TOTAL_DAILY_PRS_MERGED" \
  --arg monthly_changes "$TOTAL_MONTHLY_CHANGES" \
  --arg monthly_goal "$MONTHLY_CODE_CHANGES_GOAL" \
  --arg changes_progress "$CHANGES_PROGRESS" \
  --arg monthly_prs_created "$TOTAL_MONTHLY_PRS_CREATED" \
  --arg pr_creation_goal "$MONTHLY_PR_CREATION_GOAL" \
  --arg pr_creation_progress "$PR_CREATION_PROGRESS" \
  --arg monthly_prs_merged "$TOTAL_MONTHLY_PRS_MERGED" \
  --arg pr_merge_goal "$MONTHLY_PR_MERGE_GOAL" \
  --arg pr_merge_progress "$PR_MERGE_PROGRESS" \
  --arg remaining_days "$REMAINING_DAYS" \
  '{
    "blocks": [
      {
        "type": "header",
        "text": {
          "type": "plain_text",
          "text": "📊 GitHub Activity Report"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Today'\''s Total Activity*\n• Code Changes: \($daily_changes) lines\n• PRs Created: \($daily_prs_created)\n• PRs Merged: \($daily_prs_merged)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Monthly Total*\n• Code Changes: \($monthly_changes)/\($monthly_goal) (\($changes_progress)%)\n• PRs Created: \($monthly_prs_created)/\($pr_creation_goal) (\($pr_creation_progress)%)\n• PRs Merged: \($monthly_prs_merged)/\($pr_merge_goal) (\($pr_merge_progress)%)\n*Remaining Days in Month: \($remaining_days)*"
        }
      }
    ]
  }')

log "Slack payload:"
echo "$PAYLOAD" | jq '.'

log "Sending notification to Slack..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H 'Content-type: application/json' \
    --data "$PAYLOAD" "$SLACK_WEBHOOK_URL")
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

log "Slack API Response:"
log "- Status Code: $HTTP_STATUS"
log "- Response Body: $RESPONSE_BODY"

if [ "$HTTP_STATUS" -ne 200 ]; then
  log "Error: Failed to send Slack notification (HTTP $HTTP_STATUS)"
  exit 1
fi

log "Successfully completed GitHub Activity Report"
