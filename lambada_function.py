import json
import boto3
import os
import uuid

textract = boto3.client('textract')
s3 = boto3.client('s3')
cloudsearch_client = boto3.client('cloudsearchdomain', endpoint_url=os.getenv('document_service_endpoint'))
search_client = boto3.client('cloudsearchdomain', endpoint_url=os.getenv('search_service_endpoint'))


def lambda_handler(event, context):

    if 'rawPath' in event:
        path = event['rawPath']
        query_params = event['queryStringParameters'] if 'queryStringParameters' in event else {}
        if path == '/search' and 'keyword' in query_params and query_params['keyword']:

            hitsout = []
            response = search_client.search(
                query=query_params["keyword"]
            )
            hits = response['hits']['hit']
            for hit in hits:
                file_name = hit['fields']['file_name'][0]
                hitsout.append({'file_name': file_name, 'Keyword': query_params["keyword"]})

            return {
                'statusCode': 200,
                'body': json.dumps(hitsout)
            }

    if 'Records' in event:
        for record in event['Records']:
            if 's3' in record and 'pdfs' in record['s3']['object']['key']:
                response = textract.start_document_text_detection(
                    DocumentLocation={
                        'S3Object': {
                            'Bucket': os.getenv('bucket_name'),
                            'Name': record['s3']['object']['key']
                        }
                    },
                    OutputConfig={
                        'S3Bucket': os.getenv('bucket_name'),
                        'S3Prefix': 'outputs'
                    },
                    NotificationChannel={
                        'SNSTopicArn': os.getenv('sns_arn'),
                        'RoleArn': os.getenv('sns_role_arn'),
                    },
                )
                
                print(response)

            if 'Sns' in record:
                message = json.loads(record['Sns']['Message'])
                JobId = message['JobId']
                doc_name = message['DocumentLocation']['S3ObjectName'].split('/')[1]

                files = s3.list_objects_v2(Bucket=os.getenv('bucket_name'), Prefix='outputs/' + JobId)
                file_names = [obj['Key'] for obj in files.get('Contents', [])]

                text_results = []
                for file_name in file_names:
                    if 's3_access_check' not in file_name:
                        file = s3.get_object(Bucket=os.getenv('bucket_name'), Key=file_name)
                        file_content = file['Body'].read()
                        extracted_data = json.loads(file_content)
                        
                        
                        for item in extracted_data['Blocks']:
                            if item['BlockType'] == 'LINE':
                                text_results.append(item['Text'])

                docs = [{
                    'type': 'add',
                    'id': str(uuid.uuid4()),
                    'fields': {
                        'file_name': doc_name,
                        'content':  '\n'.join(text_results)
                    }
                }]

                rsp = cloudsearch_client.upload_documents(
                    documents=json.dumps(docs),
                    contentType='application/json'
                )
                print(rsp)
    
            
            
    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
    }
