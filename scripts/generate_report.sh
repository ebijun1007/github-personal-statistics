#!/bin/bash

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" 1>&2
}

log "Starting GitHub Activity Report script"

# 必要な環境変数の確認
for var in "GITHUB_TOKEN" "SLACK_WEBHOOK_URL" "USERNAME"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set"
        exit 1
    fi
    log "Confirmed $var is set"
done

# 月間目標値の確認
for goal in "MONTHLY_CODE_CHANGES_GOAL" "MONTHLY_PR_CREATION_GOAL" "MONTHLY_PR_MERGE_GOAL"; do
    if [ -z "${!goal}" ]; then
        log "Error: $goal is not set"
        exit 1
    fi
    if ! [[ "${!goal}" =~ ^[1-9][0-9]*$ ]]; then
        log "Error: $goal must be a positive integer"
        exit 1
    fi
    log "$goal is set to ${!goal}"
done

# 過去24時間の期間を設定
FROM_DATE=$(date -d '24 hours ago' -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MONTH_START=$(date -d "$(date +%Y-%m-01)" -u +"%Y-%m-%dT%H:%M:%SZ")

log "Time ranges:"
log "- From: $FROM_DATE"
log "- Current: $CURRENT_DATE"
log "- Month Start: $MONTH_START"

###
### 1. ユーザーが所属するオーガニゼーション一覧を取得
###
ORGS_QUERY=$(gh api graphql -f query='
  query($user: String!) {
    user(login: $user) {
      organizations(first: 100) {
        nodes {
          login
        }
      }
    }
  }
' -f user="$USERNAME")

ORGS=$(echo "$ORGS_QUERY" | jq -r '.data.user.organizations.nodes[].login')
if [ -z "$ORGS" ]; then
  log "No organizations found for user $USERNAME."
  ORGS=()  # 空配列
fi

log "Found Organizations: $(echo "$ORGS" | xargs)"

###
### 2. コミット数・コード変更行数を「オーガニゼーション別」と「合計」で集計
###
TOTAL_DAILY_CHANGES=0
TOTAL_MONTHLY_CHANGES=0

# 計算用のヘルパー関数
calculate_changes() {
    local json="$1"
    local since="$2"
    echo "$json" | jq --raw-output --arg since "$since" '
      [ 
        .data.organization.repositories.nodes[]?
        | select(.defaultBranchRef != null)
        | .defaultBranchRef.target.history.nodes[]?
        | select(.committedDate >= $since)
        | (.additions + .deletions)
      ] | add // 0
    '
}

# オーガニゼーションごとの集計を保存する配列
declare -A ORG_DAILY_CHANGES
declare -A ORG_MONTHLY_CHANGES

for org in $ORGS
do
  # オーガニゼーション内のリポジトリからコード変更行数を取得
  # リポジトリが多い場合はfirst: 100 など必要に応じて変更
  # (大規模オーガニゼーションでは paginate が必要になる場合も)
  STATS_JSON=$(gh api graphql -f query='
    query($org: String!, $dailyFrom: DateTime!, $monthFrom: DateTime!) {
      organization(login: $org) {
        repositories(first: 100, ownerAffiliations: OWNER) {
          nodes {
            defaultBranchRef {
              target {
                ... on Commit {
                  history(first: 100) {
                    nodes {
                      additions
                      deletions
                      committedDate
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  ' -f org="$org" -f dailyFrom="$FROM_DATE" -f monthFrom="$MONTH_START")

  # Daily
  DAILY_CHANGES=$(calculate_changes "$STATS_JSON" "$FROM_DATE")
  # Monthly
  MONTHLY_CHANGES=$(calculate_changes "$STATS_JSON" "$MONTH_START")

  ORG_DAILY_CHANGES["$org"]=$DAILY_CHANGES
  ORG_MONTHLY_CHANGES["$org"]=$MONTHLY_CHANGES

  # 合計に加算
  TOTAL_DAILY_CHANGES=$((TOTAL_DAILY_CHANGES + DAILY_CHANGES))
  TOTAL_MONTHLY_CHANGES=$((TOTAL_MONTHLY_CHANGES + MONTHLY_CHANGES))
done

###
### 3. PR統計(作成/マージ)を「オーガニゼーション別」と「合計」で集計
###
TOTAL_DAILY_PRS_CREATED=0
TOTAL_DAILY_PRS_MERGED=0
TOTAL_MONTHLY_PRS_CREATED=0
TOTAL_MONTHLY_PRS_MERGED=0

declare -A ORG_DAILY_PRS_CREATED
declare -A ORG_DAILY_PRS_MERGED
declare -A ORG_MONTHLY_PRS_CREATED
declare -A ORG_MONTHLY_PRS_MERGED

# bc のチェック
if ! command -v bc &> /dev/null; then
  log "Error: bc command not found"
  exit 1
fi

# オーガニゼーション別にPRを取得
for org in $ORGS
do
  PRS_JSON=$(gh api graphql -f query='
    query($org: String!) {
      organization(login: $org) {
        repositories(first: 100, ownerAffiliations: OWNER) {
          nodes {
            pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes {
                createdAt
                mergedAt
                state
              }
            }
          }
        }
      }
    }
  ' -f org="$org")

  # Daily Created
  DC=$(echo "$PRS_JSON" | jq --arg from "$FROM_DATE" '
    [
      .data.organization.repositories.nodes[]?.pullRequests.nodes[]?
      | select(.createdAt >= $from)
    ] | length
  ')
  # Daily Merged
  DM=$(echo "$PRS_JSON" | jq --arg from "$FROM_DATE" '
    [
      .data.organization.repositories.nodes[]?.pullRequests.nodes[]?
      | select(.mergedAt != null and .mergedAt >= $from)
    ] | length
  ')
  # Monthly Created
  MC=$(echo "$PRS_JSON" | jq --arg from "$MONTH_START" '
    [
      .data.organization.repositories.nodes[]?.pullRequests.nodes[]?
      | select(.createdAt >= $from)
    ] | length
  ')
  # Monthly Merged
  MM=$(echo "$PRS_JSON" | jq --arg from "$MONTH_START" '
    [
      .data.organization.repositories.nodes[]?.pullRequests.nodes[]?
      | select(.mergedAt != null and .mergedAt >= $from)
    ] | length
  ')

  ORG_DAILY_PRS_CREATED["$org"]=$DC
  ORG_DAILY_PRS_MERGED["$org"]=$DM
  ORG_MONTHLY_PRS_CREATED["$org"]=$MC
  ORG_MONTHLY_PRS_MERGED["$org"]=$MM

  TOTAL_DAILY_PRS_CREATED=$((TOTAL_DAILY_PRS_CREATED + DC))
  TOTAL_DAILY_PRS_MERGED=$((TOTAL_DAILY_PRS_MERGED + DM))
  TOTAL_MONTHLY_PRS_CREATED=$((TOTAL_MONTHLY_PRS_CREATED + MC))
  TOTAL_MONTHLY_PRS_MERGED=$((TOTAL_MONTHLY_PRS_MERGED + MM))
done

###
### 4. 進捗率計算
###
calculate_progress() {
    local current="$1"
    local goal="$2"
    if [ "$goal" -eq 0 ]; then
        echo "0.00"
    else
        printf "%.2f" "$(echo "scale=2; $current * 100 / $goal" | bc)"
    fi
}

MONTHLY_CHANGES_PROGRESS=$(calculate_progress "$TOTAL_MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
MONTHLY_PR_CREATION_PROGRESS=$(calculate_progress "$TOTAL_MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
MONTHLY_PR_MERGE_PROGRESS=$(calculate_progress "$TOTAL_MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

DAYS_IN_MONTH=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

###
### 5. Slack通知ブロック作成
###
log "Creating Slack payload..."

# オーガニゼーション毎のブロックを作成
ORG_BLOCKS=()
for org in $ORGS
do
  DAILY_LINES="${ORG_DAILY_CHANGES[$org]}"
  MONTHLY_LINES="${ORG_MONTHLY_CHANGES[$org]}"
  DAILY_CREATED="${ORG_DAILY_PRS_CREATED[$org]}"
  DAILY_MERGED="${ORG_DAILY_PRS_MERGED[$org]}"
  MONTHLY_CREATED="${ORG_MONTHLY_PRS_CREATED[$org]}"
  MONTHLY_MERGED="${ORG_MONTHLY_PRS_MERGED[$org]}"

  ORG_BLOCK=$(jq -n \
    --arg org "$org" \
    --arg dc "$DAILY_LINES" \
    --arg mc "$MONTHLY_LINES" \
    --arg dprc "$DAILY_CREATED" \
    --arg dprm "$DAILY_MERGED" \
    --arg mprc "$MONTHLY_CREATED" \
    --arg mprm "$MONTHLY_MERGED" \
    '{
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Organization: \($org)*\n• Daily Changes: \($dc) lines\n• Monthly Changes: \($mc) lines\n• Daily PRs Created: \($dprc)\n• Daily PRs Merged: \($dprm)\n• Monthly PRs Created: \($mprc)\n• Monthly PRs Merged: \($mprm)"
      }
    }'
  )

  ORG_BLOCKS+=( "$ORG_BLOCK" )
done

# 組み立て用に配列をJSON配列に変換
ORG_BLOCKS_JSON=$(printf '%s\n' "${ORG_BLOCKS[@]}" | jq -s '.')

# 最終的なブロック
PAYLOAD=$(jq -n \
  --arg daily_changes "$TOTAL_DAILY_CHANGES" \
  --arg daily_prs_created "$TOTAL_DAILY_PRS_CREATED" \
  --arg daily_prs_merged "$TOTAL_DAILY_PRS_MERGED" \
  --arg monthly_changes "$TOTAL_MONTHLY_CHANGES" \
  --arg monthly_goal "$MONTHLY_CODE_CHANGES_GOAL" \
  --arg changes_progress "$MONTHLY_CHANGES_PROGRESS" \
  --arg monthly_prs_created "$TOTAL_MONTHLY_PRS_CREATED" \
  --arg pr_creation_goal "$MONTHLY_PR_CREATION_GOAL" \
  --arg pr_creation_progress "$MONTHLY_PR_CREATION_PROGRESS" \
  --arg monthly_prs_merged "$TOTAL_MONTHLY_PRS_MERGED" \
  --arg pr_merge_goal "$MONTHLY_PR_MERGE_GOAL" \
  --arg pr_merge_progress "$MONTHLY_PR_MERGE_PROGRESS" \
  --arg remaining_days "$REMAINING_DAYS" \
  --argjson org_blocks "$ORG_BLOCKS_JSON" \
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
      }
    ]
  }
  +
  {
    "blocks": (
      .blocks + $org_blocks + [
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "*Monthly Total Progress*\n• Code Changes: \($monthly_changes)/\($monthly_goal) (\($changes_progress)%)\n• PRs Created: \($monthly_prs_created)/\($pr_creation_goal) (\($pr_creation_progress)%)\n• PRs Merged: \($monthly_prs_merged)/\($pr_merge_goal) (\($pr_merge_progress)%)\n*Remaining Days in Month: \($remaining_days)*"
          }
        }
      ]
    )
  }'
)

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
