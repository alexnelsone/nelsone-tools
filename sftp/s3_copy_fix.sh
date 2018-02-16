#!/bin/bash 

aws s3api list-objects-v2 --bucket BUCKET --prefix logs/sftp/ENV/eu-west-1/ --query "Contents[?StorageClass=='STANDARD']" --output text | awk '{print $2}' > file_list.txt

while read KEY
do
        filename=`echo $KEY | awk -F '/' '{print $5}'`

        aws s3 cp s3://BUCKET/$KEY $filename

        __format=$(file -i "${filename}" | cut -d "=" -f2)

        if [ "${filename}" == *.xlsx ]
        then

                xlsx2csv "${filename}" "$(basename "${filename}" .xlsx).csv"
                rm "${filename}"

        elif [ "${__format}" = "unknown-8bit" ]
        then

                cat -v "${filename}" > processing-"${filename}"

        else

                iconv -f "${__format}" -t utf-8 "${filename}" > processing-"${filename}"
        fi

        dos2unix -k -q -o processing-"${filename}"

        if [ -s processing-"${filename}" ]
        then
                mv -f processing-"${filename}" "${filename}"
        else
                mv -f processing-"${filename}" error-"${filename}"
        fi

        aws s3 cp $filename s3://BUCKET/file-ingestion/processed/sftp-logs/$filename --sse

        rm -rf $filename

done < file_list.txt


