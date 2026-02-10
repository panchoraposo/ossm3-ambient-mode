#!/bin/bash

# Configuration
NAMESPACE="bookinfo"
ROUTE_NAME="bookinfo-gateway"
APP_PATH="/productpage"

echo "------------------------------------------------"
echo "🔍 Discovering Bookinfo Route..."

# 1. Get the Host directly from the OpenShift Route
HOST=$(oc get route $ROUTE_NAME -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null)

# 2. Validation
if [ -z "$HOST" ]; then
    echo "❌ Error: Could not find route '$ROUTE_NAME' in namespace '$NAMESPACE'."
    echo "   Please run: 'oc get route -n $NAMESPACE' to verify the name."
    exit 1
fi

# 3. Construct the URL
URL="http://${HOST}${APP_PATH}"

echo "✅ Target acquired: $URL"
echo "🚀 Generating traffic... (Press CTRL+C to stop)"
echo "------------------------------------------------"

# 4. Traffic Loop
while true; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
    
    TIMESTAMP=$(date +"%H:%M:%S")
    
    if [ "$CODE" == "200" ]; then
        echo "[$TIMESTAMP] Status: $CODE (OK)"
    else
        echo "[$TIMESTAMP] Status: $CODE (Checking...)"
    fi
    
    # Wait 0.5 seconds between requests
    sleep 0.5
done