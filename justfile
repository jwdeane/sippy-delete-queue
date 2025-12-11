set dotenv-load := true
set quiet := true

demo_name := "sippy-delete-queue"
env_file := ".env"

# Cloudflare variables
#--------------------------------------------------

cloudflare_account_id := "1264dd6e6cc190c7c7527289dd3aa799"
r2_bucket := "cflr-sippy-delete-queue-destination"

# AWS variables
#--------------------------------------------------

profile := "cflr-admin"
iam_user := "cflr-sippy-delete-queue"
s3_bucket := "cflr-sippy-delete-queue-source"

_default:
    just --list

setup: create-r2-bucket create-s3-bucket create-iam-user create-r2-token enable-sippy

teardown: delete-r2-bucket delete-r2-token delete-s3-bucket destroy-iam-user

create-r2-bucket:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Creating R2 bucket {{ r2_bucket }}"
    cfapi -s accounts/{{ cloudflare_account_id }}/r2/buckets -XPOST --json "{\"name\": \"{{ r2_bucket }}\", \"locationHint\": \"oc\"}"
    echo -e "\n✔︎ created R2 bucket {{ r2_bucket }}"

    echo -e "\nEnabling r2.dev domain for bucket {{ r2_bucket }}"
    domain=$(cfapi -s accounts/{{ cloudflare_account_id }}/r2/buckets/{{ r2_bucket }}/domains/managed -XPUT --json '{"enabled": true}' | jq -r '.result.domain')
    echo "✔︎ enabled access at https://$domain"

create-r2-token:
    #!/usr/bin/env bash
    set -euo pipefail

    if command -v gdate >/dev/null 2>&1; then
      # Use gdate if available (GNU coreutils on macOS)
      EXPIRES=$(gdate -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)
    else
      # Try BSD date (macOS default)
      EXPIRES=$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)
    fi

    token_payload=$(mktemp)
    jq -n \
        --arg demo_name "{{ demo_name }}" \
        --arg cloudflare_account_id "{{ cloudflare_account_id }}" \
        --arg r2_bucket "{{ r2_bucket }}" \
        '{
          "name": ($demo_name),
          "policies": [
              {
                  "effect": "allow",
                  "resources": {
                      ("com.cloudflare.edge.r2.bucket." + $cloudflare_account_id + "_default_" + $r2_bucket): "*"
                  },
                  "permission_groups": [
                      {"id": "2efd5506f9c8494dacb1fa10a3e7d5b6", "name": "Workers R2 Storage Bucket Item Write"}
                  ]
              }
          ],
          "expires_on": "'$EXPIRES'"
        }' >"${token_payload}"

    response=$(cfapi -s accounts/{{ cloudflare_account_id }}/tokens \
      --json "$(cat "${token_payload}")" -XPOST)

    if jq -e 'if .result.value then .result.value = (.result.value[:8] + "..." + .result.value[-4:]) else . end' >/dev/null <<<"$response"; then
        echo "✔︎ created R2 API token for {{ demo_name }}"
    else
        echo -e "✖︎ failed to create R2 API token for {{ demo_name }}\n"
        jq '.' <<<"$response"
        exit 1
    fi

    echo -e "\nUpdating .env file with R2 credentials"
    # Access Key ID: The id of the API token.
    # Secret Access Key: The SHA-256 hash of the API token value.
    token=$(echo "$response" | jq -r '.result.value // empty')
    access_key_id=$(echo "$response" | jq -r '.result.id // empty')
    secret_access_key=$(printf "%s" "$token" | shasum -a 256 | awk '{print $1}')

    tmp_env=$(mktemp)
    if [ -f "{{ env_file }}" ]; then
        grep -Ev '^R2_ACCESS_KEY_ID=|^R2_SECRET_ACCESS_KEY=' "{{ env_file }}" >"${tmp_env}" || true
    fi

    {
        [ -s "${tmp_env}" ] && cat "${tmp_env}"
        echo "R2_ACCESS_KEY_ID=${access_key_id}"
        echo "R2_SECRET_ACCESS_KEY=${secret_access_key}"
    } >"{{ env_file }}"

    echo "✔︎ added R2 credentials to .env"
    rm -f "${token_payload}" "${tmp_env}"

delete-r2-token:
    #!/usr/bin/env bash
    set -euo pipefail

    echo -e "\nFinding {{ demo_name }} R2 tokens to delete…"
    tokens=$(cfapi -s accounts/{{ cloudflare_account_id }}/tokens | jq -r '.result[] | select(.name == "sippy-delete-queue") | .id')
    if [ -z "$tokens" ]; then
        echo "No R2 API tokens named sippy-delete-queue found"
    else
        for token in $tokens; do
            cfapi -s accounts/{{ cloudflare_account_id }}/tokens/${token} -XDELETE
            echo -e "\n✔︎ deleted ${token}"
        done
    fi

disable-sippy:
    cfapi -s accounts/{{ cloudflare_account_id }}/r2/buckets/{{ r2_bucket }}/sippy -XDELETE

enable-sippy:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ env_file }}

    echo "Using AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:8}..."
    echo -e "\nEnabling Sippy between S3 s3://{{ s3_bucket }} and R2 {{ r2_bucket }}"
    payload=$(mktemp)
    jq -n \
        --arg r2_bucket "{{ r2_bucket }}" \
        --arg s3_bucket "{{ s3_bucket }}" \
        --arg r2_access_key_id "$R2_ACCESS_KEY_ID" \
        --arg r2_secret_access_key "$R2_SECRET_ACCESS_KEY" \
        --arg aws_access_key_id "$AWS_ACCESS_KEY_ID" \
        --arg aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" \
        '{
          "destination": {
            "provider": "r2",
            "accessKeyId": $r2_access_key_id,
            "secretAccessKey": $r2_secret_access_key,
          },
          "source": {
            "provider": "aws",
            "region": "ap-southeast-2",
            "bucket": ($s3_bucket),
            "accessKeyId": $aws_access_key_id,
            "secretAccessKey": $aws_secret_access_key
          }
        }' >"${payload}"

    # AWS takes time to propagate IAM user permissions 🤮
    for i in {1..5}; do
      response=$(cfapi -s accounts/{{ cloudflare_account_id }}/r2/buckets/{{ r2_bucket }}/sippy -XPUT --json  "$(cat "${payload}")")
      if jq -e '.success == true' >/dev/null <<<"$response"; then
          echo "✔︎ enabled Sippy for R2 bucket {{ r2_bucket }}"
          exit 0
      fi
      echo "✖︎ attempt ${i}/5, retrying in 5s…"
      sleep 5
    done
    rm -f "${payload}"
    echo "Exceeded maximum retry attempts. Exiting."
    exit 1

[no-exit-message]
delete-r2-bucket:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Emptying R2 bucket {{ r2_bucket }}"
    if output=$(AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY aws s3 rm s3://{{ r2_bucket }} --region auto --recursive --endpoint-url https://{{ cloudflare_account_id }}.r2.cloudflarestorage.com 2>&1); then
        echo -e "✔︎ emptied {{ r2_bucket }} R2 bucket\n"
    elif grep -q "NoSuchBucket" <<<"$output"; then
        echo -e "✖︎ {{ r2_bucket }} R2 bucket not found"
        exit 1
    else
        echo "$output"
        echo -e "✖︎ failed to empty {{ r2_bucket }} R2 bucket"
        exit 1
    fi

    echo "Deleting R2 bucket {{ r2_bucket }}"
    response=$(cfapi -s accounts/{{ cloudflare_account_id }}/r2/buckets/{{ r2_bucket }} -XDELETE)
    if jq -e '.success == true' >/dev/null <<<"$response"; then
        echo "✔︎ deleted {{ r2_bucket }} R2 bucket"
    else
        echo -e "✖︎ {{ r2_bucket }} R2 bucket not found"
        exit 1
    fi

[no-exit-message]
create-s3-bucket:
    #!/usr/bin/env bash
    set -euo pipefail

    echo -e "\nCreating S3 bucket {{ s3_bucket }}"
    if aws s3api head-bucket --bucket "{{ s3_bucket }}" --profile {{ profile }} >/dev/null 2>&1; then
        echo "{{ s3_bucket }} S3 bucket already exists"
    else
        aws s3 mb "s3://{{ s3_bucket }}" --profile {{ profile }} >/dev/null
        echo "✔︎ created s3://{{ s3_bucket }}"
    fi

[no-exit-message]
delete-s3-bucket:
    #!/usr/bin/env bash
    set -euo pipefail

    echo -e "\nDeleting s3://{{ s3_bucket }}"
    if aws s3api head-bucket --bucket "{{ s3_bucket }}" --profile {{ profile }} >/dev/null 2>&1; then
      aws s3 rm s3://{{ s3_bucket }} --recursive --profile {{ profile }} >/dev/null
      echo "✔︎ emptied s3://{{ s3_bucket }}"
      aws s3api delete-bucket --bucket "{{ s3_bucket }}" --profile {{ profile }} >/dev/null
      echo "✔︎ deleted s3://{{ s3_bucket }}"
    else
        echo "✖︎ {{ s3_bucket }} S3 bucket not found"
    fi

# create IAM user and access key scoped to the bucket/prefix
create-iam-user:
    #!/usr/bin/env bash
    set -euo pipefail

    echo -e "\nEnsuring IAM user {{ iam_user }} exists"
    if ! aws iam get-user --user-name "{{ iam_user }}" --profile {{ profile }} >/dev/null 2>&1; then
        aws iam create-user --user-name "{{ iam_user }}" --profile {{ profile }} >/dev/null
        echo "✔︎ created IAM user {{ iam_user }}"
    else
        echo "IAM user {{ iam_user }} already exists"
    fi

    policy=$(mktemp)
    jq -n \
        --arg bucket "{{ s3_bucket }}" \
        '{
          "Version": "2012-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Action": ["s3:ListBucket*", "s3:GetObject*"],
              "Resource": [("arn:aws:s3:::" + $bucket), ("arn:aws:s3:::" + $bucket + "/*")]
            }
          ]
        }' >"${policy}"

    echo -e "\nAttaching inline policy for s3://{{ s3_bucket }} exclusively"
    aws iam put-user-policy \
        --user-name "{{ iam_user }}" \
        --policy-name "{{ iam_user }}-s3-access" \
        --policy-document "file://${policy}" \
        --profile {{ profile }}

    echo -e "\nDeleting existing access keys for {{ iam_user }}"
    for key in $(aws iam list-access-keys --user-name "{{ iam_user }}" --query 'AccessKeyMetadata[].AccessKeyId' --output text --profile {{ profile }}); do
        aws iam delete-access-key --user-name "{{ iam_user }}" --access-key-id "${key}" --profile {{ profile }}
        echo "Deleted access key ${key}"
    done
    echo -e "\nCreating new access key for {{ iam_user }}"
    read -r access_key_id secret_access_key <<<"$(aws iam create-access-key --user-name "{{ iam_user }}" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text --profile {{ profile }})"

    tmp_env=$(mktemp)
    if [ -f "{{ env_file }}" ]; then
        grep -Ev '^AWS_ACCESS_KEY_ID=|^AWS_SECRET_ACCESS_KEY=' "{{ env_file }}" >"${tmp_env}" || true
    fi

    {
        [ -s "${tmp_env}" ] && cat "${tmp_env}"
        echo "AWS_ACCESS_KEY_ID=${access_key_id}"
        echo "AWS_SECRET_ACCESS_KEY=${secret_access_key}"
    } >"{{ env_file }}"

    echo "✔︎ wrote credentials to {{ env_file }} (do not commit this file)"

    rm -f "${policy}" "${tmp_env}"

# delete IAM user, its access keys, and local env file
destroy-iam-user:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Deleting access keys for {{ iam_user }}"
    for key in $(aws iam list-access-keys --user-name "{{ iam_user }}" --query 'AccessKeyMetadata[].AccessKeyId' --output text --profile {{ profile }}); do
        aws iam delete-access-key --user-name "{{ iam_user }}" --access-key-id "${key}" --profile {{ profile }}
        echo "✔︎ deleted access key ${key}"
    done

    echo "Deleting inline policy for {{ iam_user }}"
    aws iam delete-user-policy --user-name "{{ iam_user }}" --policy-name "{{ iam_user }}-s3-access" --profile {{ profile }} || true
    echo "✔︎ deleted {{ iam_user }} user policy"

    echo "Deleting IAM user {{ iam_user }}"
    aws iam delete-user --user-name "{{ iam_user }}" --profile {{ profile }} || true
    echo "✔︎ deleted {{ iam_user }}"

    echo "Removing {{ env_file }}"
    rm -f "{{ env_file }}"

    echo "✔︎ cleanup complete"

# list all onjects in the R2 bucket
[no-exit-message]
list-r2:
    echo "Listing contents of R2 bucket {{ r2_bucket }}"
    cfapi -s accounts/{{ cloudflare_account_id }}/r2/buckets/{{ r2_bucket }}/objects -XGET --json '{"limit":1000}' | jq '.result'

# list all objects in the S3 bucket
[no-exit-message]
list-s3:
    echo "Listing contents of s3://{{ s3_bucket }}"
    aws s3 ls s3://{{ s3_bucket }} --recursive --profile {{ profile }}
