#!/bin/bash

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" 1>&2
}

log "Starting GitHub Activity Report script"

# OSの判定
if [[ "$(uname)" == "Darwin" ]]; then
    IS_MACOS=true
else
    IS_MACOS=false
fi

# date関数: OS依存の日付操作を抽象化
get_date() {
    if [[ "$IS_MACOS" == true ]]; then
        case "$1" in
            "24h_ago")
                date -v-24H -u +"%Y-%m-%dT%H:%M:%SZ"
                ;;
            "month_start")
                date -v1d -v0H -v0M -v0S -u +"%Y-%m-%dT%H:%M:%SZ"
                ;;
            "days_in_month")
                days=$(cal $(date +"%m %Y") | awk 'NF {DAYS = $NF}; END {print DAYS}')
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

# ユーザー名の取得
USERNAME="${USERNAME:-$(gh api user --jq '.login')}"
log "Using GitHub username: $USERNAME"

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
FROM_DATE=$(get_date "24h_ago")
CURRENT_DATE=$(get_date)
MONTH_START=$(get_date "month_start")

log "Time ranges:"
log "- From: $FROM_DATE"
log "- Current: $CURRENT_DATE"
log "- Month Start: $MONTH_START"

# コミット統計の取得
log "Fetching commit statistics..."
STATS=$(gh api graphql -f query='
  query($owner: String!, $dailyFrom: DateTime!, $monthStart: DateTime!) {
    daily: user(login: $owner) {
      contributionsCollection(from: $dailyFrom) {
        commitContributionsByRepository {
          repository {
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
    monthly: user(login: $owner) {
      contributionsCollection(from: $monthStart) {
        commitContributionsByRepository {
          repository {
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
  }
' -f owner="$USERNAME" -f dailyFrom="$FROM_DATE" -f monthStart="$MONTH_START")

log "Raw GitHub API Response:"
echo "$STATS" | jq '.'

# 変更行数の計算関数
calculate_changes() {
    local json=$1
    local period=$2
    local since=$3

    log "Debugging calculate_changes function:"
    log "- JSON input: $json"
    log "- Period: $period"
    log "- Since: $since"

    # jqの出力をraw-outputで整形し、空白をトリム
    local result=$(echo "$json" | jq --raw-output --arg since "$since" --arg period "$period" '
        [.data[$period].contributionsCollection.commitContributionsByRepository[] |
        select(.repository.defaultBranchRef != null) |
        .repository.defaultBranchRef.target.history.nodes[] |
        select(.committedDate >= $since) |
        (.additions + .deletions)] |
        add // 0
    ' | tr -d '[:space:]')

    log "Calculated changes for $period since $since: $result"

    # 値が空かどうかをチェック
    if [[ -z "$result" ]]; then
        log "Error: Result is empty"
        exit 1
    fi

    # 数値であるかどうかを確認
    if ! [[ "$result" =~ ^[0-9]+$ ]]; then
        log "Error: Result is not a valid number: $result"
        exit 1
    fi

    echo "$result"
}

# 実際の変更行数を計算
DAILY_CHANGES=$(calculate_changes "$STATS" "daily" "$FROM_DATE")
log "Final validated DAILY_CHANGES: $DAILY_CHANGES"

MONTHLY_CHANGES=$(calculate_changes "$STATS" "monthly" "$MONTH_START")
log "Final validated MONTHLY_CHANGES: $MONTHLY_CHANGES"

# 数値の検証
if ! [[ "$DAILY_CHANGES" =~ ^[0-9]+$ ]]; then
    log "Error: Invalid daily changes value: $DAILY_CHANGES"
    exit 1
fi

if ! [[ "$MONTHLY_CHANGES" =~ ^[0-9]+$ ]]; then
    log "Error: Invalid monthly changes value: $MONTHLY_CHANGES"
    exit 1
fi

log "Change counts validated"

log "Fetching PR statistics..."
# PR情報の取得（ユーザーレベル）
PR_STATS=$(gh api graphql -f owner="$USERNAME" -f query='
  query($owner: String!) {
    user(login: $owner) {
      pullRequests(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
        nodes {
          createdAt
          mergedAt
          state
        }
      }
    }
  }
')

log "Raw PR Query Response:"
echo "$PR_STATS" | jq '.'

# PRの統計を計算（期間でフィルタリング）
DAILY_PRS_CREATED=$(echo "$PR_STATS" | jq --arg from "$FROM_DATE" '[.data.user.pullRequests.nodes[] | select(.createdAt >= $from)] | length')
DAILY_PRS_MERGED=$(echo "$PR_STATS" | jq --arg from "$FROM_DATE" '[.data.user.pullRequests.nodes[] | select(.mergedAt != null and .mergedAt >= $from)] | length')
MONTHLY_PRS_CREATED=$(echo "$PR_STATS" | jq --arg from "$MONTH_START" '[.data.user.pullRequests.nodes[] | select(.createdAt >= $from)] | length')
MONTHLY_PRS_MERGED=$(echo "$PR_STATS" | jq --arg from "$MONTH_START" '[.data.user.pullRequests.nodes[] | select(.mergedAt != null and .mergedAt >= $from)] | length')

log "PR Statistics:"
log "- Daily PRs Created: $DAILY_PRS_CREATED"
log "- Daily PRs Merged: $DAILY_PRS_MERGED"
log "- Monthly PRs Created: $MONTHLY_PRS_CREATED"
log "- Monthly PRs Merged: $MONTHLY_PRS_MERGED"

# bcコマンドの確認
if ! command -v bc &> /dev/null; then
    log "Error: bc command not found"
    exit 1
fi
log "bc command available"

# 進捗率計算用の関数
calculate_progress() {
    local current=$1
    local goal=$2
    if [ "$goal" -eq 0 ]; then
        log "Error: monthly goal cannot be zero"
        exit 1
    fi
    local progress=$(printf "%.2f" "$(echo "scale=2; $current * 100 / $goal" | bc)")
    log "Progress calculation: $current / $goal = $progress%"
    echo "$progress"
}

# 月間目標に対する進捗率の計算
CHANGES_PROGRESS=$(calculate_progress "$MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
PR_CREATION_PROGRESS=$(calculate_progress "$MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
PR_MERGE_PROGRESS=$(calculate_progress "$MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

# 残り日数の計算
DAYS_IN_MONTH=$(get_date "days_in_month")
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

log "Time calculations:"
log "- Days in month: $DAYS_IN_MONTH"
log "- Current day: $CURRENT_DAY"
log "- Remaining days: $REMAINING_DAYS"

# Slack通知用のJSONペイロードを作成
log "Creating Slack payload..."
PAYLOAD=$(jq -n \
  --arg daily_changes "$DAILY_CHANGES" \
  --arg daily_prs_created "$DAILY_PRS_CREATED" \
  --arg daily_prs_merged "$DAILY_PRS_MERGED" \
  --arg monthly_changes "$MONTHLY_CHANGES" \
  --arg monthly_goal "$MONTHLY_CODE_CHANGES_GOAL" \
  --arg changes_progress "$CHANGES_PROGRESS" \
  --arg monthly_prs_created "$MONTHLY_PRS_CREATED" \
  --arg pr_creation_goal "$MONTHLY_PR_CREATION_GOAL" \
  --arg pr_creation_progress "$PR_CREATION_PROGRESS" \
  --arg monthly_prs_merged "$MONTHLY_PRS_MERGED" \
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
          "text": "*Today'\''s Activity*\n• Code Changes: \($daily_changes) lines\n• PRs Created: \($daily_prs_created)\n• PRs Merged: \($daily_prs_merged)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Monthly Progress*\n• Code Changes: \($monthly_changes)/\($monthly_goal) lines (\($changes_progress)%)\n• PRs Created: \($monthly_prs_created)/\($pr_creation_goal) (\($pr_creation_progress)%)\n• PRs Merged: \($monthly_prs_merged)/\($pr_merge_goal) (\($pr_merge_progress)%)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Remaining Days in Month: \($remaining_days)*"
        }
      }
    ]
  }')

log "Slack payload:"
echo "$PAYLOAD" | jq '.'

# Slackに通知を送信
if [ -n "$SLACK_WEBHOOK_URL" ]; then
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
else
    log "SLACK_WEBHOOK_URL is not set, skipping Slack notification"
fi

log "Successfully completed GitHub Activity Report"
