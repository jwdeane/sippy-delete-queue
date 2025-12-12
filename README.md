# Sippy Delete Queue

[Sippy](https://developers.cloudflare.com/r2/data-migration/sippy/) is a function of [Cloudflare R2](https://developers.cloudflare.com/r2/) that allows you to permanently store a _copy_ of objects on-demand when requested from S3.

Note the _emphasis_ above: Sippy _copies_ objects from S3 to R2 when requested, it doesn't _move_ them. If you want to delete the source S3 objects after-copy you need to implement that logic yourself.

This demo showcases that functionality. Using Sippy in conjunction with [Cloudflare Workers](https://developers.cloudflare.com/workers/) and [Cloudflare Queues](https://developers.cloudflare.com/queues/) you can automatically delete source S3 objects after they've been successfully pulled into R2 by hooking into the R2 [`object-create`](https://developers.cloudflare.com/r2/buckets/event-notifications/#event-types) event.

```
┌───────────┐                  ┌───────────┐                        ┌───────────┐
│           │                  │           │                        │           │
│  EYEBALL  │───/coffee.jpg───▶│    R2     │◀ ─ ─ ─ ─ Sippy ─ ─ ─ ─▶│    S3     │
│           │                  │           │                        │           │
└───────────┘                  └───────────┘                        └───────────┘
                                     │                                    ▲
                                     │                                    │
                               object-create                              │
                                     │                              deleteObject
                                     │                                    │
                                     ▼                                    │
                               ┌───────────┐                        ┌───────────┐
                               │           │                        │           │
                               │   Queue   │────consumer-worker────▶│  Worker   │
                               │           │                        │           │
                               └───────────┘                        └───────────┘
```

## Tools

To use this demo as-is you'll need the following tools installed:

- [Just](https://just.systems/) for task running
- [AWS CLI](https://aws.amazon.com/cli/) for S3 bucket management
  - You'll need to configure the AWS CLI with appropriate credentials for creating the initial S3 bucket, IAM user, and uploading assets
- [Wrangler](https://developers.cloudflare.com/workers/cli-wrangler/) for Worker management
- [jq](https://stedolan.github.io/jq/) for JSON manipulation
- `cfapi` - a [personal script](https://github.com/jwdeane/scripts/blob/main/cfapi) that wraps [cf-vault](https://github.com/jacobbednarz/cf-vault/) for managing Cloudflare resources via the [client API](https://developers.cloudflare.com/api/)
  - For simplicities sake this demo assumes a `global` cf-vault profile has been configured with a [Global API Key](https://developers.cloudflare.com/fundamentals/api/get-started/keys/).

## Demo

To run the demo, open two terminal splits:

1. **Terminal 1**: run `just setup` to automatically:
   - create the R2 and S3 buckets
   - upload all assets from the `/assets` directory to S3
   - configure the Sippy connection
   - wire up Queue notifications
   - deploy a consumer-worker to process delete requests from the Queue

2. **Terminal 2**: `cd` into the `consumer-worker` directory
   - run `npx wrangler tail` to watch for Queue / Worker logs

3. **Terminal 1**: run `just trigger-sippy` to `cURL` all assets from the R2 public access URL.
   - as R2 is empty at this point the assets will be pulled in from S3 by Sippy on each cURL request

4. **Terminal 2**: observe the Worker logs fly by as the queue triggers the consumer-worker and sends the delete requests to S3

```sh
# terminal 1
just setup
# terminal 2
cd consumer-worker
npx wrangler tail
# terminal 1
just trigger-sippy
```

To reset the demo run `just reset` in **terminal 1** to clear R2 and re-upload all assets to S3.

When finished you can teardown all resources with `just teardown`.

## Components

- S3 bucket as the source (`create-s3-bucket` recipe)
- AWS IAM user with permissions to read, list, and delete objects from the source S3 bucket **only** (`create-iam-user` recipe)

  ```jsonc
  // IAM policy for S3 with jq argument placeholders
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:ListBucket*", "s3:GetObject*", "s3:DeleteObject*"],
        "Resource": [("arn:aws:s3:::" + $bucket), ("arn:aws:s3:::" + $bucket + "/*")]
      }
    ]
  }
  ```

- R2 bucket for the destination (`create-r2-bucket` recipe)
- R2 bucket API token scoped to the R2 bucket (`create-r2-token` recipe)
- Sippy connection to an S3 bucket (`enable-sippy` recipe)
- R2 `object-create` notifications to push S3 delete requests to the queue (`create-r2-notification` recipe)
- Cloudflare Queue to enqueue delete requests (`create-r2-queue` recipe)
- A consumer-worker to process delete requests from the Queue and issue `DeleteObject` requests to S3 (`deploy-worker` recipe)
- Secrets (AWS and R2 Access Keys) loaded against the consumer-worker (`add-secrets` recipe)

## Notes

- S3 supports 3500 rps for PUT/COPY/POST/DELETE and 5500 rps for GET/HEAD requests per prefix.
- `import { S3Client, DeleteObjectCommand } from '@aws-sdk/client-s3';` is used in the Worker to issue `DeleteObject` requests to S3. This makes the Worker reasonably chunky at ~`504.65 KiB / gzip: 104.28 KiB`.
