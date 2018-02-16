#!/bin/bash 

# grab latest version of THIS file
# aws s3 cp s3://BUCKET/deployment/binaries/sftp/pull_latest.sh pull_latest

TIMESTAMP=`date '+%Y-%m-%d-%H_%M_%S'`
S3_LOCATION=s3://BUCKET/deployment/binaries/sftp
FILE_TO_COPY=file_cleanser.sh
STARTUP_SCRIPT=file_cleanser_start.sh
NONCSV_FILE_SCRIPT=file_cleanser_non_csv_file_handler.sh

# copy running script
cp $FILE_TO_COPY ./backups/$FILE_TO_COPY-$TIMESTAMP
aws s3 cp $S3_LOCATION/$FILE_TO_COPY /usr/local/scripts/$FILE_TO_COPY
chmod +x /usr/local/scripts/$FILE_TO_COPY

# copy compressed file script
cp $NONCSV_FILE_SCRIPT ./backups/$NONCSV_FILE_SCRIPT-$TIMESTAMP
aws s3 cp $S3_LOCATION/$NONCSV_FILE_SCRIPT /usr/local/scripts/$NONCSV_FILE_SCRIPT
chmod +x /usr/local/scripts/$NONCSV_FILE_SCRIPT

# copy startup script
cp $STARTUP_SCRIPT ./backups/$STARTUP_SCRIPT-$TIMESTAMP
aws s3 cp $S3_LOCATION/$STARTUP_SCRIPT /usr/local/scripts/$STARTUP_SCRIPT
chmod +x /usr/local/scripts/$STARTUP_SCRIPT

