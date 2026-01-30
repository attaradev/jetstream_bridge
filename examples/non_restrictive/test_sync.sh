#!/bin/bash

# Test script for non-restrictive example
# Demonstrates end-to-end sync between System A and System B

set -e

echo "======================================"
echo "JetStream Bridge - Non-Restrictive Example"
echo "Bidirectional Sync Test"
echo "======================================"
echo

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SYSTEM_A_URL="http://localhost:3000"
SYSTEM_B_URL="http://localhost:3001"

# Add per-run uniqueness to avoid collisions when re-running the script
RUN_SUFFIX=$(date +%s)
ORG_NAME="Test Corp ${RUN_SUFFIX}"
ORG_DOMAIN="testcorp-${RUN_SUFFIX}.com"
ORG_UPDATED_NAME="Test Corporation ${RUN_SUFFIX}"
USER_EMAIL="test@${ORG_DOMAIN}"

ORG_B_NAME="Beta Corp ${RUN_SUFFIX}"
ORG_B_DOMAIN="betacorp-${RUN_SUFFIX}.com"
USER_B_EMAIL="bob@${ORG_B_DOMAIN}"

echo -e "${BLUE}Step 1: Checking service health...${NC}"
curl -f $SYSTEM_A_URL/health || { echo "System A not ready"; exit 1; }
curl -f $SYSTEM_B_URL/health || { echo "System B not ready"; exit 1; }
echo -e "${GREEN}✓ Both systems healthy${NC}"
echo

echo -e "${BLUE}Step 2: Creating organization in System A...${NC}"
ORG_RESPONSE=$(curl -s -X POST $SYSTEM_A_URL/organizations \
  -H "Content-Type: application/json" \
  -d "{
    \"organization\": {
      \"name\": \"${ORG_NAME}\",
      \"domain\": \"${ORG_DOMAIN}\",
      \"active\": true
    }
  }")

echo "$ORG_RESPONSE" | jq '.'
ORG_ID=$(echo "$ORG_RESPONSE" | jq -r '.id // empty')
if [ -z "$ORG_ID" ]; then
  echo -e "${RED}✗ Failed to create organization in System A${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Created organization with ID: $ORG_ID${NC}"
echo

echo -e "${BLUE}Step 3: Waiting for sync to System B (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 4: Verifying organization synced to System B...${NC}"
SYNCED_ORG=$(curl -s $SYSTEM_B_URL/organizations/$ORG_ID)
echo "$SYNCED_ORG" | jq '.'

SYNCED_NAME=$(echo "$SYNCED_ORG" | jq -r '.name')
if [ "$SYNCED_NAME" == "$ORG_NAME" ]; then
  echo -e "${GREEN}✓ Organization successfully synced!${NC}"
else
  echo -e "${YELLOW}✗ Organization not synced yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 5: Creating user in System A...${NC}"
USER_RESPONSE=$(curl -s -X POST $SYSTEM_A_URL/users \
  -H "Content-Type: application/json" \
  -d "{
    \"user\": {
      \"organization_id\": $ORG_ID,
      \"name\": \"Test User\",
      \"email\": \"${USER_EMAIL}\",
      \"role\": \"admin\",
      \"active\": true
    }
  }")

echo "$USER_RESPONSE" | jq '.'
USER_ID=$(echo "$USER_RESPONSE" | jq -r '.id // empty')
if [ -z "$USER_ID" ]; then
  echo -e "${RED}✗ Failed to create user in System A${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Created user with ID: $USER_ID${NC}"
echo

echo -e "${BLUE}Step 6: Waiting for sync to System B (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 7: Verifying user synced to System B...${NC}"
SYNCED_USER=$(curl -s $SYSTEM_B_URL/users/$USER_ID)
echo "$SYNCED_USER" | jq '.'

SYNCED_EMAIL=$(echo "$SYNCED_USER" | jq -r '.email')
if [ "$SYNCED_EMAIL" == "$USER_EMAIL" ]; then
  echo -e "${GREEN}✓ User successfully synced!${NC}"
else
  echo -e "${YELLOW}✗ User not synced yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 8: Updating organization in System A...${NC}"
UPDATE_RESPONSE=$(curl -s -X PATCH $SYSTEM_A_URL/organizations/$ORG_ID \
  -H "Content-Type: application/json" \
  -d "{
    \"organization\": {
      \"name\": \"${ORG_UPDATED_NAME}\"
    }
  }")

echo "$UPDATE_RESPONSE" | jq '.'
echo -e "${GREEN}✓ Updated organization${NC}"
echo

echo -e "${BLUE}Step 9: Waiting for update to sync (polling up to 10 seconds)...${NC}"
UPDATE_SYNCED=false
UPDATED_ORG=""
for i in {1..10}; do
  UPDATED_ORG=$(curl -s $SYSTEM_B_URL/organizations/$ORG_ID)
  UPDATED_NAME=$(echo "$UPDATED_ORG" | jq -r '.name')
  if [ "$UPDATED_NAME" == "$ORG_UPDATED_NAME" ]; then
    UPDATE_SYNCED=true
    break
  fi
  sleep 1
done
echo

echo -e "${BLUE}Step 10: Verifying update synced to System B...${NC}"
echo "$UPDATED_ORG" | jq '.'

if [ "$UPDATE_SYNCED" == true ]; then
  echo -e "${GREEN}✓ Update successfully synced!${NC}"
else
  echo -e "${YELLOW}✗ Update not synced yet after 10 seconds${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 11: Checking sync status on System B...${NC}"
SYNC_STATUS=$(curl -s $SYSTEM_B_URL/sync_status)
echo "$SYNC_STATUS" | jq '.'
echo

echo -e "${BLUE}Step 12: Testing reverse direction - Creating organization in System B...${NC}"
ORG_B_RESPONSE=$(curl -s -X POST $SYSTEM_B_URL/organizations \
  -H "Content-Type: application/json" \
  -d "{
    \"organization\": {
      \"name\": \"${ORG_B_NAME}\",
      \"domain\": \"${ORG_B_DOMAIN}\",
      \"active\": true
    }
  }")

echo "$ORG_B_RESPONSE" | jq '.'
ORG_B_ID=$(echo "$ORG_B_RESPONSE" | jq -r '.id // empty')
if [ -z "$ORG_B_ID" ]; then
  echo -e "${RED}✗ Failed to create organization in System B${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Created organization in System B with ID: $ORG_B_ID${NC}"
echo

echo -e "${BLUE}Step 13: Waiting for reverse sync to System A (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 14: Verifying organization synced from B to A...${NC}"
SYNCED_ORG_B=$(curl -s $SYSTEM_A_URL/organizations/$ORG_B_ID)
echo "$SYNCED_ORG_B" | jq '.'

SYNCED_B_NAME=$(echo "$SYNCED_ORG_B" | jq -r '.name')
if [ "$SYNCED_B_NAME" == "$ORG_B_NAME" ]; then
  echo -e "${GREEN}✓ Organization successfully synced from B to A!${NC}"
else
  echo -e "${YELLOW}✗ Organization not synced from B to A yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 15: Creating user in System B...${NC}"
USER_B_RESPONSE=$(curl -s -X POST $SYSTEM_B_URL/users \
  -H "Content-Type: application/json" \
  -d "{
    \"user\": {
      \"organization_id\": $ORG_B_ID,
      \"name\": \"Bob Johnson\",
      \"email\": \"${USER_B_EMAIL}\",
      \"role\": \"user\",
      \"active\": true
    }
  }")

echo "$USER_B_RESPONSE" | jq '.'
USER_B_ID=$(echo "$USER_B_RESPONSE" | jq -r '.id // empty')
if [ -z "$USER_B_ID" ]; then
  echo -e "${RED}✗ Failed to create user in System B${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Created user in System B with ID: $USER_B_ID${NC}"
echo

echo -e "${BLUE}Step 16: Waiting for user sync from B to A (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 17: Verifying user synced from B to A...${NC}"
SYNCED_USER_B=$(curl -s $SYSTEM_A_URL/users/$USER_B_ID)
echo "$SYNCED_USER_B" | jq '.'

SYNCED_B_EMAIL=$(echo "$SYNCED_USER_B" | jq -r '.email')
if [ "$SYNCED_B_EMAIL" == "$USER_B_EMAIL" ]; then
  echo -e "${GREEN}✓ User successfully synced from B to A!${NC}"
else
  echo -e "${YELLOW}✗ User not synced from B to A yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 18: Checking sync status on both systems...${NC}"
echo -e "${YELLOW}System A:${NC}"
curl -s $SYSTEM_A_URL/sync_status | jq '.'
echo
echo -e "${YELLOW}System B:${NC}"
curl -s $SYSTEM_B_URL/sync_status | jq '.'
echo

echo "======================================"
echo -e "${GREEN}✓ All bidirectional tests passed!${NC}"
echo "======================================"
echo
echo "Summary:"
echo "- Created organization in System A → synced to System B ✓"
echo "- Created user in System A → synced to System B ✓"
echo "- Updated organization in System A → synced to System B ✓"
echo "- Created organization in System B → synced to System A ✓"
echo "- Created user in System B → synced to System A ✓"
echo
echo "Bidirectional JetStream Bridge is working correctly!"
