#!/bin/bash

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" 1>&2
}

log "Starting GitHub Activity Report script"

#--- 必要な環境変数の確認 --------------------------------------------

# 例: USERNAME, SLACK_WEBHOOK_URL など
for var in "GITHUB_TOKEN" "SLACK_WEBHOOK_URL" "USERNAME"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set"
        exit 1
    fi
    log "Confirmed $var is set"
done

# 月間目標の例（不要なら外してください）
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

#--- 日付の設定 -----------------------------------------------------

FROM_DATE=$(date -d '24 hours ago' -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MONTH_START=$(date -d "$(date +%Y-%m-01)" -u +"%Y-%m-%dT%H:%M:%SZ")

log "Time ranges:"
log "- From: $FROM_DATE"
log "- Current: $CURRENT_DATE"
log "- Month Start: $MONTH_START"

#--- GraphQLクエリ: コミット貢献 & PR一覧を一括取得 --------------------

log "Fetching commit & PR statistics..."

# 以下のクエリでは:
#  - contributionsCollection を使い、各リポジトリごとのコミットを取得
#  - pullRequests を使い、ユーザーが作成したPRを取得
#  - repositoryオブジェクトから owner.login を取得して、個人リポジトリか判定できるようにする

ALL_STATS=$(gh api graphql -f query='
  query($owner: String!, $dailyFrom: DateTime!, $monthFrom: DateTime!) {
    # コミットの集計（Daily & Monthly）
    daily: user(login: $owner) {
      contributionsCollection(from: $dailyFrom) {
        commitContributionsByRepository {
          repository {
            name
            owner {
              login
            }
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
      contributionsCollection(from: $monthFrom) {
        commitContributionsByRepository {
          repository {
            name
            owner {
              login
            }
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
    # PRの集計（ユーザーが作成したPR全体）
    user(login: $owner) {
      pullRequests(
        first: 100
        states: [OPEN, CLOSED, MERGED]
        orderBy: { field: CREATED_AT, direction: DESC }
      ) {
        nodes {
          createdAt
          mergedAt
          state
          baseRepository {
            owner {
              login
            }
            name
          }
        }
      }
    }
  }
' -f owner="$USERNAME" \
   -f dailyFrom="$FROM_DATE" \
   -f monthFrom="$MONTH_START")

log "Raw GitHub API Response:"
echo "$ALL_STATS" | jq '.'

#--- 変更行数の計算関数 ----------------------------------------------

calculate_changes() {
    local json="$1"
    local period="$2"    # "daily" or "monthly"
    local since="$3"     # FROM_DATE or MONTH_START
    local filter="$4"    # "ALL" or "PERSONAL"

    # filterが"PERSONAL"なら .repository.owner.login == ユーザー名 を抽出
    # filterが"ALL"なら全レポジトリを対象
    local jq_filter=''
    if [ "$filter" = "PERSONAL" ]; then
      jq_filter="select(.repository.owner.login == \"$USERNAME\")"
    else
      jq_filter="."  # 全レポジトリ対象
    fi

    # jqで合計を算出
    local result
    result=$(echo "$json" | jq --raw-output \
      --arg period "$period" \
      --arg since "$since" \
      --arg uname "$USERNAME" '
        [.data[$period].contributionsCollection.commitContributionsByRepository[]?
         | '"$jq_filter"'
         | select(.repository.defaultBranchRef != null)
         | .repository.defaultBranchRef.target.history.nodes[]?
         | select(.committedDate >= $since)
         | (.additions + .deletions)
        ] | add // 0
      ')

    echo "$result"
}

#--- コミット差分の集計 ----------------------------------------------

# 全リポジトリ合計
ALL_DAILY_CHANGES=$(calculate_changes "$ALL_STATS" "daily" "$FROM_DATE" "ALL")
ALL_MONTHLY_CHANGES=$(calculate_changes "$ALL_STATS" "monthly" "$MONTH_START" "ALL")

# 個人リポジトリ限定
PERSONAL_DAILY_CHANGES=$(calculate_changes "$ALL_STATS" "daily" "$FROM_DATE" "PERSONAL")
PERSONAL_MONTHLY_CHANGES=$(calculate_changes "$ALL_STATS" "monthly" "$MONTH_START" "PERSONAL")

log "Code Changes (Daily / Monthly):"
log "- All repos:      $ALL_DAILY_CHANGES / $ALL_MONTHLY_CHANGES"
log "- Personal repos: $PERSONAL_DAILY_CHANGES / $PERSONAL_MONTHLY_CHANGES"

#--- PR統計の集計 --------------------------------------------------

# ユーザーが作成した全PRを対象とし、そこから個人リポジトリかどうかを判定
PR_STATS=$(echo "$ALL_STATS" | jq '.data.user.pullRequests.nodes')

# PR数を計算する関数
calculate_prs() {
    local json="$1"
    local since="$2"
    local filter="$3"   # "ALL" or "PERSONAL"
    local mode="$4"     # "CREATED" or "MERGED"

    # .baseRepository.owner.login == $USERNAME -> 個人リポジトリ
    local jq_filter=''
    if [ "$filter" = "PERSONAL" ]; then
      jq_filter="select(.baseRepository.owner.login == \"$USERNAME\")"
    else
      jq_filter="."
    fi

    local jq_mode=''
    if [ "$mode" = "CREATED" ]; then
      jq_mode="select(.createdAt >= \"$since\")"
    else
      # MERGED
      jq_mode="select(.mergedAt != null and .mergedAt >= \"$since\")"
    fi

    local count
    count=$(echo "$json" | jq --argjson prNodes "$json" \
              --arg since "$since" '
              $prNodes
              | map(
                  '"$jq_filter"' 
                  | '"$jq_mode"'
                ) 
              | length
            ')

    echo "$count"
}

# 全リポジトリ対象のPR数
ALL_DAILY_PRS_CREATED=$(calculate_prs "$PR_STATS" "$FROM_DATE" "ALL" "CREATED")
ALL_DAILY_PRS_MERGED=$(calculate_prs "$PR_STATS" "$FROM_DATE" "ALL" "MERGED")
ALL_MONTHLY_PRS_CREATED=$(calculate_prs "$PR_STATS" "$MONTH_START" "ALL" "CREATED")
ALL_MONTHLY_PRS_MERGED=$(calculate_prs "$PR_STATS" "$MONTH_START" "ALL" "MERGED")

# 個人リポジトリのみ
PERSONAL_DAILY_PRS_CREATED=$(calculate_prs "$PR_STATS" "$FROM_DATE" "PERSONAL" "CREATED")
PERSONAL_DAILY_PRS_MERGED=$(calculate_prs "$PR_STATS" "$FROM_DATE" "PERSONAL" "MERGED")
PERSONAL_MONTHLY_PRS_CREATED=$(calculate_prs "$PR_STATS" "$MONTH_START" "PERSONAL" "CREATED")
PERSONAL_MONTHLY_PRS_MERGED=$(calculate_prs "$PR_STATS" "$MONTH_START" "PERSONAL" "MERGED")

log "PR Statistics (Daily / Monthly):"
log "- All repos:      Created: $ALL_DAILY_PRS_CREATED / $ALL_MONTHLY_PRS_CREATED, Merged: $ALL_DAILY_PRS_MERGED / $ALL_MONTHLY_PRS_MERGED"
log "- Personal repos: Created: $PERSONAL_DAILY_PRS_CREATED / $PERSONAL_MONTHLY_PRS_CREATED, Merged: $PERSONAL_DAILY_PRS_MERGED / $PERSONAL_MONTHLY_PRS_MERGED"

#--- 月間目標に対する進捗度合い（不要なら削除可） ---------------------

if ! command -v bc &> /dev/null; then
    log "Error: bc command not found"
    exit 1
fi

calculate_progress() {
    local current=$1
    local goal=$2
    if [ "$goal" -eq 0 ]; then
        echo 0
        return
    fi
    printf "%.2f" "$(echo "scale=2; $current * 100 / $goal" | bc)"
}

ALL_CHANGES_PROGRESS=$(calculate_progress "$ALL_MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
ALL_PR_CREATION_PROGRESS=$(calculate_progress "$ALL_MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
ALL_PR_MERGE_PROGRESS=$(calculate_progress "$ALL_MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

# 個人リポジトリ向けの目標ももしあるなら別途計算可能
PERSONAL_CHANGES_PROGRESS=$(calculate_progress "$PERSONAL_MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
PERSONAL_PR_CREATION_PROGRESS=$(calculate_progress "$PERSONAL_MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
PERSONAL_PR_MERGE_PROGRESS=$(calculate_progress "$PERSONAL_MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

DAYS_IN_MONTH=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

#--- Slack通知 ------------------------------------------------------

log "Creating Slack payload..."

PAYLOAD=$(jq -n \
  --arg all_daily_changes "$ALL_DAILY_CHANGES" \
  --arg personal_daily_changes "$PERSONAL_DAILY_CHANGES" \
  --arg all_daily_prs_created "$ALL_DAILY_PRS_CREATED" \
  --arg personal_daily_prs_created "$PERSONAL_DAILY_PRS_CREATED" \
  --arg all_daily_prs_merged "$ALL_DAILY_PRS_MERGED" \
  --arg personal_daily_prs_merged "$PERSONAL_DAILY_PRS_MERGED" \
  --arg all_monthly_changes "$ALL_MONTHLY_CHANGES" \
  --arg personal_monthly_changes "$PERSONAL_MONTHLY_CHANGES" \
  --arg all_monthly_prs_created "$ALL_MONTHLY_PRS_CREATED" \
  --arg personal_monthly_prs_created "$PERSONAL_MONTHLY_PRS_CREATED" \
  --arg all_monthly_prs_merged "$ALL_MONTHLY_PRS_MERGED" \
  --arg personal_monthly_prs_merged "$PERSONAL_MONTHLY_PRS_MERGED" \
  --arg all_changes_progress "$ALL_CHANGES_PROGRESS" \
  --arg personal_changes_progress "$PERSONAL_CHANGES_PROGRESS" \
  --arg all_pr_creation_progress "$ALL_PR_CREATION_PROGRESS" \
  --arg personal_pr_creation_progress "$PERSONAL_PR_CREATION_PROGRESS" \
  --arg all_pr_merge_progress "$ALL_PR_MERGE_PROGRESS" \
  --arg personal_pr_merge_progress "$PERSONAL_PR_MERGE_PROGRESS" \
  --arg remaining_days "$REMAINING_DAYS" \
  '{
    "blocks": [
      {
        "type": "header",
        "text": { "type": "plain_text", "text": "📊 GitHub Activity Report" }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Today'\''s Activity (All vs Personal)*\n• Code Changes: \($all_daily_changes) / \($personal_daily_changes) lines\n• PRs Created: \($all_daily_prs_created) / \($personal_daily_prs_created)\n• PRs Merged: \($all_daily_prs_merged) / \($personal_daily_prs_merged)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Monthly Activity (All vs Personal)*\n• Code Changes: \($all_monthly_changes) / \($personal_monthly_changes)\n• PRs Created: \($all_monthly_prs_created) / \($personal_monthly_prs_created)\n• PRs Merged: \($all_monthly_prs_merged) / \($personal_monthly_prs_merged)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Monthly Progress (All vs Personal)*\n• Code Changes: \($all_changes_progress)% / \($personal_changes_progress)%\n• PR Creation: \($all_pr_creation_progress)% / \($personal_pr_creation_progress)%\n• PR Merges: \($all_pr_merge_progress)% / \($personal_pr_merge_progress)%"
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
