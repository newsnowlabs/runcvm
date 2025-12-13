#!/bin/bash
# test-persistence.sh
# Phase 5: Database Persistence (MySQL)

set -e
RUNTIME=${RUNTIME:-runcvm}
HYPERVISOR=${RUNCVM_HYPERVISOR:-firecracker}
VOL_NAME="mysql-data-$$"
CONTAINER_NAME="mysql-test-$$"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Testing $RUNTIME with MySQL..."
docker volume create "$VOL_NAME"

# Start MySQL
echo "Starting MySQL container..."
docker run -d --label runcvm-test=true --name "$CONTAINER_NAME" \
  --runtime="$RUNTIME" \
  -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
  -e MYSQL_ROOT_PASSWORD=secret \
  -v "$VOL_NAME:/var/lib/mysql" \
  mysql:8.0

echo "Waiting for MySQL to accept connections..."
# Wait loop
MAX_RETRIES=60
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if docker exec "$CONTAINER_NAME" mysqladmin ping -h localhost -u root -psecret --silent >/dev/null 2>&1; then
        echo "MySQL is up!"
        break
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT+1))
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo -e "\n${RED}❌ MySQL failed to start in time${NC}"
    docker logs "$CONTAINER_NAME" || true
    exit 1
fi
echo ""

# Create data
echo "Creating test data..."
docker exec "$CONTAINER_NAME" mysql -uroot -psecret -e "
    CREATE DATABASE IF NOT EXISTS testdb;
    USE testdb;
    CREATE TABLE IF NOT EXISTS users (id INT, name VARCHAR(50));
    INSERT INTO users VALUES (1, 'Alice');
"

# Restart
echo "Restarting MySQL container..."
docker restart "$CONTAINER_NAME"
sleep 5

# Wait again
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if docker exec "$CONTAINER_NAME" mysqladmin ping -h localhost -u root -psecret --silent >/dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT+1))
done
echo ""

# Verify
echo "Verifying data persistence..."
RESULT=$(docker exec "$CONTAINER_NAME" mysql -uroot -psecret -e "SELECT name FROM testdb.users WHERE id=1" -sN)
if [ "$RESULT" = "Alice" ]; then
    echo -e "${GREEN}✅ MySQL data persisted successfully${NC}"
else
    echo -e "${RED}❌ MySQL data lost. Got: '$RESULT'${NC}"
    exit 1
fi

# -------------------------------------------------------------
# PostgreSQL Test
# -------------------------------------------------------------
VOL_NAME_PG="pg-data-$$"
CONTAINER_NAME_PG="pg-test-$$"

cleanup() {
    docker rm -f "$CONTAINER_NAME" "$CONTAINER_NAME_PG" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL_NAME" "$VOL_NAME_PG" >/dev/null 2>&1 || true
}

echo "Testing $RUNTIME with PostgreSQL..."
docker volume create "$VOL_NAME_PG"

docker run -d --label runcvm-test=true --name "$CONTAINER_NAME_PG" \
  --runtime="$RUNTIME" \
  -e RUNCVM_HYPERVISOR="$HYPERVISOR" \
  -e POSTGRES_PASSWORD=secret \
  -v "$VOL_NAME_PG:/var/lib/postgresql/data" \
  postgres:alpine

echo "Waiting for PostgreSQL..."
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if docker exec "$CONTAINER_NAME_PG" PGPASSWORD=secret psql -U postgres -c "\l" >/dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT+1))
done
echo ""

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}❌ PostgreSQL failed to start${NC}"
    docker logs "$CONTAINER_NAME_PG" || true
    exit 1
fi

docker exec "$CONTAINER_NAME_PG" PGPASSWORD=secret psql -U postgres -c "
    CREATE TABLE products (id INT, name VARCHAR(50));
    INSERT INTO products VALUES (1, 'Laptop');
" >/dev/null

echo "Restarting PostgreSQL..."
docker restart "$CONTAINER_NAME_PG"
sleep 5

# Wait for restart
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if docker exec "$CONTAINER_NAME_PG" PGPASSWORD=secret psql -U postgres -c "\l" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    COUNT=$((COUNT+1))
done

# Verify
RESULT=$(docker exec "$CONTAINER_NAME_PG" PGPASSWORD=secret psql -U postgres -tAc "SELECT COUNT(*) FROM products")
if [ "$RESULT" = "1" ]; then
    echo -e "${GREEN}✅ PostgreSQL data persisted${NC}"
else
    echo -e "${RED}❌ PostgreSQL data lost. Got: '$RESULT'${NC}"
    exit 1
fi

