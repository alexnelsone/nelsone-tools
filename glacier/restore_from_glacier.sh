#!/bin/bash

# TODO: add bulk restore option
# HOW TO USE THIS SCRIPT
# Replace the S3prefix variable below with the prefix for the files you want to restore
# Replace the root_bucket variable with the bucket name
# You do not need the beginning / on the S3Prefix or any / on the root_bucket

# root_bucket should be set to the bucket that contains the object you want to modify the storage class of.
root_bucket="BUCKET"
S3prefix="PREFIX"
tmp_file="/var/tmp/restore_from_glacier"

#aws sns publish --topic-arn arn:aws:sns:eu-west-1:167977214020:cordis-redshift-cluster-default-alarms --subject "STARTED: Collecting list of EMR data files to move from Glacier to standard storage" --message "Started collecting file list of EMR files in $root_bucket. Another message will be sent when the job is completed and the move is starting." --region eu-west-1

printf "collecting files to change class\n"
aws s3api list-objects-v2 --bucket $root_bucket  --prefix emr-appdata --prefix $S3prefix --query "Contents[?StorageClass=='GLACIER']" --output text  | awk '{print $2}' > $tmp_file


#aws sns publish --topic-arn arn:aws:sns:eu-west-1:ACCOUNTNUMBER:cordis-redshift-cluster-default-alarms --subject "STARTING: Move data files from Glacier to standard storage" --message "Finished creating file list. Starting move of data files in $root_bucket has started. Another message will be sent when the job is completed to verify success." --region eu-west-1

printf "processing `wc -l $tmp_file`"
counter=0
while read KEY
do
        printf "requesting restore of object $KEY\n"
        aws s3api restore-object --restore-request Days=122 --bucket $root_bucket --key $KEY
        counter=$((counter+1))
        printf "$counter files processes\n"
done < $tmp_file
#
# sleep for enough time for restores (not needed)
#sleep 14400
#
printf "requested restore of $counter files from $root_bucket/$S3prefix\n"
printf "starting move to standard storage.\n"
printf "this part will take a long time per file.\n"

#
counter=0

while read KEY
do
        printf "\nmoving $KEY\n"
        aws s3api copy-object --copy-source $root_bucket/$KEY  --key $KEY  --bucket $root_bucket --server-side-encryption AES256 --storage-class STANDARD --acl bucket-owner-full-control
        counter=$((counter+1))
        printf "$counter files processes\n"
done < $tmp_file


printf "removing scratch file\n"
rm -rf /var/tmp/files2.txt
