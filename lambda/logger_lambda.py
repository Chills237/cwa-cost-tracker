
import boto3
import json
import os
from datetime import datetime

dynamodb = boto3.resource("dynamodb")
table_name = os.environ.get("DDB_TABLE", "CostTrackerLogs")
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    timestamp = datetime.utcnow().isoformat()

    # Simplify message extraction
    message = event.get("Records", [{}])[0].get("Sns", {}).get("Message", "Test alert")

    table.put_item(Item={
        "id": timestamp,
        "message": message
    })

    return {"statusCode": 200, "body": "Log stored"}