#!/bin/bash 


SERVERNAME=`hostname -s`
LOG_GROUP=file-cleanser-sftp-server
LOG_STREAM=sftp-incoming-files
# NOTE: for variables that will hold URLs to use, don't add trailing '/'
SFTP_DIR=/sftp-incoming
S3_TARGET=s3://BUCKET/sftp-incoming/ENVIRONMENT
S3_LOG_FILE_LOCATION=s3://BUCKET/logs/sftp/ENVIRONMENT/file-info
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/)
AWS_REGION=$(echo ${AWS_REGION:0:-1})
DATE=$(date +%Y%m%d)
RANDOM_NUM=$(echo $((1 + RANDOM % 100000000)))
DYNAMODB_TABLE=file-cleanser-sftp-log
RULES_TABLE=file-cleanser-rules
TIMESTAMP=`date +%s%3N`
DATETIME=`date --utc +%Y%m%d_%H%M%SZ`
UserName=""
FileName="" 
DelimiterType=""
FileSize=""
md5Sum=""
md5Sum_post=""
TotalLines=""
Duplicates=""
QuotedValues=""
EvenQuotes=""
NumColumns=""
MinColumns=""
MaxColumns=""
ColAligned=""
CopyStatus=""
TimeStamp=""
FileType=""
CRLF=""
rule_defined="na"
file_expected="na"
CRLFCONVERTED="na"
alertNoData="na"
fileTypeIncoming="na"
md5sumPostCleanse="na"

ServerName=""

ACCOUNT_ID=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '(?<="accountId" : ")[^"]*(?=")'`
SNSARN="arn:aws:sns:us-east-1:$ACCOUNT_ID:file-cleanser-sftp-server-notifications"

	# Line below is for testing purposes.
	# output="/sftp-incoming/testuser1/incoming/ CLOSE_WRITE,CLOSE nice_formatted_csv_comma.csv"
	
output="$1 $2 $3"

TIMESTAMP=`date`
printf "Script execution begin: $TIMESTAMP\n"
printf "The following was passed to the script: $output\n"
eventDIR=`echo $output | cut -d ' ' -f1`
eventFILE=`echo $output | cut -d ' ' -f3-`

file=$eventFILE

# if you need to create a scratch file. Make sure you put -conv in the name so that the script
# doesn't execute twice when you create a new FILE_CLOSE event in the directory.
if [[ "$file" = *"-conv"* ]]; then
	printf "conversion file created. no need to run script.\n"
	exit
fi


printf "$eventDIR$eventFILE was uploaded \n"
username=`echo $eventDIR | cut -d '/' -f3`

# check to make sure log file has headers
# /var/log/sftp-file-logging-$SERVERNAME-$DATE
logFileLines=`grep -vc '^$' /var/log/sftp-file-logging-$SERVERNAME-$DATE`

#############################################

find_delimiter () { 

	firstline=$1
	delimiter=$2
	
	printf "Looking for delimiter $delimiter.\n"
	char=$2
	delim_count=`echo $firstline | awk -F "${char}" '{print NF-1}'`
	printf "Found $delim_count \"$char\"'s.\n"
	return $delim_count	
}

##############################################

send_notification () { 

	message=$1	
	printf "Sending SNS Notification\n"
	printf "Sending message to: $SNSARN\n"
	aws sns publish --topic-arn $SNSARN --message "$message." --region $AWS_REGION

}

##############################################

get_cleanse_rule () { 

	username=$1 
	filename=$2
	dayOfWeek=`date '+%a'`
	
	printf "Checking if $filename cleanser rule exists for $username\n"
	printf "Querying $RULES_TABLE...\n"																																								
	for row in `aws dynamodb query --table-name $RULES_TABLE --index-name UserName-index --region $AWS_REGION --key-condition-expression "UserName = :usernameValue" --expression-attribute-values '{":usernameValue":{"S":'\"$username\"'}}' | jq -c .Items[]`; do
		
		project=`echo $row | jq -r '.project.S'`
		
		if [[ "$filename" = *"$project"* ]]; then
			rule_defined="true"
			printf "Rule matched $filename\n"
			printf "Project: $project\n"
			printf "Rule exists for $filename\n"
			days_expected=`echo $row | jq -r '.days_expected.S'`
			printf "Days Expected: $days_expected\n"
			
			receive_alert=`echo $row | jq -r '.alert_on_receive.S'`
			printf "Alert on receive: $receive_alert\n"
							
			
			if [[ "$days_expected" == *"$dayOfWeek"* ]]; then
				printf "$filename is expected today ($dayOfWeek).\n"
				file_expected="true"
			else
				file_expected="false"
			fi
				
			contains_header=`echo $row | jq -r '.contains_header.S'`
			printf "Contains Header: $contains_header\n"
			
			if [[ "$contains_header" = "true" ]]; then
				header_line=`echo $row | jq -r '.header_line.S'`
				printf "Header line: $header_line\n"
				numLinesWithText=`grep -vc '^$' $file`
				if [[ numLinesWithText -gt header_line ]];then
					printf "This file contains data.\n"
					alertNoData="false"
				else
					printf "File possibly has no data!\n"d
					alertNoData="true"
				fi
			fi
			printf "Finished processing rule.\n"
			return 0
			
		else
			# No rule matched for this file
			rule_defined="false"
			file_expected="false"			
		fi
	done
	return 0

}

##############################################

log_to_cloudwatch () { 

	# this is for logging to cloudwatch.  We need to have cloudwatch token to upload logs.  The very first time you upload to a new logStream you don't have a token (it's 0). So the first
	# upload doesn't need one. Documentation for this command can be found at https://docs.aws.amazon.com/cli/latest/reference/logs/describe-log-streams.html.
	
	printf "Logging to cloudwatch\n"
	
	message=$1

	if [ -z $nextSeqToken ]; then
		printf "nextSeqToken is empty. Getting next token.\n"
		nextSeqToken=$(aws logs describe-log-streams --log-group $LOG_GROUP --log-stream-name-prefix $LOG_STREAM --region $AWS_REGION | jq '.logStreams[].uploadSequenceToken' | tr -d '"'``)
	
		if [ $nextSeqToken = "null" ]; then
			# this is the first log write
			printf "First write to log. No Sequence token required.\n"
			nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "running script from $(pwd)\n")" --region $AWS_REGION | jq '.nextSequenceToken' | tr -d '"'``)
		else
			printf "Running script from $(pwd)\n"
			nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$(printf "running script from $(pwd)\n")" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
		fi
 	#not necessary
	#else
		#printf "nextSeqToken has a value of $nextSeqToken\n"
	fi
	
	# If script cannot get next sequence token then it can just exit. No need to execute.  This happens if the script can't reach the cloudwatch service.  We had this happen a few times when the unbound dns
	# that we run was off.
	if [ -z $nextSeqToken ]; then
		printf 'Could not get next sequence token from cloudwatch logs.\n'
		printf 'Exiting script.\n'
		exit
	fi

	nextSeqToken=$(aws logs put-log-events --log-group-name $LOG_GROUP --log-stream-name $LOG_STREAM --log-events timestamp=$(date +%s%3N),message="$message" --region $AWS_REGION --sequence-token $nextSeqToken | jq '.nextSequenceToken' | tr -d '"'``)
	printf "Wrote $message to cloudwatch\n"
}

##############################################

printf "Starting script execution.\n"
log_to_cloudwatch "Script execution started: $TIMESTAMP"

if [[ logFileLines -eq 0 ]]; then
 echo "TIMESTAMP,USERNAME,FILENAME,DELIMTYPE,FILESIZE,MD5SUM,MD5SUM_POST,TOTALLINES,DUPLICATES,QUOTEDVALUES,EVENQUOTES,NUMCOLUMNS,MINCOLUMNS,MAXCOLUMNS,COLALIGN,COPYACTION,FILETYPE,CRLF,CRLFCONVERTED,RULEDEFINED,FILEEXPECTED,ALERTNODATA,FILETYPEINCOMING,RECEIVEALERT,SERVERNAME" >> /var/log/sftp-file-logging-$SERVERNAME-$DATE
fi


# This is here for debug purposes.
printf "Checking for files on sftp server in $AWS_REGION\n"

	printf "Checking $username directory for files...\n"
	log_to_cloudwatch "Checking $username directory"
	
	dirToCheck=$eventDIR
	printf "Changing to $dirToCheck\n"

	cd $dirToCheck
	# NOTE: the ls is -1 (one) not a lowercase l
	fileCount=$(ls -1 | wc -l)
	printf "$fileCount files in $dirToCheck\n"
	log_to_cloudwatch "Found $fileCount files."
	if [ $fileCount -gt 0 ]; then
			printf "Found: $file\n"
			log_to_cloudwatch "Found file $file"
			if  [[ `lsof $file` ]]; then
				# if the file is open, don't do anything. For example, a large file that takes time to upload. we need to wait.
				printf "Skipping $file because it is currently being written to.\n"
				copy_status="processing"
				log_to_cloudwatch "Skipping copy of $file because it is currently being written to.  File will be moved on next run of script."
				echo "$timestamp,$username,$file,$delimType,$sizeOfFile,$md5sum,$md5sum_post,$numLinesWithText,$duplicatesFlag,$quotedValues,$evenQuotes,$numColumns,$minColumns,$maxColumns,$colAlign,$copy_status,$file_type,$crlf,$crlf_converted,$alertNoData,$fileTypeIncoming,$md5sumPostCleanse,$receive_alert,$SERVERNAME" >> /var/log/sftp-file-logging-$SERVERNAME-$DATE
			else
				
				##############################################################

				#check if we have a cleanser rule for this username/file
				get_cleanse_rule $username $file
				
				# gather some stats on the file and log them.
				# check if this is a zip file
				fileType=`file -b $file`
				fileType=`echo $fileType | cut -d "," -f1 | cut -d ' ' -f1`
				
				fileTypeIncoming=$fileType
				
				
				md5sum=`md5sum $file | awk '{ print $1 }'`
				
				##############################################################
				if [[ "$fileType" = *"UTF-8"* || "$fileType" = *"ASCII"* ]]; then
					printf "File is in recognizable format.\n"
					:
				elif [[ "$fileType" = *"ISO-8859"* ]]; then
						printf "File is of type ISO-8859\n"
						printf "Converting file to utf-8.\n"
						if $(aws s3 cp $file $S3_TARGET/archive/$username/$file-$DATETIME --sse AES256 --region $AWS_REGION > /dev/null); then
							#Get current file format - mime output has the exact type
       						FORMAT=`file -i $file | cut -d "=" -f2`
							printf "FORMAT: $FORMAT\n"
							iconv -f $FORMAT -t UTF-8 $file >> $file-conv
							mv -f $file-conv $file
						fi
					
				elif [[ "$fileType" = *"Microsoft"* ]]; then
					printf "File is a Microsoft format.\n"
					if [[ "$file" = *".xlsx"* ]]; then
						printf "Converting $file to $(basename $file .xlsx).csv\n"
						if `/usr/bin/python /usr/local/bin/xlsx2csv -a $file $(basename $file .xlsx).csv`; then
							printf "Conversion successful.\n"
							if $(aws s3 mv $file $S3_TARGET/archive/$username/$file-$DATETIME --sse AES256 --region $AWS_REGION > /dev/null); then
								printf "Copying original file to s3 archive.\n"
								printf "Exiting. Script will trigger again for csv.\n"
								exit
							fi
						else
							printf "Conversion failed.\n"
						fi
					fi		
				else
					printf "File type is $fileType. Skipping checks and sending to s3.\n"
					log_to_cloudwatch "Found compressed $file"
					/usr/local/scripts/file_cleanser_non_csv_file_handler.sh $file $username >> /var/log/file_cleanser.log-$SERVERNAME-$DATE
					exit
				fi
				##############################################################
				
				# This is the size of the file in bytes
				sizeOfFile=`stat --printf="%s" $file` 
				printf "Size of file: $sizeOfFile\n"
				
				# md5sum of file
				# TODO: ADD THIS PRIOR AND ADD COLUMN IN DYNAMO
				md5sum_post=`md5sum $file | awk '{ print $1 }'`
				
				# We use grep to count only lines with text
				numLinesWithText=`grep -vc '^$' $file`

				#check for carraige return if CRLF, convert to LF
				# now that we have to convert to UTF-8 we probably won't need this.
				# keeping for good measuer.
				printf "Checking for CRLF...\n"
				crlf_check=`file -b $file`
				file_type=`echo $crlf_check | cut -d ',' -f1 | cut -d ' ' -f1`
				printf "$crlf_check\n"
				
				##############################################################
				if [[ $crlf_check == *" CRLF "* ]]; then
					printf "Found CRLF. Converting to LF.\n"
					crlf=true
					
					# Should we back up original?
					if `dos2unix -k -q -o $file`; then
						printf "conversion from crlf successful.\n"
						crlf_converted=success
					else
						printf "conversion from crlf failed.\n"
						crlf_converted=fail
					fi
				else
					printf "CRLF not found. Nothing to do.\n"
					crlf=false
					crlf_converted=na
				fi
				##############################################################
				

				# Check for duplicates
				# first, we need to remove blank lines. multiple blank lines are counted as duplicates
				tmpFile=`mktemp /var/tmp/move_script.XXXXX`
				sed -i '/^$/d' $file > $tmpFile 
				
				##############################################################
				# next, look for duplicate lines
				duplicates=`sort $file | sort | uniq -d | wc -l`
				if [ $duplicates -gt 0 ]; then
					printf "Found $duplicates duplicates in $file\n"
					sort $file | sort | uniq -d >> /var/log/sftp-duplicates/$DATE-$username-$file-$RANDOM_NUM
					duplicatesFlag=true
				else
					duplicatesFlag=false
				fi
				##############################################################
				

				# We will read in the first line of the file for the next tests
                firstLine=`head -1 $file`

				# check if file values are quoted
				quotedCount=`grep -o '"' <<< $firstLine | wc -l`
				printf "Found $quotedCount quotes in first line of $file\n"

				##############################################################
				if [[ $quotedCount -eq 0 ]]; then
					printf "File does not contain quoted values.\n"
					quotedValues=false
					evenQuotes=na
				else
					printf "File contains quoted values.\n"
					quotedValues=true

					 # Do we have an even number of quotes?
                                	if [[ $(( $quotedCount % 2 )) -eq 0 ]]; then
                                        	printf "Even number of quotes.\n"
                                        	evenQuotes=true
                                	else
                                        	printf "Odd number of quotes, file may not load properlly\n"
                                        	evenQuotes=false
                                        	# TODO: send notification  of possible load failure
                               		 fi
				fi 
				##############################################################
				

				# now we count columns. First we need to figure out what our delimeter is
                # we will test for common delimeters such as pipe, comma and tab
				numColumns=0
				
				# Let's try to find the delimiter
				find_delimiter "$firstLine" ","
				comma_delim=$?
				printf "Found $comma_delim commas.\n"
				
				find_delimiter "$firstLine" "|"
				pipe_delim=$?
				printf "Found $pipe_delim pipes.\n"
				
				find_delimiter "$firstLine" ";"
				semicol_delim=$?
				printf "Found $semicol_delim semicolons.\n"
				
				##############################################################
				if [ $comma_delim -gt $pipe_delim ] && [ $comma_delim -gt $semicol_delim ]; then
					printf "File is comma delimited.\n"
					delim=","
					delimType="comma"
			 	elif [ $pipe_delim -gt $semicol_delim ] && [  $pipe_delim -gt $comma_delim ]; then
			 		printf "File is pipe delimited.\n"
			 		delim="|"
			 		delimType="pipe"
			 	elif [ $semicol_delim -gt $pipe_delim ] && [ $semicol_delim -gt $comma_delim ]; then
			 		printf "File is semicolon delimited.\n"
			 		delim=";"
			 		delimType="semicolon"
			 	else
			 		printf "Delimiter not found.\n"
			 		delimType="none_found"
			 	fi
				##############################################################
				
				echo $firstLine | grep -q "$delim"
				
				##############################################################
				if [ $? -eq 0 ]; then
					printf "Checking for mismatched columns.\n"	
					#delimType="comma"
					maxColumns=`awk -F "$delim" '{ print NF }' $file | sort -nu |  tail -n 1`
					minColumns=`awk -F "$delim" '{ print NF }' $file | sort -nu |  head -n 1`
					numColumns=$maxColumns
					
					if [ $maxColumns -ne $minColumns ]; then
						printf "Column mismatch in file. Possible bad load.\n"
						colAlign="no"
					else
						numColumns=$maxColumns
						printf "$file has $numColumns columns.\n"
						colAlign="yes"
					fi
				fi
				##############################################################
				
				
				printf "Checking if minColumns is empty.\n"
				
				##############################################################
				
				if [[ -z $minColumns ]]; then
					printf "minColumns is empty.  Setting value to 0.\n"
					minColumns="0"
				fi
				##############################################################
				
				printf "Checking if maxColumns is empty.\n"
				
				##############################################################
				
				if [[ -z $maxColumns ]]; then
					printf "maxColumns is empty. Setting value to 0.\n"
					maxColumns="0"
					numColumns="0"
				fi

				##############################################################
				
				md5sumPostCleanse=`md5sum $file | awk '{ print $1 }'`
				printf "md5sum after Midas: $md5sumPostCleanse\n"

				printf "Start copying $file\n"
				log_to_cloudwatch "Starting copy of $file of $sizeOfFile bytes with $numLines and md5sum of $md5sum to $S3_TARGET/$username/"
				timestamp=`date --utc +%FT%TZ` 
				##############################################################	
				if $(aws s3 mv $file $S3_TARGET/$username/$file --sse AES256 --region $AWS_REGION > /dev/null); then				
					printf "Copy successful. Setting copy_status variable to copied.\n"
					copy_status="success"
				else
					printf "Copy not successful. Setting copy_status variable to failed.\n"
					copy_status="failed"
				    #---
				    send_notification "$file copy from $SERVERNAME to s3 failed for $username. Please review sftp server to determine reason."
				    #$(aws sns publish --topic-arn $SNSARN --message "$file copy from $SERVERNAME to s3 failed for $username.Please review sftp server to determine reason." --region $AWS_REGION)
			        #---	
				fi
				##############################################################

				printf "Writing log entry to disk.\n"
				printf "$timestamp,$username,$file,$delimType,$sizeOfFile,$md5sum,$md5sum_post,$numLinesWithText,$duplicatesFlag,$quotedValues,$evenQuotes,$numColumns,$minColumns,$maxColumns,$colAlign,$copy_status,$file_type,$crlf,$crlf_converted,$rule_defined,$file_expected,$alertNoData,$fileTypeIncoming,$md5sumPostCleanse,$receive_alert,$SERVERNAME\n"
				echo "$timestamp,$username,$file,$delimType,$sizeOfFile,$md5sum,$md5sum_post,$numLinesWithText,$duplicatesFlag,$quotedValues,$evenQuotes,$numColumns,$minColumns,$maxColumns,$colAlign,$copy_status,$file_type,$crlf,$crlf_converted,$rule_defined,$file_expected,$alertNoData,$fileTypeIncoming,$md5sumPostCleanse,$receive_alert,$SERVERNAME" >> /var/log/sftp-file-logging-$SERVERNAME-$DATE
			    printf "Copying file log to s3.\n"
				##############################################################
			    if $(aws s3 cp /var/log/sftp-file-logging-$SERVERNAME-$DATE $S3_LOG_FILE_LOCATION/sftp-file-logging-$SERVERNAME-$DATE --sse AES256 --region $AWS_REGION > /dev/null); then
			    	printf "Copy of file logs to s3 successful.\n"
			   	else
			   		printf "Copy of file logs to s3 failed.\n"
			   	fi
				##############################################################
				
			   	printf "Sending duplicates log to s3.\n"
			   	if $(aws s3 cp /var/log/sftp-duplicates/ s3://BUCKET/file-ingestion/sftp-duplicates/ --sse AES256 --region $AWS_REGION --recursive > /dev/null); then
			   		printf "Copy of duplicates log to s3 sucessful.\n"
			   		rm -rf /var/log/sftp-duplicates/* 
			   	else
			   		printf "Copy of duplicates log to s3 failed.\n"
			   	fi
				##############################################################
				
				
			    printf "Writing to dynamodb.\n"	
				# write to dynamodb for future tracking in TRACKS
				# DynamoDB is source of record for successfully copied files. no need to insert failed copied or partial copied data as that is not needed by next phases of TRACKS.

				if `aws dynamodb put-item --table-name $DYNAMODB_TABLE --region $AWS_REGION --item '{ "UserName": { "S": '\"$username\"' }, "FileName" : { "S": '\"$file\"'}, "DelimiterType": {"S": '\"$delimType\"'}, "FileSize" : { "S" : '\"$sizeOfFile\"'}, "md5Sum" : { "S" : '\"$md5sum\"' }, "md5Sum_post" : { "S" : '\"$md5sum_post\"' }, "TotalLines" : { "S" : '\"$numLinesWithText\"' }, "Duplicates" : { "S": '\"$duplicatesFlag\"' }, "QuotedValues" : { "S": '\"$quotedValues\"' }, "EvenQuotes" : { "S": '\"$evenQuotes\"' }, "NumColumns" : { "S" : '\"$numColumns\"' } , "MinColumns" : { "S" : '\"$minColumns\"'}, "MaxColumns" : { "S" : '\"$maxColumns\"'}, "ColAligned" : { "S" : '\"$colAlign\"'}, "CopyStatus" : { "S" : '\"$copy_status\"'},"TimeStamp" : { "S" : '\"$timestamp\"'},"FileType" : { "S" : '\"$file_type\"'}, "CRLF" : { "S" : '\"$crlf\"'}, "CRLFCONVERTED" : { "S" : '\"$crlf_converted\"'},"RuleDefined" : { "S" : '\"$rule_defined\"'},"FileExpected" : { "S" : '\"$file_expected\"'},"AlertNoData" : { "S" : '\"$alertNoData\"'},"fileTypeIncoming" : { "S" : '\"$fileTypeIncoming\"'},"md5sumPostCleanse" : { "S" : '\"$md5sumPostCleanse\"'},"receive_alert" : { "S" : '\"$receive_alert\"'},"ServerName" : { "S" : '\"$SERVERNAME\"'} }' >> /var/log/sftp-file-logging-$SERVERNAME-$DATE `; then
					printf "write to dynamodb successful.\n"
			 	else
			 		printf "write to dynamodb failed.\n"
			 	fi
			
				printf "finished processing $file.\n"
				TIMESTAMP=`date`
    			printf "Script execution ended: $TIMESTAMP\n"
    			log_to_cloudwatch "Script execution ended: $TIMESTAMP"
    			rm -rf /var/tmp/move_script.*
    			printf "\n\n"
			
		fi # DONE if file not open
	
	else
		printf "No files were found. \n"
		# No files were found.  Just print a new line to keep logging pretty
		 log_to_cloudwatch "No files found in $username directory. Nothing to copy."
		printf "\n"
	fi




