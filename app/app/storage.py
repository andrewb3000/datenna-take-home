import json
import os
import time

import boto3
from botocore.exceptions import ClientError

_BUCKET = os.environ.get("BUCKET_NAME", "items")

# Covers both head_bucket's ("404") and get_object's ("NoSuchKey"/"NoSuchBucket")
# not-found error codes, across S3 and MinIO's S3-compatible responses.
_NOT_FOUND_CODES = {"404", "NoSuchKey", "NoSuchBucket"}


def _client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["MINIO_ENDPOINT"],
        aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
        aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
        region_name="us-east-1",
    )


def wait_for_bucket(retries: int = 10, delay_seconds: float = 2.0) -> None:
    # The app's MinIO identity is a scoped IAM user (read/write on this bucket only,
    # no CreateBucket) — the bucket itself is provisioned once, out of band, by
    # scripts/03-deploy.sh using the MinIO root credential. This just waits for it to
    # exist rather than creating it.
    last_error: Exception | None = None
    for _ in range(retries):
        try:
            _client().head_bucket(Bucket=_BUCKET)
            return
        except Exception as exc:
            last_error = exc
            time.sleep(delay_seconds)
    raise RuntimeError(f"could not confirm bucket '{_BUCKET}' exists after {retries} attempts") from last_error


def put_object(item_id: int, payload: dict) -> None:
    _client().put_object(
        Bucket=_BUCKET,
        Key=f"items/{item_id}.json",
        Body=json.dumps(payload).encode("utf-8"),
        ContentType="application/json",
    )


def get_object(item_id: int) -> dict | None:
    try:
        resp = _client().get_object(Bucket=_BUCKET, Key=f"items/{item_id}.json")
    except ClientError as exc:
        if exc.response["Error"]["Code"] in _NOT_FOUND_CODES:
            return None
        raise
    return json.loads(resp["Body"].read())


def ping() -> bool:
    try:
        _client().head_bucket(Bucket=_BUCKET)
        return True
    except Exception:
        return False
