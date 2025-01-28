#!/bin/bash
set -e
cd "$(dirname "$0")/.."

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" 1>&2
}

log "Starting GitHub Activity Report script"

# 環境変数の確認
for var in "GITHUB_TOKEN" "SLACK_WEBHOOK_URL" "USERNAME"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set"
        exit 1
    fi
    log "Confirmed $var is set"
done

# リポジトリ情報の設定
REPO_OWNER="${REPO_OWNER:-$USERNAME}"

# リポジトリ所有者の確認
if [ -z "$REPO_OWNER" ]; then
    log "Error: REPO_OWNER is not set"
    exit 1
fi
log "Confirmed REPO_OWNER is set"

# 所有リポジトリの一覧を取得
log "Fetching repository list for $REPO_OWNER..."
REPOS=$(gh repo list "$REPO_OWNER" --json name --jq '.[].name' --limit 100)
if [ -z "$REPOS" ]; then
    log "Warning: No repositories found for $REPO_OWNER"
fi
log "Found repositories for $REPO_OWNER"

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
if [ -z "${GITHUB_ACTIONS}" ]; then
    # テスト用の日付設定（2024年のデータを取得）
    FROM_DATE="2024-01-26T00:00:00Z"
    CURRENT_DATE="2024-01-27T23:59:59Z"
    MONTH_START="2024-01-01T00:00:00Z"
else
    FROM_DATE=$(date -d '24 hours ago' -u +"%Y-%m-%dT%H:%M:%SZ")
    CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    MONTH_START=$(date -d "$(date +%Y-%m-01)" -u +"%Y-%m-%dT%H:%M:%SZ")
fi

log "Time ranges:"
log "- From: $FROM_DATE"
log "- Current: $CURRENT_DATE"
log "- Month Start: $MONTH_START"

# コミット統計の取得
log "Fetching commit statistics..."

# 個人の活動量を取得
log "Fetching personal commit statistics..."
# Convert dates to ISO 8601 format for GitHub API
# Use original ISO8601 format for DateTime fields
daily_from_iso="$FROM_DATE"
month_start_iso="$MONTH_START"

log "Using time ranges:"
log "- Daily From: $daily_from_iso"
log "- Month Start: $month_start_iso"
log "- Current: $CURRENT_DATE"

PERSONAL_STATS=$(gh api graphql -f query='
  query($owner: String!, $dailyFrom: DateTime!, $monthStart: DateTime!) {
    daily: user(login: $owner) {
      contributionsCollection(from: $dailyFrom) {
        commitContributionsByRepository(maxRepositories: 100) {
          repository {
            nameWithOwner
            owner {
              login
            }
            defaultBranchRef {
              target {
                ... on Commit {
                  history(first: 100, since: $dailyFrom) {
                    nodes {
                      additions
                      deletions
                      committedDate
                      author {
                        email
                        user {
                          login
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
    }
    monthly: user(login: $owner) {
      contributionsCollection(from: $monthStart) {
        commitContributionsByRepository(maxRepositories: 100) {
          repository {
            nameWithOwner
            owner {
              login
            }
            defaultBranchRef {
              target {
                ... on Commit {
                  history(first: 100, since: $monthStart) {
                    nodes {
                      additions
                      deletions
                      committedDate
                      author {
                        email
                        user {
                          login
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
    }
  }
' -f owner="$USERNAME" -f dailyFrom="$daily_from_iso" -f monthStart="$month_start_iso" -f dailyFromGit="$daily_from_iso" -f monthStartGit="$month_start_iso")

# リポジトリ全体の活動量を取得（所有リポジトリのみ）
log "Fetching repository-wide commit statistics (owned repositories)..."
REPO_STATS=$(gh api graphql -f query='
   query($owner: String!, $dailyFrom: DateTime!, $monthStart: DateTime!) {
     daily: user(login: $owner) {
       repositories(first: 100, ownerAffiliations: OWNER) {
         nodes {
           nameWithOwner
           defaultBranchRef {
             target {
               ... on Commit {
                 history(first: 100, since: $dailyFrom) {
                   nodes {
                     additions
                     deletions
                     committedDate
                     author {
                       email
                       user {
                         login
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
     monthly: user(login: $owner) {
       repositories(first: 100, ownerAffiliations: OWNER) {
         nodes {
           nameWithOwner
           defaultBranchRef {
             target {
               ... on Commit {
                 history(first: 100, since: $monthStart) {
                   nodes {
                     additions
                     deletions
                     committedDate
                     author {
                       email
                       user {
                         login
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
   }
' -f owner="$USERNAME" -f dailyFrom="$daily_from_iso" -f monthStart="$month_start_iso")

# Debug: Print raw response
log "Raw repository statistics response:"
echo "$REPO_STATS" | jq '.' || echo "Failed to parse JSON"

# Check for GraphQL errors
if [[ "$REPO_STATS" == *"Something went wrong"* ]]; then
    log "Error: GraphQL query failed for repository statistics"
elif [ -z "$REPO_STATS" ] || [ "$REPO_STATS" = "{}" ]; then
    log "Warning: No repository data retrieved"
else
    log "Successfully fetched repository statistics"
fi

log "Raw GitHub API Response:"
echo "$PERSONAL_STATS" | jq '.'
log "Raw Repository Stats:"
echo -e "$REPO_STATS" | jq '.'

# 変更行数の計算関数
calculate_personal_changes() {
    local json=$1
    local period=$2
    local since=$3
    local username=$4

    log "Calculating personal changes:"
    log "- Period: $period"
    log "- Since: $since"
    log "- Username: $username"

    # jqの出力をraw-outputで整形し、空白をトリム
    local result=$(echo "$json" | jq --raw-output --arg since "$since" --arg period "$period" --arg username "$username" '
        [.data[$period].contributionsCollection.commitContributionsByRepository[] |
        select(.repository.defaultBranchRef != null) |
        .repository.defaultBranchRef.target.history.nodes[] |
        select(.committedDate >= $since and (.author.user.login == $username or (.author.user == null and .author.email | contains($username)))) |
        (.additions + .deletions)] |
        add // 0
    ' 2>/dev/null | tr -d '[:space:]' || echo "0")

    log "Calculated personal changes for $period since $since: $result"
    echo "${result:-0}"
}

calculate_repo_changes() {
    local json=$1
    local period=$2
    local since=$3

    log "Calculating repository changes:"
    log "- Period: $period"
    log "- Since: $since"

    # Process all repositories in a single jq query
    local result=$(echo "$json" | jq --raw-output --arg since "$since" --arg period "$period" '
        [.data[$period].repositories.nodes[] |
        select(.defaultBranchRef != null) |
        .defaultBranchRef.target.history.nodes[] |
        select(.committedDate >= $since and .author != null) |
        (.additions + .deletions)] |
        add // 0
    ' 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Validate result
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        log "Repository changes calculated: $result"
    else
        log "Warning: Invalid changes value from repositories: $result"
        result=0
    fi

    log "Calculated repository changes for $period since $since: $result"
    echo "$result"
}

# 重複を除いた合計を計算する関数
calculate_total_changes() {
    local personal_changes=$1
    local repo_changes=$2
    local overlap_changes=$3
    local period=$4

    log "Calculating total changes for $period period:"
    log "Input values:"
    log "- Personal changes: $personal_changes"
    log "- Repository changes: $repo_changes"
    log "- Overlap (double-counted) changes: $overlap_changes"

    # 入力値の検証
    if ! [[ "$personal_changes" =~ ^[0-9]+$ ]] || \
       ! [[ "$repo_changes" =~ ^[0-9]+$ ]] || \
       ! [[ "$overlap_changes" =~ ^[0-9]+$ ]]; then
        log "Error: Invalid input values detected for $period"
        log "- Personal changes (valid number?): $([[ "$personal_changes" =~ ^[0-9]+$ ]] && echo "Yes" || echo "No")"
        log "- Repository changes (valid number?): $([[ "$repo_changes" =~ ^[0-9]+$ ]] && echo "Yes" || echo "No")"
        log "- Overlap changes (valid number?): $([[ "$overlap_changes" =~ ^[0-9]+$ ]] && echo "Yes" || echo "No")"
        return 0
    fi

    # 重複を除いた合計を計算
    local total=$((personal_changes + repo_changes - overlap_changes))
    log "Calculation for $period:"
    log "- Formula: $personal_changes + $repo_changes - $overlap_changes"
    log "- Result: $total"

    if [ "$total" -lt 0 ]; then
        log "Warning: Negative total detected ($total) for $period. This might indicate an issue with overlap calculation."
        total=0
    fi

    echo "$total"
}

# 個人の変更行数の計算
log "Calculating personal changes..."
DAILY_PERSONAL_CHANGES=$(calculate_personal_changes "$PERSONAL_STATS" "daily" "$FROM_DATE" "$USERNAME")
MONTHLY_PERSONAL_CHANGES=$(calculate_personal_changes "$PERSONAL_STATS" "monthly" "$MONTH_START" "$USERNAME")

log "Personal changes:"
log "- Daily: $DAILY_PERSONAL_CHANGES"
log "- Monthly: $MONTHLY_PERSONAL_CHANGES"

# リポジトリ全体の変更行数の計算
log "Calculating repository changes..."
DAILY_REPO_CHANGES=$(calculate_repo_changes "$REPO_STATS" "daily" "$FROM_DATE")
MONTHLY_REPO_CHANGES=$(calculate_repo_changes "$REPO_STATS" "monthly" "$MONTH_START")

log "Repository changes:"
log "- Daily: $DAILY_REPO_CHANGES"
log "- Monthly: $MONTHLY_REPO_CHANGES"

# オーバーラップの計算（個人の変更のうち、自分のリポジトリでの変更分）
calculate_overlap_changes() {
    local json=$1
    local period=$2
    local since=$3
    local username=$4

    log "Calculating overlap changes:"
    log "- Period: $period"
    log "- Since: $since"
    log "- Username: $username"

    # Calculate changes only for commits by the user in their owned repositories
    local result=$(echo "$json" | jq --raw-output --arg since "$since" --arg period "$period" --arg username "$username" '
        [.data[$period].contributionsCollection.commitContributionsByRepository[] |
        select(.repository.owner.login == $username) |
        select(.repository.defaultBranchRef != null) |
        .repository.defaultBranchRef.target.history.nodes[] |
        select(.committedDate >= $since and (.author.user.login == $username or (.author.user == null and .author.email | contains($username)))) |
        (.additions + .deletions)] |
        add // 0
    ' 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Validate result
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        log "Overlap changes calculated: $result"
    else
        log "Warning: Invalid overlap changes value: $result"
        result=0
    fi

    log "Calculated overlap changes for $period since $since: $result"
    echo "$result"
}

log "Calculating overlap changes..."
DAILY_OVERLAP_CHANGES=$(calculate_overlap_changes "$PERSONAL_STATS" "daily" "$FROM_DATE" "$USERNAME")
MONTHLY_OVERLAP_CHANGES=$(calculate_overlap_changes "$PERSONAL_STATS" "monthly" "$MONTH_START" "$USERNAME")

log "Overlap changes:"
log "- Daily: $DAILY_OVERLAP_CHANGES"
log "- Monthly: $MONTHLY_OVERLAP_CHANGES"

# 重複を除いた合計の計算
log "Calculating total changes (without double counting)..."
log "Daily metrics breakdown:"
log "- Personal Changes: $DAILY_PERSONAL_CHANGES"
log "- Repository Changes: $DAILY_REPO_CHANGES"
log "- Overlap (double-counted) Changes: $DAILY_OVERLAP_CHANGES"
DAILY_CHANGES=$(calculate_total_changes "$DAILY_PERSONAL_CHANGES" "$DAILY_REPO_CHANGES" "$DAILY_OVERLAP_CHANGES" "daily")

log "Monthly metrics breakdown:"
log "- Personal Changes: $MONTHLY_PERSONAL_CHANGES"
log "- Repository Changes: $MONTHLY_REPO_CHANGES"
log "- Overlap (double-counted) Changes: $MONTHLY_OVERLAP_CHANGES"
MONTHLY_CHANGES=$(calculate_total_changes "$MONTHLY_PERSONAL_CHANGES" "$MONTHLY_REPO_CHANGES" "$MONTHLY_OVERLAP_CHANGES" "monthly")

log "Final changes (without double counting):"
log "- Daily Total: $DAILY_CHANGES (Personal: $DAILY_PERSONAL_CHANGES + Repo: $DAILY_REPO_CHANGES - Overlap: $DAILY_OVERLAP_CHANGES)"
log "- Monthly Total: $MONTHLY_CHANGES (Personal: $MONTHLY_PERSONAL_CHANGES + Repo: $MONTHLY_REPO_CHANGES - Overlap: $MONTHLY_OVERLAP_CHANGES)"

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

# PR統計の初期化
log "Initializing PR statistics..."
DAILY_PRS_CREATED=0
DAILY_PRS_MERGED=0
MONTHLY_PRS_CREATED=0
MONTHLY_PRS_MERGED=0

# 全リポジトリに対してPR情報を取得
log "Starting PR data collection for all repositories..."
log "Time ranges for PR statistics:"
log "- Daily from: $FROM_DATE"
log "- Monthly from: $MONTH_START"

while IFS= read -r repo; do
    log "Processing repository: $repo"
    log "- Fetching PR data since $FROM_DATE for daily stats"
    log "- Fetching PR data since $MONTH_START for monthly stats"
    log "Executing GraphQL query for repository: $repo"
    log "Query parameters:"
    log "- Repository Owner: $REPO_OWNER"
    log "- Repository Name: $repo"
    log "- States: [OPEN, CLOSED, MERGED]"
    log "- Limit: 100 PRs"
    
    PR_QUERY=$(gh api graphql -f query='
      query($repoOwner: String!, $repoName: String!) {
        repository(owner: $repoOwner, name: $repoName) {
          pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) {
            nodes {
              createdAt
              mergedAt
              state
              author {
                login
              }
            }
          }
        }
      }
    ' -f repoOwner="$REPO_OWNER" -f repoName="$repo")

    # Validate GraphQL response
    if [ -z "$PR_QUERY" ]; then
        log "Warning: Empty GraphQL response for repository $repo"
        continue
    fi

    # Check for GraphQL errors
    if echo "$PR_QUERY" | jq -e '.errors' >/dev/null; then
        log "Warning: GraphQL query returned errors for repository $repo:"
        echo "$PR_QUERY" | jq '.errors' || log "Failed to parse GraphQL errors"
        continue
    fi

    log "Successfully retrieved PR data for $repo"
    log "Raw GraphQL response structure:"
    echo "$PR_QUERY" | jq -r 'paths | select(length > 0) | join(".")' || log "Failed to analyze GraphQL response structure"
    
    # リポジトリごとのPR統計を計算
    log "Calculating PR statistics for repository: $repo"
    log "- Using time ranges:"
    log "  • Daily: from $FROM_DATE"
    log "  • Monthly: from $MONTH_START"
    log "- Filtering for user: $USERNAME"

    # Daily PR statistics
    REPO_DAILY_PRS_CREATED=$(echo "$PR_QUERY" | jq --arg from "$FROM_DATE" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.createdAt >= $from and .author.login == $username)] | length')
    REPO_DAILY_PRS_MERGED=$(echo "$PR_QUERY" | jq --arg from "$FROM_DATE" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.mergedAt != null and .mergedAt >= $from and .author.login == $username)] | length')
    
    # Monthly PR statistics
    REPO_MONTHLY_PRS_CREATED=$(echo "$PR_QUERY" | jq --arg from "$MONTH_START" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.createdAt >= $from and .author.login == $username)] | length')
    REPO_MONTHLY_PRS_MERGED=$(echo "$PR_QUERY" | jq --arg from "$MONTH_START" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.mergedAt != null and .mergedAt >= $from and .author.login == $username)] | length')

    # Validate PR counts
    if ! [[ "$REPO_DAILY_PRS_CREATED" =~ ^[0-9]+$ ]] || ! [[ "$REPO_DAILY_PRS_MERGED" =~ ^[0-9]+$ ]] || \
       ! [[ "$REPO_MONTHLY_PRS_CREATED" =~ ^[0-9]+$ ]] || ! [[ "$REPO_MONTHLY_PRS_MERGED" =~ ^[0-9]+$ ]]; then
        log "Warning: Invalid PR count detected for repository $repo"
        log "Raw counts:"
        log "- Daily Created: $REPO_DAILY_PRS_CREATED"
        log "- Daily Merged: $REPO_DAILY_PRS_MERGED"
        log "- Monthly Created: $REPO_MONTHLY_PRS_CREATED"
        log "- Monthly Merged: $REPO_MONTHLY_PRS_MERGED"
        continue
    fi

    # 合計に加算
    DAILY_PRS_CREATED=$((DAILY_PRS_CREATED + REPO_DAILY_PRS_CREATED))
    DAILY_PRS_MERGED=$((DAILY_PRS_MERGED + REPO_DAILY_PRS_MERGED))
    MONTHLY_PRS_CREATED=$((MONTHLY_PRS_CREATED + REPO_MONTHLY_PRS_CREATED))
    MONTHLY_PRS_MERGED=$((MONTHLY_PRS_MERGED + REPO_MONTHLY_PRS_MERGED))

    log "Repository $repo PR statistics:"
    log "- Daily metrics:"
    log "  • Created: $REPO_DAILY_PRS_CREATED"
    log "  • Merged: $REPO_DAILY_PRS_MERGED"
    log "- Monthly metrics:"
    log "  • Created: $REPO_MONTHLY_PRS_CREATED"
    log "  • Merged: $REPO_MONTHLY_PRS_MERGED"
    log "- Running totals:"
    log "  • Daily Created (total): $DAILY_PRS_CREATED"
    log "  • Daily Merged (total): $DAILY_PRS_MERGED"
    log "  • Monthly Created (total): $MONTHLY_PRS_CREATED"
    log "  • Monthly Merged (total): $MONTHLY_PRS_MERGED"
done <<< "$REPOS"

log "Total PR Statistics:"
log "- Total Daily PRs Created: $DAILY_PRS_CREATED"
log "- Total Daily PRs Merged: $DAILY_PRS_MERGED"
log "- Total Monthly PRs Created: $MONTHLY_PRS_CREATED"
log "- Total Monthly PRs Merged: $MONTHLY_PRS_MERGED"

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
    local metric_name=$3

    log "Calculating progress for $metric_name:"
    log "- Current value: $current"
    log "- Goal value: $goal"

    if [ "$goal" -eq 0 ]; then
        log "Error: Goal value cannot be zero for $metric_name"
        exit 1
    fi

    if ! [[ "$current" =~ ^[0-9]+$ ]]; then
        log "Error: Invalid current value for $metric_name: $current"
        exit 1
    fi

    local progress=$(printf "%.2f" "$(echo "scale=2; $current * 100 / $goal" | bc)")
    log "Progress calculation for $metric_name:"
    log "- Formula: ($current / $goal) * 100"
    log "- Result: $progress%"
    echo "$progress"
}

# 月間目標に対する進捗率の計算
log "Calculating monthly progress metrics..."
CHANGES_PROGRESS=$(calculate_progress "$MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL" "Total Code Changes")
PR_CREATION_PROGRESS=$(calculate_progress "$MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL" "PR Creation")
PR_MERGE_PROGRESS=$(calculate_progress "$MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL" "PR Merges")

# 残り日数の計算
DAYS_IN_MONTH=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

log "Time calculations:"
log "- Days in month: $DAYS_IN_MONTH"
log "- Current day: $CURRENT_DAY"
log "- Remaining days: $REMAINING_DAYS"

# Slack通知用のJSONペイロードを作成
log "Creating Slack payload..."
PAYLOAD=$(jq -n \
  --arg daily_personal_changes "$DAILY_PERSONAL_CHANGES" \
  --arg daily_repo_changes "$DAILY_REPO_CHANGES" \
  --arg daily_changes "$DAILY_CHANGES" \
  --arg daily_prs_created "$DAILY_PRS_CREATED" \
  --arg daily_prs_merged "$DAILY_PRS_MERGED" \
  --arg monthly_personal_changes "$MONTHLY_PERSONAL_CHANGES" \
  --arg monthly_repo_changes "$MONTHLY_REPO_CHANGES" \
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
          "text": "*Activity Metrics Explanation*\n• Personal Changes: Commits by you in any repository (owned or external)\n• Repository Changes: All commits in repositories you own\n• Overlap Changes: Your commits in your repositories (counted in both above)\n• Total Changes: Personal + Repository - Overlap (no double-counting)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Today'\''s Activity*\n• Personal Changes: \($daily_personal_changes) lines\n• Repository Changes: \($daily_repo_changes) lines\n• Overlap (Double-Counted): \($daily_overlap_changes) lines\n• Total Changes (No Double Count): \($daily_changes) lines\n• PRs Created: \($daily_prs_created)\n• PRs Merged: \($daily_prs_merged)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Monthly Progress*\n• Personal Changes: \($monthly_personal_changes) lines\n• Repository Changes: \($monthly_repo_changes) lines\n• Overlap (Double-Counted): \($monthly_overlap_changes) lines\n• Total Changes (No Double Count): \($monthly_changes)/\($monthly_goal) lines (\($changes_progress)%)\n• PRs Created: \($monthly_prs_created)/\($pr_creation_goal) (\($pr_creation_progress)%)\n• PRs Merged: \($monthly_prs_merged)/\($pr_merge_goal) (\($pr_merge_progress)%)"
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
