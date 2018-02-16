#!/bin/bash 

LOG_GROUP=file-cleanser-sftp-server
LOG_STREAM=sftp-incoming-files

# NOTE: for variables that will hold URLs to use, don't add trailing '/'
SFTP_DIR=/sftp-incoming
S3_TARGET=s3://BUCKET/sftp-incoming/test
S3_LOG_FILE_LOCATION=s3://BUCKET/logs/sftp/test
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/)
AWS_REGION=$(echo ${AWS_REGION:0:-1})
DATE=$(date +%m%d%Y)
RANDOM_NUM=$(echo $((1 + RANDOM % 100000000)))
DYNAMODB_TABLE=file-cleanser-sftp-log



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

	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "running script from $(pwd)\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)

	fi


else
	printf "nextSeqToken has a value of $nextSeqToken\n"
fi

# If script cannot get next sequence token then it can just exit. No need to execute.
if [ -z $nextSeqToken ]
then
	printf 'Could not get next sequence token from cloudwatch logs.\n'
	printf 'Exiting script.\n'
	exit
fi


printf "Checking for files on sftp server in $AWS_REGION\n\n"


for username in $(ls $SFTP_DIR)
do
	printf "Checking $username directory for files...\n"

	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "Checking $username directory\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)

	dirToCheck=$SFTP_DIR/$username/incoming

	cd $dirToCheck
	# NOTE:: the ls is -1 (one) not a lowercase l
	fileCount=$(ls -1 | wc -l)
	printf "$fileCount files in $dirToCheck\n"
	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "Found $fileCount files.\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
	if [ $fileCount -gt 0 ]
	then
		for file in "$dirToCheck"/*
		do
			file=$(basename $file)
			printf "Found: $file\n"
			nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "Found file $file\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
			if ! [[ `lsof $file` ]]
			then
				
				##############################################################

				# gather some stats on the file and log them.
				
				# This is the size of the file in bytes
				sizeOfFile=`stat --printf="%s" $file` 

				# md5sum of file
				md5sum=`md5sum $file | awk '{ print $1 }'`

				# We use grep to count only lines with text
				numLinesWithText=`grep -vc '^$' $file`

				# Check for duplicates

				# first, we need to remove blank lines. multiple blank lines are counted as duplicates
				sed -i '/^$/d' $file
				
				# next, look for duplicate lines
				duplicates=`sort $file | sort | uniq -d | wc -l`
				if [ $duplicates -gt 0 ]
				then
					printf "Found $duplicates duplicates in $file\n"
					sort $file | sort | uniq -d >> /var/log/sftp-duplicates/$DATE-$username-$file-$RANDOM_NUM
					duplicatesFlag=true
				else
					duplicatesFlag=false
				fi

				# We will read in the first line of the file for the next tests
                                firstLine=`head -1 $file`

				# check if file values are quoted
				quotedCount=`grep -o '"' <<< $firstLine | wc -l`
				printf "Found $quotedCount quotes in first line of $file\n"

				if [[ $quotedCount -eq 0 ]]
				then
					printf "File does not contain quoted values.\n"
					quotedValues=false
					evenQuotes=na
				else
					printf "File contains quoted values.\n"
					quotedValues=true

					 # Do we have an even number of quotes?
                                	if [[ $(( $quotedCount % 2 )) -eq 0 ]]
                                	then
                                        	printf "Even number of quotes.\n"
                                        	evenQuotes=true
                                	else
                                        	printf "Odd number of quotes, file may not load properlly\n"
                                        	evenQuotes=false
                                        	# TODO: send notification  of possible load failure
                               		 fi
				fi 

				

				# now we count columns. First we need to figure out what our delimeter is
                                # we will test for common delimeters such as pipe, comma and tab

				#grab the first line of the file
				firstLine=`head -1 $file`

				echo $firstLine | grep -q ','
				if [ $? -eq 0 ]
				then
					printf "$file is comma separated csv.\n"	
					delimType="comma"
					maxColumns=`awk -F ',' '{ print NF }' $file | sort -nu |  tail -n 1`
					minColumns=`awk -F ',' '{ print NF }' $file | sort -nu |  head -n 1`

					if [ $maxColumns -ne $minColumns ]
					then
						printf "Column mismatch in file. Possible bad load.\n"
						colAlign="no"
					else
						numColumns=$maxColumns
						printf "$file has $numColumns columns.\n"
						colAlign="yes"
					fi
				fi

				echo $firstLine | grep -q '|'
				if [ $? -eq 0 ]
				then
					printf "$file is pipe separated csv.\n"
					delimType="pipe"
					maxColumns=`awk -F '|' '{ print NF }' $file | sort -nu |  tail -n 1`
                                        minColumns=`awk -F '|' '{ print NF }' $file | sort -nu |  head -n 1`

                                        if [ $maxColumns -ne $minColumns ]
                                        then
                                                printf "Column mismatch in file. Possible bad load.\n"
						colAlign="no"
                                        else
                                                numColumns=$maxColumns
                                                printf "$file has $numColumns columns.\n"
						colAlign="yes"
                                        fi

				fi

				# TAB DELIM? ADD?


				##############################################################

				printf "Start copying $file\n"
				nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "Starting copy of $file of $sizeOfFile bytes with $numLines and md5sum of $md5sum to $S3_TARGET/$username/\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
				
				timestamp=`date --utc +%FT%TZ` 	
				if $(aws s3 cp $file $S3_TARGET/$username/$file --sse AES256 --region $AWS_REGION > /dev/null)
				then					
					printf "Copy successful. Setting copy_status variable to copied.\n"
					copy_status="success"
				

				else
					printf "Copy not successful. Setting copy_status variable to failed.\n"
					copy_status="failed"
				fi

				printf "Writing log entry to disk.\n"
				echo "$timestamp,$username,$file,$delimType,$sizeOfFile,$md5sum,$numLinesWithText,$duplicatesFlag,$quotedValues,$evenQuotes,$numColumns,$minColumns,$maxColumns,$colAlign,$copy_status" >> /var/log/sftp-file-logging
			        printf "Writing to dynamodb.\n"	

			
				# write to dynamodb for future tracking in TRACKS
				# DynamoDB is source of record for successfully copied files. no need to insert failed copied or partial copied data as that is not needed by next phases of TRACKS.
				aws dynamodb put-item --table-name $DYNAMODB_TABLE --region $AWS_REGION --item '{ "UserName": { "S": '\"$username\"' }, "FileName" : { "S": '\"$file\"'}, "DelimiterType": {"S": '\"$delimType\"'}, "FileSize" : { "S" : '\"$sizeOfFile\"'}, "md5Sum" : { "S" : '\"$md5sum\"' }, "TotalLines" : { "S" : '\"$numLinesWithText\"' }, "Duplicates" : { "S": '\"$duplicatesFlag\"' }, "QuotedValues" : { "S": '\"$quotedValues\"' }, "EvenQuotes" : { "S": '\"$evenQuotes\"' }, "NumColumns" : { "S" : '\"$numColumns\"' } , "MinColumns" : { "S" : '\"$minColumns\"'}, "MaxColumns" : { "S" : '\"$maxColumns\"'}, "ColAligned" : { "S" : '\"$colAlign\"'}, "CopyStatus" : { "S" : '\"$copy_status\"'},"TimeStamp" : { "S" : '\"$timestamp\"'} }'


				


			else
				printf "Skipping $file because it is currently being written to.\n"
				copy_status="processing"
				nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "Skipping copy of $file because it is currently being written to.  File will be moved on next run of script.\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
				echo "$timestamp,$username,$file,,,,0,,,,,,,,processing" >> /var/log/sftp-file-logging
			fi
			
			printf "finished processing $file.\n\n"
			
		done
	else
		# No files were found.  Just print a new line to keep logging pretty

		 nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "No files found in $username directory. Nothing to copy.\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
		printf "\n"

	
	fi
	
done



	

 # PARAMETERIZE THIS
        aws s3 cp /var/log/sftp-file-logging $S3_LOG_FILE_LOCATION/sftp-file-logging --sse AES256 --region $AWS_REGION > /dev/null
	aws s3 cp /var/log/sftp-duplicates/ s3://BUCKET/file-ingestion/sftp-duplicates/ --sse AES256 --region $AWS_REGION --recursive > /dev/null
	rm -rf /var/log/sftp-duplicates/* 

