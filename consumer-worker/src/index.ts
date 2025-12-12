import { S3Client, DeleteObjectCommand } from '@aws-sdk/client-s3';

export interface Env {
	BUCKET: R2Bucket;
	S3_BUCKET_NAME: string;
	AWS_REGION: string;
	AWS_ACCESS_KEY_ID: string;
	AWS_SECRET_ACCESS_KEY: string;
}

interface R2EventMessage {
	account: string;
	bucket: string;
	eventTime: string;
	action: string;
	object: {
		key: string;
		size: number;
		eTag: string;
	};
}

export default {
	async queue(batch: MessageBatch<R2EventMessage>, env: Env): Promise<void> {
		const client = new S3Client({
			region: env.AWS_REGION,
			credentials: {
				accessKeyId: env.AWS_ACCESS_KEY_ID,
				secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
			},
		});

		for (const message of batch.messages) {
			const objectKey = message.body.object.key;
			try {
				const params = {
					Bucket: env.S3_BUCKET_NAME,
					Key: objectKey,
				};
				const {
					$metadata: { requestId, httpStatusCode },
				} = await client.send(new DeleteObjectCommand(params));
				console.log({
					msg: `${env.S3_BUCKET_NAME}/${objectKey} deleted successfully`,
					bucket: env.S3_BUCKET_NAME,
					objectKey,
					requestId,
					httpStatusCode,
				});
				message.ack();
			} catch (e) {
				console.log('Error deleting object', e);
				message.retry({ delaySeconds: 5 });
			}
		}
	},
};
