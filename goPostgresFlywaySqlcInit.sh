#!/bin/bash

validate_project_name() {
    echo "Validating project name: $1"
    if [[ "$1" =~ ^[-a-zA-Z0-9_./:]+$ ]]; then
        echo "Project name is valid"
        return 0
    else
        echo "Project name contains invalid characters"
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

read -p "Enter the project name (letters, numbers, hyphens, dots, slashes, underscores allowed): " INPUT_PROJECT_NAME
if ! validate_project_name "$INPUT_PROJECT_NAME"; then
    echo "Invalid project name. Only letters, numbers, hyphens (-), dots (.), slashes (/), and underscores (_) are allowed."
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
mkdir -p src/{routes,controllers,service,utils,security,dto,dao,middleware,entity} sql/{migrations,queries}

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

cat <<EOL > setupRedis.go
package utils

import (
	"context"
	"log"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
)

func SetupRedis() *redis.Client {
	client := redis.NewClient(&redis.Options{
		Addr:     os.Getenv("REDIS_URL"), // Use default Addr
		Password: os.Getenv("REDIS_PASS"), // No password
		DB:       0,                // Default DB
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := client.Ping(ctx).Result()
	if err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}

	log.Println("Connected to Redis!")
	return client
}

EOL

cd -

cd src/routes

touch allRoutes.go

cat <<EOL > allRoutes.go
package routes

import (
	"test/sqlc"
	"test/src/controllers"
	"test/src/middleware"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

type AllRoutes struct {
	ginEngine   *gin.Engine
	db          *sqlc.Queries
	redisClient *redis.Client
}

func NewAllRoutes(r *gin.Engine, db *sqlc.Queries, redisClient *redis.Client) *AllRoutes {
	return &AllRoutes{
		ginEngine:   r,
		db:          db,
		redisClient: redisClient,
	}
}

func (ar *AllRoutes) SetUpAllRoutes() {
	userController := controllers.NewUserController(ar.db, ar.redisClient)

	userGroup := ar.ginEngine.Group("/user")
	userGroup.Use(middleware.GetSession(ar.redisClient))
	userGroup.GET("/getAll", userController.GetAllUsers) 

	authController := controllers.NewAuthController(ar.db, ar.redisClient)

	authGroup := ar.ginEngine.Group("/auth")
	authGroup.POST("/login", authController.Login)
	authGroup.POST("/register", authController.Register)
	authGroup.POST("/logout", authController.Logout)
}


EOL

cd -

cd src/controllers

cat <<EOL > userController.go
package controllers

import (
	"test/sqlc"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

type UserController struct {
	DB          *sqlc.Queries
	RedisClient *redis.Client
}

func NewUserController(db *sqlc.Queries, redisClient *redis.Client) *UserController {
	return &UserController{
		DB:          db,
		RedisClient: redisClient,
	}
}

// Renamed function to use PascalCase
func (uc *UserController) GetAllUsers(c *gin.Context) {
	// Get users from database
}

EOL

cat <<EOL > authController.go

package controllers

import (
	"test/sqlc"
	"test/src/entity"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

type AuthController struct {
	DB          *sqlc.Queries
	RedisClient *redis.Client
}

func NewAuthController(db *sqlc.Queries, redisClient *redis.Client) *AuthController {
	return &AuthController{
		DB:          db,
		RedisClient: redisClient,
	}
}

// Utility function to create a session
func (ac *AuthController) CreateSession() *entity.SessionValueEntity {
	// Create session logic
	return &entity.SessionValueEntity{}
}

// User authentication functions
func (ac *AuthController) Login(c *gin.Context) {
	// Login logic
}

func (ac *AuthController) Register(c *gin.Context) {
	// User registration logic
}

func (ac *AuthController) Logout(c *gin.Context) {
	// Delete session logic
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

cd src/entity

cat <<EOL > sessionEntity.go
package entity

type SessionValueEntity struct {
	SessionId string
	UserId    int
}

EOL

cd -

cd src/middleware

cat<<EOL > checkUserSession.go
package middleware

import (
	"context"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

func GetSession(redisClient *redis.Client) gin.HandlerFunc{
    return func(c *gin.Context) {
        session := c.Query("session")
        if session == "" {
            c.JSON(400, gin.H{"error": "Session is required"})
            c.Abort()
            return
        }
        
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()

        value, err := redisClient.Get(ctx, session).Result()
        if err != nil {
            c.JSON(400, gin.H{"error": "Invalid session"})
            c.Abort()
            return
        }

        c.Set("session", value)
        c.Next()
    }
}

EOL

cd -

# Create main.go
cat <<EOL > main.go
package main

import (
	"log"
	"test/sqlc"
	"test/src/routes"
	"test/src/utils"

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

    defer db.Close()

    redisClient := utils.SetupRedis()
    
    queries := sqlc.New(db)
    AllRoutes := routes.NewAllRoutes(r,queries, redisClient)
    AllRoutes.SetUpAllRoutes()
    
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
        out: "sqlc"
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
pg_dump -U postgres -h localhost -p 5432 -s -F p -v -f ${DB_NAME}_dump.sql ${DB_NAME}
EOL

chmod +x createSchemaDump.sh

touch frequentlyUsedCommands.txt
cat<<EOL > frequentlyUsedCommands.txt
flyway migrate
go build && ./${PROJECT_NAME}
export PATH=\$PATH:\$(go env GOPATH)/bin
sqlc generate   
go mod tidy && go mod vendor
EOL

echo "Running go mod tidy..."
go mod tidy
go mod vendor


echo "Setup complete! Project ${PROJECT_NAME} has been initialized."
echo "Remember to create the database '${DB_NAME}' in PostgreSQL before running the application."

rm goPostgresFlywaySqlcInit.sh