#!/bin/bash/ 

#Dynamically convert files to UTF-8 -- experimenting with converting unknown-8bit to ASCII
for FILE in *; do
	
	#Get current file format - mime output has the exact type
	FORMAT=`file -i $FILE | cut -d "=" -f2`
	
	#Catch if the file is in XLSX format and convert it to CSV
	if [ $FILE == *.xlsx ]
	then
		
		#Requires xlsx2csv.py to be in the PATH
		xlsx2csv "$FILE" "$(basename "$FILE" .xlsx).csv"
			
		#Results will automatically be in UTF-8-remove old file
		rm $FILE
		
	elif [ $FORMAT = "unknown-8bit" ]
	then
		
		#Cat the file to ASCII -- subset of UTF-8
		cat -v $FILE > processing-$FILE
		
	else
		
		#Convert the encoding to UTF-8 and output to a temp file
		iconv -f $FORMAT -t utf-8 $FILE > processing-$FILE
	
	fi
	
	#Convert the file to Linux (CRLF to LF)
	dos2unix -k -q -o processing-$FILE
	
	if [ -s processing-"$FILE" ]
	then
		
		#The file has data, overwrite the original file with the converted file
		mv -f processing-$FILE $FILE
	
	else
		
		#The file is zero-byte, something failed, so leave the original file alone
		mv -f processing-$FILE error-$FILE
	fi
done

