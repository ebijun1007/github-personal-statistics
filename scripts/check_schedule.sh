#!/bin/bash

# Convert current time to JST
CURRENT_HOUR_JST=$(TZ=Asia/Tokyo date +%H)

# Check if current hour is 6 AM or 6 PM JST
if [ "$CURRENT_HOUR_JST" = "06" ] || [ "$CURRENT_HOUR_JST" = "18" ]; then
    exit 0
else
    exit 1
fi
