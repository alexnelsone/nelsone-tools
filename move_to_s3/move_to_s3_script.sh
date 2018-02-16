#!/bin/bash

# Things that must exist for this script to work properly:  LogGroup and a LogStream. a role that can write to the group/stream

logStream="LOG_STREAM_NAME"
logGroup="LOG_GROUP_NAME"
dirToMonitor="PATH_TO_DIRECTORY"
s3TargetURL="BUCKET+KEY"
DATE=$(date +%Y%m%d)

#Lets get the region
region=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/)
region=$(echo ${region:0:-1})

printf "\nScript execution began: `date`\n"

printf "Checking $dirToMonitor to log to the $logStream log stream located in the $logGroup log group.\n"



#check if the nextSeqToken Variable has a value. If not get it.
if [ -z "$nextSeqToken" ]
then
      nextSeqToken=$(aws logs describe-log-streams --log-group $logGroup --log-stream-name-prefix $logStream --region $region | jq '.logStreams[].uploadSequenceToken' | tr -d '"'``)
else
        echo "nextSeqToken has a value."
fi

nextSeqToken=$(aws logs put-log-events --log-group-name $logGroup --log-stream-name $logStream --log-events timestamp=$(date +%s%3N),message="$(printf "running script from $(pwd)\n")" --region $region --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)


# Jump to the directory we want to monitor
cd $dirToMonitor

#If there are files in the directory log the files found. if not log that no files were found.
if [ $(ls -1 | wc -l) -gt 0 ]
then
    fileCount=$(ls -1 | wc -l)
        printf "$fileCount files in $dirToMonitor. Logging filenames.\n"
        #logMessage=$(printf "Found $fileCount files in $(pwd):\n$(ls -p | grep -v /)\n")
        nextSeqToken=$(aws logs put-log-events --log-group-name $logGroup --log-stream-name $logStream --log-events timestamp=$(date +%s%3N),message="$(printf "Found $fileCount files in $(pwd):\n$(ls -p | grep -v /)\n")" --region $region --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
        nextSeqToken=$(aws logs put-log-events --log-group-name $logGroup --log-stream-name $logStream --log-events timestamp=$(date +%s%3N),message="$(printf "Moving $fileCount files to s3.")" --region $region --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
        printf "Starting to move files to $s3TargetURL\n"
        #this will eventually be a mv
        if $(aws s3 mv $dirToMonitor $s3TargetURL --sse AES256 --region $region --recursive --exclude "archive/*" > /dev/null)
        then
                #if the previous command was successful TODO
                awsFileCount=$(aws s3 ls $s3TargetURL | wc -l)
                printf "Finished move. Counted $awsFileCount in $s3TargetURL.\n"
                nextSeqToken=$(aws logs put-log-events --log-group-name $logGroup --log-stream-name $logStream --log-events timestamp=$(date +%s%3N),message="$(printf "File move complete.  Counted $awsFileCount in $s3TargetURL")" --region $region --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
        else
                printf "There was an error.  The file copy to aws may have failed."
                nextSeqToken=$(aws logs put-log-events --log-group-name $logGroup --log-stream-name $logStream --log-events timestamp=$(date +%s%3N),message="$(printf "File copy to $s3TargetURL may have failed.")" --region $region --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
        fi
else
        printf "No files in the directory to monitor. Logging that no files were found.\n"
        nextSeqToken=$(aws logs put-log-events --log-group-name $logGroup --log-stream-name $logStream --log-events timestamp=$(date +%s%3N),message="$(printf "No files found in $(pwd).")" --region $region --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
fi

# if we were in another directory go back.
cd - > /dev/null
printf "Finished execution.\n"

printf "Script execution ended: `date`\n"

aws s3 cp /var/log/LOG_FILE_NAME.log-`date +%Y%m%d` BUCKET/KEY/LOG_FILE_NAME.log-`date +%Y%m%d` --sse AES256 --region us-east-2
