param([string]$path = "PATH_TO_FILES",[string]$file="",[string]$username="")

#$path="PATH_TO_FILES"
$s3Bucket="BUCKET"
$s3Bucket2="BUCKET"
#$s3Bucket3="BUCKET"
$environment="ENV"

Start-Transcript -path c:\scripts\remove_spaces-output.log

        echo checking "$file"
        if ($file -like '* *') {
        echo $file -replace ' ', '_'
        $newFileName= $file -replace ' ', '_'
        Rename-Item -NewName $newFileName -Path $path$item\$file
        echo Copying $path$item$newFileName to $s3Bucket/sftp-incoming/$environment/$username/$newFileName
        Write-S3Object -BucketName $s3Bucket -File $path$item\$newFileName  -Key sftp-incoming/$environment/$username/$newFileName -ServerSideEncryption AES256
        #Write-S3Object -BucketName $s3Bucket3 -File $path$item\$newFileName  -Key sftp-incoming/$environment/$username/$newFileName -ServerSideEncryption AES256
        Write-S3Object -BucketName $s3Bucket2 -File $path$item\$newFileName -Key sftp-incoming/$username/$newFileName -ServerSideEncryption AES256
        Remove-Item -path $path$item$newFileName
}
     

Stop-Transcript
