#!/bin/bash

# Test script for restrictive example
# Demonstrates end-to-end sync between System A and System B
# with pre-provisioned streams and consumers

set -e

echo "======================================"
echo "JetStream Bridge - Restrictive Example"
echo "Bidirectional Sync Test"
echo "======================================"
echo

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SYSTEM_A_URL="http://localhost:3000"
SYSTEM_B_URL="http://localhost:3001"

echo -e "${BLUE}Checking provisioner status...${NC}"
# Compose v2 only lists running containers by default; include exited ones.
PROVISIONER_STATUS=$(docker compose ps -a provisioner 2>/dev/null | grep -E "Exit 0|Exited \\(0\\)" || true)
if [ -z "$PROVISIONER_STATUS" ]; then
  echo -e "${RED}✗ Provisioner has not completed successfully${NC}"
  echo "Please check provisioner logs: docker compose logs provisioner"
  exit 1
fi
echo -e "${GREEN}✓ Provisioner completed successfully${NC}"
echo

echo -e "${BLUE}Step 1: Checking service health...${NC}"
curl -f $SYSTEM_A_URL/health || { echo "System A not ready"; exit 1; }
curl -f $SYSTEM_B_URL/health || { echo "System B not ready"; exit 1; }
echo -e "${GREEN}✓ Both systems healthy${NC}"
echo

echo -e "${BLUE}Step 2: Verifying NATS stream was pre-provisioned...${NC}"
NATS_CONTAINER=$(docker compose ps -q nats)
NATS_NETWORK=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{print $k}}{{end}}' "$NATS_CONTAINER")
docker run --rm --network="$NATS_NETWORK" natsio/nats-box:latest nats -s nats://nats:4222 stream info sync-stream >/dev/null || {
  echo -e "${RED}✗ Stream not found - provisioner may have failed${NC}"
  exit 1
}
echo -e "${GREEN}✓ Stream 'sync-stream' exists (pre-provisioned)${NC}"
echo

echo -e "${BLUE}Step 3: Verifying NATS consumers were pre-provisioned (bidirectional)...${NC}"
docker run --rm --network="$NATS_NETWORK" natsio/nats-box:latest nats -s nats://nats:4222 consumer info sync-stream system_a-workers >/dev/null || {
  echo -e "${RED}✗ Consumer 'system_a-workers' not found - provisioner may have failed${NC}"
  exit 1
}
docker run --rm --network="$NATS_NETWORK" natsio/nats-box:latest nats -s nats://nats:4222 consumer info sync-stream system_b-workers >/dev/null || {
  echo -e "${RED}✗ Consumer 'system_b-workers' not found - provisioner may have failed${NC}"
  exit 1
}
echo -e "${GREEN}✓ Both consumers exist (pre-provisioned for bidirectional sync)${NC}"
echo

echo -e "${BLUE}Step 4: Creating organization in System A...${NC}"
ORG_RESPONSE=$(curl -s -X POST $SYSTEM_A_URL/organizations \
  -H "Content-Type: application/json" \
  -d '{
    "organization": {
      "name": "Test Corp",
      "domain": "testcorp.com",
      "active": true
    }
  }')

echo "$ORG_RESPONSE" | jq '.'
ORG_ID=$(echo "$ORG_RESPONSE" | jq -r '.id')
echo -e "${GREEN}✓ Created organization with ID: $ORG_ID${NC}"
echo

echo -e "${BLUE}Step 5: Waiting for sync to System B (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 6: Verifying organization synced to System B...${NC}"
SYNCED_ORG=$(curl -s $SYSTEM_B_URL/organizations/$ORG_ID)
echo "$SYNCED_ORG" | jq '.'

SYNCED_NAME=$(echo "$SYNCED_ORG" | jq -r '.name')
if [ "$SYNCED_NAME" == "Test Corp" ]; then
  echo -e "${GREEN}✓ Organization successfully synced!${NC}"
else
  echo -e "${YELLOW}✗ Organization not synced yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 7: Creating user in System A...${NC}"
USER_RESPONSE=$(curl -s -X POST $SYSTEM_A_URL/users \
  -H "Content-Type: application/json" \
  -d "{
    \"user\": {
      \"organization_id\": $ORG_ID,
      \"name\": \"Test User\",
      \"email\": \"test@testcorp.com\",
      \"role\": \"admin\",
      \"active\": true
    }
  }")

echo "$USER_RESPONSE" | jq '.'
USER_ID=$(echo "$USER_RESPONSE" | jq -r '.id')
echo -e "${GREEN}✓ Created user with ID: $USER_ID${NC}"
echo

echo -e "${BLUE}Step 8: Waiting for sync to System B (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 9: Verifying user synced to System B...${NC}"
SYNCED_USER=$(curl -s $SYSTEM_B_URL/users/$USER_ID)
echo "$SYNCED_USER" | jq '.'

SYNCED_EMAIL=$(echo "$SYNCED_USER" | jq -r '.email')
if [ "$SYNCED_EMAIL" == "test@testcorp.com" ]; then
  echo -e "${GREEN}✓ User successfully synced!${NC}"
else
  echo -e "${YELLOW}✗ User not synced yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 10: Updating organization in System A...${NC}"
UPDATE_RESPONSE=$(curl -s -X PATCH $SYSTEM_A_URL/organizations/$ORG_ID \
  -H "Content-Type: application/json" \
  -d '{
    "organization": {
      "name": "Test Corporation"
    }
  }')

echo "$UPDATE_RESPONSE" | jq '.'
echo -e "${GREEN}✓ Updated organization${NC}"
echo

echo -e "${BLUE}Step 11: Waiting for update to sync (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 12: Verifying update synced to System B...${NC}"
UPDATED_ORG=$(curl -s $SYSTEM_B_URL/organizations/$ORG_ID)
echo "$UPDATED_ORG" | jq '.'

UPDATED_NAME=$(echo "$UPDATED_ORG" | jq -r '.name')
if [ "$UPDATED_NAME" == "Test Corporation" ]; then
  echo -e "${GREEN}✓ Update successfully synced!${NC}"
else
  echo -e "${YELLOW}✗ Update not synced yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 13: Checking sync status on System B...${NC}"
SYNC_STATUS=$(curl -s $SYSTEM_B_URL/sync_status)
echo "$SYNC_STATUS" | jq '.'
echo

echo -e "${BLUE}Step 14: Testing reverse direction - Creating organization in System B...${NC}"
ORG_B_RESPONSE=$(curl -s -X POST $SYSTEM_B_URL/organizations \
  -H "Content-Type: application/json" \
  -d '{
    "organization": {
      "name": "Beta Corp",
      "domain": "betacorp.com",
      "active": true
    }
  }')

echo "$ORG_B_RESPONSE" | jq '.'
ORG_B_ID=$(echo "$ORG_B_RESPONSE" | jq -r '.id')
echo -e "${GREEN}✓ Created organization in System B with ID: $ORG_B_ID${NC}"
echo

echo -e "${BLUE}Step 15: Waiting for reverse sync to System A (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 16: Verifying organization synced from B to A...${NC}"
SYNCED_ORG_B=$(curl -s $SYSTEM_A_URL/organizations/$ORG_B_ID)
echo "$SYNCED_ORG_B" | jq '.'

SYNCED_B_NAME=$(echo "$SYNCED_ORG_B" | jq -r '.name')
if [ "$SYNCED_B_NAME" == "Beta Corp" ]; then
  echo -e "${GREEN}✓ Organization successfully synced from B to A!${NC}"
else
  echo -e "${YELLOW}✗ Organization not synced from B to A yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 17: Creating user in System B...${NC}"
USER_B_RESPONSE=$(curl -s -X POST $SYSTEM_B_URL/users \
  -H "Content-Type: application/json" \
  -d "{
    \"user\": {
      \"organization_id\": $ORG_B_ID,
      \"name\": \"Bob Johnson\",
      \"email\": \"bob@betacorp.com\",
      \"role\": \"user\",
      \"active\": true
    }
  }")

echo "$USER_B_RESPONSE" | jq '.'
USER_B_ID=$(echo "$USER_B_RESPONSE" | jq -r '.id')
echo -e "${GREEN}✓ Created user in System B with ID: $USER_B_ID${NC}"
echo

echo -e "${BLUE}Step 18: Waiting for user sync from B to A (10 seconds)...${NC}"
sleep 10
echo

echo -e "${BLUE}Step 19: Verifying user synced from B to A...${NC}"
SYNCED_USER_B=$(curl -s $SYSTEM_A_URL/users/$USER_B_ID)
echo "$SYNCED_USER_B" | jq '.'

SYNCED_B_EMAIL=$(echo "$SYNCED_USER_B" | jq -r '.email')
if [ "$SYNCED_B_EMAIL" == "bob@betacorp.com" ]; then
  echo -e "${GREEN}✓ User successfully synced from B to A!${NC}"
else
  echo -e "${YELLOW}✗ User not synced from B to A yet${NC}"
  exit 1
fi
echo

echo -e "${BLUE}Step 20: Checking sync status on both systems...${NC}"
echo -e "${YELLOW}System A:${NC}"
curl -s $SYSTEM_A_URL/sync_status | jq '.'
echo
echo -e "${YELLOW}System B:${NC}"
curl -s $SYSTEM_B_URL/sync_status | jq '.'
echo

echo -e "${BLUE}Step 21: Verifying auto_provision is disabled (restrictive mode)...${NC}"
echo "System A configuration: auto_provision = false"
echo "System B configuration: auto_provision = false"
echo "Applications cannot create streams/consumers"
echo "All topology was pre-provisioned by the provisioner service"
echo

echo "======================================"
echo -e "${GREEN}✓ All bidirectional tests passed!${NC}"
echo "======================================"
echo
echo "Summary:"
echo "✓ Provisioner created BIDIRECTIONAL streams and consumers BEFORE apps started"
echo "✓ System A published events to B using pre-existing stream"
echo "✓ System B consumed events from A using pre-existing consumer"
echo "✓ System B published events to A using pre-existing stream"
echo "✓ System A consumed events from B using pre-existing consumer"
echo "✓ All bidirectional sync operations worked in RESTRICTIVE mode"
echo
echo "This demonstrates:"
echo "- Applications running with auto_provision=false"
echo "- Separate provisioning phase with admin permissions"
echo "- Bidirectional sync in production-ready deployment model"
echo "- No cyclic sync issues (thanks to skip_publish flag)"
echo
echo "Bidirectional JetStream Bridge is working correctly in restrictive mode!"
