#!/bin/bash 

# VERSION 1

SERVERNAME=`hostname -s`
file=$1
username=$2
TIMESTAMP=`date +%s%3N`
S3_TARGET=s3://BUCKETNAME/sftp-incoming/np
S3_LOG_FILE_LOCATION=s3://BUCKETNAME/logs/sftp/np/file-info
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/)
AWS_REGION=$(echo ${AWS_REGION:0:-1})
DYNAMODB_TABLE=file-cleanser-sftp-log
DATE=$(date +%Y%m%d)
LOG_GROUP=file-cleanser-sftp-server
LOG_STREAM=sftp-incoming-files


# this is for logging to cloudwatch.  We need to have cloudwatch token to upload logs.  The very first time you upload to a new logStream you don't have a token (it's 0). So the first
# upload doesn't need one. Documentation for this command can be found at https://docs.aws.amazon.com/cli/latest/reference/logs/describe-log-streams.html.

if [ -z $nextSeqToken ]
then
	printf "nextSeqToken is empty. Getting next token.\n"
	nextSeqToken=$(aws logs describe-log-streams --log-group $LOG_GROUP --log-stream-name-prefix $LOG_STREAM --region $AWS_REGION | jq '.logStreams[].uploadSequenceToken' | tr -d '"'``)

	printf "value of nextSeqToken is $nextSeqToken\n"

	#if [ -z $nextSeqToken ]
	if [ $nextSeqToken = "null" ]
	then
	# this is the first log write
	printf "First write to log. No Sequence token required.\n"

	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "running script from $(pwd)\n")" --region $AWS_REGION | jq '.nextSequenceToken' | tr -d '"'``)

	else
	printf "Running script from $(pwd)\n"
	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "running script from $(pwd)\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)

	fi

else
	printf "nextSeqToken has a value of $nextSeqToken\n"
fi



# If script cannot get next sequence token then it can just exit. No need to execute.  This happens if the script can't reach the cloudwatch service.  We had this happen a few times when the unbound dns
# that we run was off.
if [ -z $nextSeqToken ]
then
	printf 'Could not get next sequence token from cloudwatch logs.\n'
	printf 'Exiting script.\n'
	exit
fi

#############################################################

printf "Passed execution for $file to kpg_midas_non_csv_fie_handler for $file\n"
nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "Passed execution to kpg_midas_non_csv_file_handler for $file\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)


# This is the size of the file in bytes
sizeOfFile=`stat --printf="%s" $file` 

# md5sum of file
md5sum=`md5sum $file | awk '{ print $1 }'`
				
# check if this is a zip file
file_type=`file -b $file`
file_type=`echo $file_type | cut -d "," -f1`
file_type=`echo $file_type | tr -d "-" | tr " " "_"`

if [[ "$file_type" == *'7zip'* ]]
then
	file_type="7zip"
elif [[ "$file_type" == *"Zip"* ]]
then
	file_type="Zip"
elif [[ "$file_type" == *"PGP"* ]]
then
	file_type="PGP"
else
	file_type="unknown"
fi



printf "file is of type: $file_type\n"

timestamp=`date --utc +%FT%TZ`
delimType="na"
numLinesWithText=0
duplicatesFlag=false
quotedValues=false
evenQuotes="na"
numColumns=0
minColumns=0
maxColumns=0
colAlign="na"
crlf=false
crlf_converted="na"

if $(aws s3 mv $file $S3_TARGET/$username/$file --sse AES256 --region $AWS_REGION > /dev/null)
then					
	printf "Copy successful. Setting copy_status variable to copied.\n"
	copy_status="success"
	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "copied $file to $S3_TARGET/$username/$file \n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
	
else
	printf "Copy not successful. Setting copy_status variable to failed.\n"
	copy_status="failed"
fi


printf "Writing log entry to disk.\n"
printf "$timestamp,$username,$file,$delimType,$sizeOfFile,$md5sum,$numLinesWithText,$duplicatesFlag,$quotedValues,$evenQuotes,$numColumns,$minColumns,$maxColumns,$colAlign,$copy_status,$file_type,$crlf,$crlf_converted,$SERVERNAME\n"
echo "$timestamp,$username,$file,$delimType,$sizeOfFile,$md5sum,$numLinesWithText,$duplicatesFlag,$quotedValues,$evenQuotes,$numColumns,$minColumns,$maxColumns,$colAlign,$copy_status,$file_type,$crlf,$crlf_converted,$SERVERNAME" >> /var/log/sftp-file-logging-$SERVERNAME-$DATE
			 
# write to dynamodb for future tracking in TRACKS
# DynamoDB is source of record for successfully copied files. no need to insert failed copied or partial copied data as that is not needed by next phases of TRACKS.
aws dynamodb put-item --table-name $DYNAMODB_TABLE --region $AWS_REGION --item '{ "UserName": { "S": '\"$username\"' }, "FileName" : { "S": '\"$file\"'}, "DelimiterType": {"S": '\"$delimType\"'}, "FileSize" : { "S" : '\"$sizeOfFile\"'}, "md5Sum" : { "S" : '\"$md5sum\"' }, "TotalLines" : { "S" : '\"$numLinesWithText\"' }, "Duplicates" : { "S": '\"$duplicatesFlag\"' }, "QuotedValues" : { "S": '\"$quotedValues\"' }, "EvenQuotes" : { "S": '\"$evenQuotes\"' }, "NumColumns" : { "S" : '\"$numColumns\"' } , "MinColumns" : { "S" : '\"$minColumns\"'}, "MaxColumns" : { "S" : '\"$maxColumns\"'}, "ColAligned" : { "S" : '\"$colAlign\"'}, "CopyStatus" : { "S" : '\"$copy_status\"'},"TimeStamp" : { "S" : '\"$timestamp\"'},"FileType" : { "S" : '\"$file_type\"'}, "CRLF" : { "S" : '\"$crlf\"'}, "CRLFCONVERTED" : { "S" : '\"$crlf_converted\"'},"ServerName" : { "S" : '\"$SERVERNAME\"'}}'

printf "Finished execution of non csv file handler.\n"
nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "finished execution of non csv file handler \n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)

aws s3 cp /var/log/sftp-file-logging-$SERVERNAME-$DATE $S3_LOG_FILE_LOCATION/sftp-file-logging-$SERVERNAME-$DATE --sse AES256 --region $AWS_REGION > /dev/null

