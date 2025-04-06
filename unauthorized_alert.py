import json
import boto3
import os

sns_client = boto3.client('sns')
TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

def lambda_handler(event, context):
    print("Event Received:", json.dumps(event))
    detail = event.get("detail", {})
    
    user = detail.get("userIdentity", {}).get("arn", "Unknown")
    operation = detail.get("eventName", "Unknown")
    bucket = detail.get("requestParameters", {}).get("bucketName", "Unknown")
    region = detail.get("awsRegion", "Unknown")

    message = f"""
    🚨 Unauthorized S3 Access Attempt Detected 🚨

    User: {user}
    Operation: {operation}
    Bucket: {bucket}
    Region: {region}
    Error: AccessDenied
    """

    sns_client.publish(
        TopicArn=TOPIC_ARN,
        Subject="ALERT: Unauthorized S3 Access",
        Message=message
    )

    return {"statusCode": 200, "body": "Alert sent"}
