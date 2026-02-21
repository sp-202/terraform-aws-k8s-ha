import json
import urllib.request
import sys

def get_price(instance):
    url = f"https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.json"
    print(f"Checking {instance}...")

