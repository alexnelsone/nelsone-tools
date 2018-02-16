#!/bin/bash 

SERVERNAME=`hostname -s`
DATE=$(date +%Y%m%d)
S3_LOG_FILE_LOCATION=s3://BUCKET/logs/sftp/test/move-script-logs/

while output=`inotifywait -r -e close_write "/sftp-incoming/"`
do
        printf "a file was uploaded to sftp-incoming\n"
        printf "output: $output\n"

        eventDIR=`echo $output | cut -d ' ' -f1`
        eventFILE=`echo $output | cut -d ' ' -f3-`
        
        cd $eventDIR
		if [[ $eventFILE == *" "* ]]
		then
			printf "$eventFILE has spaces.\n"
			mv "$eventFILE" "${eventFILE//[[:space:]]}"
			eventFILE=${eventFILE//[[:space:]]}
			printf "spaces removed from filename. ($eventFILE)\n"
			
		fi
        
        printf "eventFILE is set to: $eventFILE\n"

        printf "$eventFILE has been written to $eventDIR\n"

        # We check if the file has a period in it.  Because sometimes scratch/tmp
        # files trigger the script to run and we don't want that.
                if [[ $eventFILE == *"."* ]]
                then
                        /usr/local/scripts/file_cleanser.sh $eventDIR "-" $eventFILE >> /var/log/file_cleanser.log-$SERVERNAME-$DATE &
                else
                        printf "Nothing to do.\n"
                fi

        aws s3 cp /var/log/file_cleanser.log-$SERVERNAME-$DATE $S3_LOG_FILE_LOCATION --sse --region us-east-1
done


