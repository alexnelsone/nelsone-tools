#boto3 is the AWS python library
import boto3
import json
import logging, inspect
import datetime, time



# for local testing set profile
# boto3.setup_default_session(profile_name='nelsone')
current_session = boto3.session.Session()
current_region = current_session.region_name

dynamodb = boto3.client('dynamodb')

'''This function is used for logging
   To use it, in your function/catch, pass in your Exception and the Logging Level
   
   Logging Levels are:
       CRITICAL
       ERROR
       WARNING
       DEBUG
       INFO
       NOTSET
       

'''
def log(e, logging_level):
    func_name=inspect.currentframe().f_back.f_code
    logging_level = logging_level.upper()
    print(logging_level+":"+func_name.co_name+':'+str(e))
    
    
''' used to evaluate if any returned structures are empty'''
def is_empty(any_structure):
    if any_structure:
        return False
    else:
        return True
    

'''#This is the main handler for lambda function'''
def lambda_handler(event, context):
    print("Hello World!")
    pass
# Make attempts to catch and log exceptions.
#     try:
#         
# 
#     except Exception as e:
#          log(e, 'warning')
        


# this calls the main lambda function when developing and debugging locally.
if __name__ == '__main__':
    lambda_handler(None, None)