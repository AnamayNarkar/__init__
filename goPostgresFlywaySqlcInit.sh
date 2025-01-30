#!/bin/bash

validate_project_name() {
    if [[ "$1" =~ ^[a-zA-Z0-9-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_db_name() {
    if [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 0
    else
        return 1
    fi
}

read -p "Enter the project name (letters, numbers, hyphens only): " INPUT_PROJECT_NAME
if ! validate_project_name "$INPUT_PROJECT_NAME"; then
    echo "Invalid name for project. Exiting."
    exit 1
fi

read -p "Enter the database name (letters, numbers, underscores only): " INPUT_DB_NAME
if ! validate_db_name "$INPUT_DB_NAME"; then
    echo "Invalid name for database. Exiting."
    exit 1
fi

PROJECT_NAME=$INPUT_PROJECT_NAME

DB_NAME=$INPUT_DB_NAME

read -p "Enter database username: " DB_USER

read -p "Enter database password: " -s DB_PASSWORD

# Create directory structure
echo "Creating necessary directories..."
mkdir -p src/{routes,controllers,service,utils,security,dto,dao} sql/{migrations,queries}

# Initialize Go module
echo "Initializing Go module..."
go mod init "$PROJECT_NAME"

# Install required tools
echo "Installing Go tools..."
export PATH=$PATH:$(go env GOPATH)/bin
go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest

# Create initial files
echo "Creating Go files..."
touch main.go sqlc.yaml .env .gitignore go.mod go.sum flyway.conf

# Create utility files
echo "Creating utility files..."
cd src/utils

# Create getPort.go
cat <<EOL > getPort.go
package utils

import (
    "os"
)

func GetPort() string {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    return port
}
EOL

# Create loadEnv.go
cat <<EOL > loadEnv.go
package utils

import (
    "github.com/joho/godotenv"
)

func LoadEnv() error {
    return godotenv.Load()
}
EOL

# Create setupCors.go
cat <<EOL > setupCors.go
package utils

import (
    "github.com/gin-contrib/cors"
    "github.com/gin-gonic/gin"
)

func SetupCORS() gin.HandlerFunc {
    corsConfig := cors.New(cors.Config{
        AllowOrigins:     []string{"http://127.0.0.1:5500"},
        AllowMethods:     []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
        AllowHeaders:     []string{"Accept", "Authorization", "Origin", "Content-Type", "X-CSRF-Token"},
        ExposeHeaders:    []string{"Link"},
        AllowCredentials: true,
        MaxAge:           300,
    })
    return corsConfig
}
EOL

# Create setUpDatabase.go
cat <<EOL > setUpDatabase.go
package utils

import (
    "database/sql"
    "fmt"
    "os"
    _ "github.com/lib/pq"
)

func SetupDatabase() (*sql.DB, error) {
    dbURL := os.Getenv("DATABASE_URL")
    if dbURL == "" {
        return nil, fmt.Errorf("DATABASE_URL is not set in the environment")
    }
    db, err := sql.Open("postgres", dbURL)
    if err != nil {
        return nil, fmt.Errorf("error opening database connection: %v", err)
    }
    if err := db.Ping(); err != nil {
        return nil, fmt.Errorf("error connecting to database: %v", err)
    }
    return db, nil
}
EOL

cd -

cd src/routes

touch allRoutes.go

cat <<EOL > allRoutes.go
package routes

import (
    "${PROJECT_NAME}/internal/database"

	"github.com/gin-gonic/gin"
)

func SetUpAllRoutes(r *gin.Engine, db* database.Queries){
	SetupUserRoutes(r,db)
}
EOL

touch userRoutes.go

cat <<EOL > userRoutes.go
package routes

import (
    "${PROJECT_NAME}/internal/database"
    "github.com/gin-gonic/gin"
)

func SetupUserRoutes(r *gin.Engine, db* database.Queries){
    func SetupUserRoutes(r *gin.Engine, db* database.Queries){
        r.GET("/users", func(c *gin.Context){
            users := []string {"user1", "user2", "user3"}
            c.JSON(200, users)
        })
    }
}
EOL


cd -

cd sql/migrations
touch V1__init.sql

cat <<EOL > V1__init.sql
CREATE TABLE users(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL UNIQUE,
    username TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
EOL

cd ../queries
touch users.sql
cat <<EOL > users.sql
-- name: CreateUser :one
    INSERT INTO users (username)
    VALUES (\$1)
    RETURNING id, username, created_at, updated_at;

-- name: GetUser :one
    SELECT id,username,created_at,updated_at
    FROM users
    WHERE username = \$1;

-- name: GetAllUsers :many
    SELECT * FROM users;
EOL

cd ../../

# Create main.go
cat <<EOL > main.go
package main

import (
    "${PROJECT_NAME}/internal/database"
    "log"
    "${PROJECT_NAME}/src/routes"
    "${PROJECT_NAME}/src/utils"
    "github.com/gin-gonic/gin"
    _ "github.com/lib/pq"
)

func main() {
    r := gin.Default()
    r.Use(utils.SetupCORS())
    
    if err := utils.LoadEnv(); err != nil {
        log.Fatalf("Error loading .env file: %v", err)
    }
    
    db, err := utils.SetupDatabase()
    if err != nil {
        log.Fatalf("Error setting up database: %v", err)
    }
    
    queries := database.New(db)
    routes.SetUpAllRoutes(r, queries)
    
    port := utils.GetPort()
    r.Run(":" + port)
}
EOL

# Write configuration to sqlc.yaml
cat <<EOL > sqlc.yaml
version: "2"
sql:
  - schema: "./sql/migrations"
    queries: "./sql/queries"
    engine: "postgresql"
    gen:
      go:
        out: "internal/database"
        emit_json_tags: true
EOL

# Write environment variables to .env
cat <<EOL > .env
PORT=3000
DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@localhost:5432/${DB_NAME}?sslmode=disable
EOL

# Write Flyway configuration
cat <<EOL > flyway.conf
flyway.url=jdbc:postgresql://localhost:5432/${DB_NAME}?sslmode=disable
flyway.user=${DB_USER}
flyway.password=${DB_PASSWORD}
flyway.locations=filesystem:sql/migrations
EOL

# Create .gitignore
cat <<EOL > .gitignore
# Binaries for programs and plugins
*.exe
*.sh
*.env
*.log
vendor/
EOL

#Create a shell script to create a dump of the postgres database
cat <<EOL > createSchemaDump.sh
#!/bin/bash
pg_dump -U postgres -h localhost -p 5432  -s -F p -v -f ${DB_NAME}_dump.sql ${DB_NAME}
EOL

touch frequentlyUsedCommands.txt
cat<<EOL > frequentlyUsedCommands.txt
    export PATH=$PATH:$(go env GOPATH)/bin
    flyway migrate
    sqlc generate   
    go build && ./${PROJECT_NAME}
EOL

echo "Running go mod tidy..."
go mod tidy
go mod vendor


echo "Setup complete! Project ${PROJECT_NAME} has been initialized."
echo "Remember to create the database '${DB_NAME}' in PostgreSQL before running the application."

rm goPostgresFlywaySqlcInit.sh