1. ARCHITECTURAL DIAGRAM
   <img width="1651" height="1211" alt="cwa-cost-tracker-Architecture" src="https://github.com/user-attachments/assets/a9fb8b15-84c2-4b35-9c77-84f63af8a770" />

DEEP DIVE INTO THE ARCHITECTURE:

The architecture is built around AWS's serverless ecosystem to ensure scalability, low maintenance, and cost-efficiency. Here's a high-level breakdown of the key components and their interconnections:

CloudWatch Metrics and Alarms: Acts as the monitoring backbone. It pulls data from AWS Cost Explorer or Billing metrics (e.g., via the EstimatedCharges metric in the AWS/Billing namespace). 
Alarms are configured to trigger when costs exceed a defined threshold (e.g., daily or monthly limits). When an alarm state changes to "ALARM," it publishes a message to an SNS topic.

SNS (Simple Notification Service) Topic: Serves as the notification hub. It receives alarm notifications from CloudWatch and dispatches them to subscribed endpoints, such as email or SMS. This decouples the alerting from the core logic, allowing easy extension to other subscribers like Lambda or external services.

Lambda Function: The core processing unit. It's invoked either on a schedule (via EventBridge, if configured) to periodically fetch and log cost data, or triggered by SNS for alert handling. The Lambda processes billing data, calculates aggregates if needed, and writes logs or summaries to DynamoDB. It uses AWS SDK (Boto3) to interact with Cost Explorer API for detailed cost breakdowns.

DynamoDB Table: A NoSQL database for storing cost logs, historical data, and alert records. It's designed with a partition key (e.g., Date or AccountID) and sort key (e.g., Timestamp) for efficient queries. Lambda writes items here, such as cost entries with fields like amount, service, and timestamp. This allows for querying past costs without relying on AWS's native billing console.

STEPS I TOOK TO BUUILD THIS:

I kicked things off by getting my local setup ready. I installed Terraform and the AWS CLI on my machine, then configured my AWS credentials with access keys for a non-root user to keep things secure. I created a new directory for the project and initialized Terraform there with terraform init, which pulled in the AWS provider.
From there, I began writing the main.tf file. I started simple: defining the AWS provider with my preferred region. Then I added the DynamoDB table resource, opting for pay-per-request billing to avoid over-provisioning since this was a low-traffic app.
Next came the Lambda part, which felt a bit more hands-on. Used the provided Python script in a separate file to handle cost fetching with Boto3—nothing fancy, just querying Cost Explorer and dumping data to DynamoDB. Created an IAM role with policies for Lambda execution, Cost Explorer access, DynamoDB writes, and CloudWatch logs. Terraform handled deploying the function, attaching the role, and setting environment variables.
After that, I layered in CloudWatch: a metric alarm on EstimatedCharges with an initial $10 threshold. I created an SNS topic, subscribed my email, and linked the alarm's actions to publish to SNS. To make it more robust, I added an optional EventBridge rule for scheduling the Lambda every day.
The deployment process was iterative. I'd run terraform plan to check what changes were coming, then terraform apply to spin everything up. Testing was key—I manually triggered the Lambda in the AWS console to see if it wrote to DynamoDB, and lowered the alarm threshold to $0.01 to simulate a breach since my account wasn't racking up real costs. I grabbed screenshots of successful runs, DB entries, alarm triggers, and email alerts to document it all.

CHALLENGES I FACED AND SOLUTIONS I TOOK:

I hit a few bumps along the way, mostly Terraform-related errors that taught me a lot.
First, when deploying the Lambda, I got a "Policy too large" error because my IAM role had too many inline policies stacked up from trial-and-error additions. I fixed it by consolidating permissions into a single managed policy and attaching it, which streamlined the Terraform code too.
Another issue was a "Resource already exists" conflict when re-applying after manual console changes—I'd tweaked the DynamoDB table settings directly in AWS to test indexes, causing state drift. Terraform errored out with "already exists." I resolved it by running terraform import to bring the resource back into state, then adjusted the config to match.
Billing data delays were frustrating; alarms wouldn't trigger because metrics update every 6 hours or so. I encountered "Insufficient data" states in CloudWatch. To work around it, I used the AWS CLI to put fake metric data (aws cloudwatch put-metric-data), which let me test end-to-end without waiting.
IAM permissions bit me hard—Lambda invocations failed with "AccessDeniedException" when trying to call Cost Explorer. CloudWatch Logs showed the errors clearly. I debugged by adding ce:GetCostAndUsage and similar actions to the policy, then re-applied Terraform.
DynamoDB provisioned throughput errors popped up initially since I started with provisioned mode; writes failed under load (even simulated). Switching to on-demand in Terraform solved it, but I had to destroy and recreate the table, losing test data—lesson learned on planning capacity modes upfront.

KEY LESSONS:

From the policy size error, I learned that Terraform encourages modular policies—keep them concise and use attachments over inlines to avoid hitting AWS limits, making configs more maintainable.

The state drift issue hammered home the importance of treating infrastructure as code exclusively; avoid console tweaks mid-project, or use terraform refresh and import immediately to sync up. It's all about consistency to prevent those "already exists" headaches.

Dealing with billing delays taught me that AWS services aren't always real-time—design tests around simulations like put-metric-data, and derive patience as a virtue in cloud ops. For cost monitoring specifically, it reinforced building in buffers for data lags to avoid false negatives.

IAM errors highlighted least-privilege principle: start broad, then tighten, but always check logs first. It derives from understanding service dependencies deeply before coding.

The DynamoDB mode switch showed me to research scaling options early—on-demand is great for unpredictable workloads like this, saving time on capacity guessing.

AWS CREATED RESOURCES SCREENSHOTS:


<img width="1366" height="768" alt="Lambda Dashboard" src="https://github.com/user-attachments/assets/5a499e13-1166-4aa4-80e3-34ce0cdb8c7c" />


<img width="1366" height="768" alt="DynamoDB table" src="https://github.com/user-attachments/assets/b875b3ad-bff8-486b-ba22-a089f5cc935d" />


<img width="1366" height="768" alt="CWA billing alarm" src="https://github.com/user-attachments/assets/13edf89f-84f9-42d7-a47b-a1f2cce6ff2c" />


<img width="1366" height="768" alt="Cloudfront Distributions" src="https://github.com/user-attachments/assets/47e9e1ef-4e0a-40ec-b083-dab8593ca219" />!


<img width="1366" height="768" alt="SNS subscription confirmation" src="https://github.com/user-attachments/assets/39da479e-d6a8-437e-a904-cd383c0c42a0" />


<img width="1366" height="768" alt="SNS Dashboard" src="https://github.com/user-attachments/assets/c4452d3e-0be4-4f2d-ac38-a896a2d52662" />


<img width="1366" height="768" alt="S3 Bucket" src="https://github.com/user-attachments/assets/f3786a78-2d5c-444a-b5ef-50ab1a87218c" />



<img width="1366" height="768" alt="API Gateway" src="https://github.com/user-attachments/assets/d3234e0b-1f21-4fa0-88b1-8c94711c483a" />

SCREENSHOT OF TERRAFORM APPLY OUTPUT: 

<img width="1366" height="768" alt="terraform apply output" src="https://github.com/user-attachments/assets/d71c22b8-be51-4bb1-bd4b-76adeb4de3fe" />

DASHBOARD SCREENSHOT:

<img width="1366" height="768" alt="cost tracker website dashboard" src="https://github.com/user-attachments/assets/3ab5ecaa-5fcb-4641-93d1-98416f1d716b" />

MY LINKEDIN POST LINK:

https://www.linkedin.com/posts/chris-ian-kimathi-101best_aws-terraform-serverless-activity-7379981568510939136-wWv9?utm_source=social_share_send&utm_medium=member_desktop_web&rcm=ACoAAEtk2GwBiPPRckR0EPrjbx00SbFLGiZfda0


