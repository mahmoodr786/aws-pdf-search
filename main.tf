provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "textract_bucket" {
  bucket = "textractblogsearch"
  tags = {
    Name        = "Textract Bucket"
    Environment = "Blog"
  }
}

resource "aws_cloudsearch_domain" "search" {
  name = "blogsearch"

  scaling_parameters {
    desired_instance_type = "search.small"
  }


  index_field {
    analysis_scheme = "_en_default_"
    facet           = false
    highlight       = false
    name            = "content"
    return          = true
    search          = true
    sort            = false
    type            = "text"
  }
  index_field {
    analysis_scheme = "_en_default_"
    facet           = false
    highlight       = false
    name            = "file_name"
    return          = true
    search          = true
    sort            = true
    type            = "text"
  }

  multi_az = false

  endpoint_options {
    enforce_https = true
  }
}

data "archive_file" "lambda_function" {
  type        = "zip"
  source_file = "${path.module}/lambada_function.py"
  output_path = "${path.module}/lambada_function.zip"
}

resource "aws_lambda_function" "lambda_function" {
  function_name = "textract"
  handler       = "lambada_function.lambda_handler"
  runtime       = "python3.11"
  role          = aws_iam_role.lambda_role.arn
  filename      = data.archive_file.lambda_function.output_path
  timeout       = 60
  environment {
    variables = {
      bucket_name               = aws_s3_bucket.textract_bucket.id
      cloudsearch_domain        = aws_cloudsearch_domain.search.name
      sns_arn                   = aws_sns_topic.textract_job.arn
      sns_role_arn              = aws_iam_role.textract_sns_role.arn
      document_service_endpoint = "https://${aws_cloudsearch_domain.search.document_service_endpoint}"
      search_service_endpoint   = "https://${aws_cloudsearch_domain.search.search_service_endpoint}"
    }
  }

  source_code_hash = data.archive_file.lambda_function.output_base64sha256
}

resource "aws_iam_role" "lambda_role" {
  name = "textract_lambda_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "textract_lambda_policy"
  description = "Policy for Lambda textract role"

  policy = <<EOF
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "VisualEditor0",
			"Effect": "Allow",
			"Action": [
				"textract:*",
				"cloudsearch:*",
				"s3:*",
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
			],
			"Resource": "*"
		}
	]
}
EOF
}
# Attach the policy to the Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_policy.arn
  role       = aws_iam_role.lambda_role.name
}
resource "aws_iam_role" "textract_sns_role" {
  name = "textract_sns_role"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "",
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "textract.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
}
EOF
}
resource "aws_iam_policy" "sns_policy" {
  name        = "textract_sns_policy"
  description = "Policy for Lambda textract sns role"

  policy = <<EOF
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "VisualEditor0",
			"Effect": "Allow",
			"Action": [
				"sns:*"
			],
			"Resource": "*"
		}
	]
}
EOF
}


resource "aws_iam_role_policy_attachment" "lambda_sns_policy_attachment" {
  policy_arn = aws_iam_policy.sns_policy.arn
  role       = aws_iam_role.textract_sns_role.name
}

resource "aws_lambda_function_url" "url" {
  function_name      = aws_lambda_function.lambda_function.function_name
  authorization_type = "NONE"
}

resource "aws_s3_bucket_notification" "upload_notification" {
  bucket = aws_s3_bucket.textract_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.lambda_function.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "pdfs/"
    filter_suffix       = ".pdf"
    id                  = "upload"
  }
}


resource "aws_sns_topic" "textract_job" {
  name = "textract_job"
}

resource "aws_sns_topic_subscription" "textract_job_subscription" {
  topic_arn = aws_sns_topic.textract_job.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.lambda_function.arn
}