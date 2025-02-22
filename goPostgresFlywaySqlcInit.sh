#!/bin/bash

validate_project_name() {
    if [[ "$1" =~ ^[-a-zA-Z0-9_./:]+$ ]]; then
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

cd src/dto

cat <<EOL > usernameAndPasswordDto.go
package dto

type UsernameAndPasswordDto struct {
	Username string `json:"username"`
	Password string `json:"password"`
}
EOL

cd -

cd src/routes

touch allRoutes.go

cat <<EOL > allRoutes.go
package routes

import (
    "$PROJECT_NAME/sqlc"
    "$PROJECT_NAME/src/controllers"
    "$PROJECT_NAME/src/middleware"

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

	userGroup := ar.ginEngine.Group("/api/user")
	userGroup.Use(middleware.GetSession(ar.redisClient))
	userGroup.GET("/getAll", userController.GetAllUsers) 

	authController := controllers.NewAuthController(ar.db, ar.redisClient)

	authGroup := ar.ginEngine.Group("/api/auth")
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
	"$PROJECT_NAME/sqlc"

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

func (uc *UserController) GetAllUsers(c *gin.Context) {
	users, err := uc.DB.GetAllUsers(c)
	if err != nil {
		c.JSON(500, gin.H{"error": "internal server error"})
		return
	}

	c.JSON(200, gin.H{"users": users})
}
EOL

cat <<EOL > authController.go

package controllers

import (
    "database/sql"
	"encoding/json"
	"log"
	"net/http"
	"time"

    "$PROJECT_NAME/sqlc"
    "$PROJECT_NAME/src/dto"
    "$PROJECT_NAME/src/entity"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
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

func (ac *AuthController) CreateSession(
    userID uuid.UUID,
    username string,
    c *gin.Context,
) {
    newSessionValueEntity := entity.SessionValueEntity{
        SessionId: uuid.New().String(),
        UserId:    userID.String(),
        Username:  username,
    }

    // Set cookie
    cookie := &http.Cookie{
        Name:     "session_id",
        Value:    newSessionValueEntity.SessionId,
        Expires:  time.Now().Add(24 * time.Hour),
        HttpOnly: true,
        Path:    "/", // This is important because the cookie will be available in all routes
    }

    http.SetCookie(c.Writer, cookie)

    // Set Redis
    sessionValue, err := json.Marshal(newSessionValueEntity)
    if err != nil {
        c.JSON(500, gin.H{"error": "internal server error"})
        return
    }

    err = ac.RedisClient.Set(c, newSessionValueEntity.SessionId, sessionValue, 24*time.Hour).Err()
    if err != nil {
        c.JSON(500, gin.H{"error": "internal server error"})
        return
    }

    log.Println("Session created")
}

func (ac *AuthController) Login(c *gin.Context) {
    requestBody := dto.UsernameAndPasswordDto{}
    err := json.NewDecoder(c.Request.Body).Decode(&requestBody)
    if err != nil {
        c.JSON(400, gin.H{"error": "invalid request body"})
        return
    }

    user, err := ac.DB.GetUser(c, requestBody.Username)
    if err!=nil {
        if err == sql.ErrNoRows {
            c.JSON(401, gin.H{"error": "invalid credentials"})
            return
        } else {
            c.JSON(500, gin.H{"error": "internal server error"})
            return
        }
    }

    if user.Password != requestBody.Password {
        c.JSON(401, gin.H{"error": "invalid credentials"})
        return
    }

    ac.CreateSession(user.ID, user.Username, c)

    c.JSON(200, gin.H{"message": "login successful"})
}

func (ac *AuthController) Register(c *gin.Context) {
    requestBody := dto.UsernameAndPasswordDto{}
    err := json.NewDecoder(c.Request.Body).Decode(&requestBody)
    if err != nil {
        c.JSON(400, gin.H{"error": "invalid request body"})
        return
    }

    newUser := sqlc.CreateUserParams{
        ID:        uuid.New(),
        Username:  requestBody.Username,
        Password:  requestBody.Password,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }

    _, err2 := ac.DB.CreateUser(c, newUser)
    if err2 != nil {
        c.JSON(500, gin.H{"error": "internal server error"})
        return
    }

    c.JSON(201, gin.H{"message": "user registered successfully"})
}

func (ac *AuthController) Logout(c *gin.Context) {
    cookie, err := c.Request.Cookie("session_id")
    if err != nil {
        c.JSON(400, gin.H{"error": "no session found"})
        return
    }

    err = ac.RedisClient.Del(c, cookie.Value).Err()
    if err != nil {
        c.JSON(500, gin.H{"error": "internal server error"})
        return
    }

    cookie.Expires = time.Now().Add(-1 * time.Hour)
    http.SetCookie(c.Writer, cookie)

    c.JSON(200, gin.H{"message": "logout successful"})
}
EOL

cd -

cd sql/migrations
touch V1__init.sql

cat <<EOL > V1__init.sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL UNIQUE,
    username TEXT NOT NULL UNIQUE,
    password TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
EOL

cd ../queries
touch users.sql
cat <<EOL > users.sql
-- name: CreateUser :one
    INSERT INTO users (id, username, password, created_at, updated_at)
    VALUES (\$1, \$2, \$3, \$4, \$5)
    RETURNING id, username, created_at, updated_at;

-- name: GetUser :one
    SELECT id,username, password, created_at, updated_at
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
	Username string
	UserId    string
}
EOL

cd -

cd src/middleware

cat<<EOL > checkUserSession.go
package middleware

import (
	"context"
	"fmt"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

func GetSession(redisClient *redis.Client) gin.HandlerFunc{
    return func(c *gin.Context) {
        session ,err:= c.Cookie("session_id")
        if err != nil {
            c.JSON(400, gin.H{"error": "Session is required from middleware"})
            c.Abort()
            return
        }
        
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()

        value, err := redisClient.Get(ctx, session).Result()
        fmt.Println(value)
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

    "$PROJECT_NAME/sqlc"
    "$PROJECT_NAME/src/routes"
    "$PROJECT_NAME/src/utils"

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
REDIS_URL=localhost:6379
REDIS_PASS=
EOL

# Write Flyway configuration
cat <<EOL > flyway.conf
flyway.url=jdbc:postgresql://localhost:5432/${DB_NAME}?sslmode=disable
flyway.user=${FLYWAY_USER}
flyway.password=${FLYWAY_PASSWORD}
flyway.locations=filesystem:sql/migrations
flyway.cleanDisabled=false
EOL

# Create .gitignore
cat <<EOL > .gitignore
# Binaries for programs and plugins
shellEnvSetupCommands.sh
*.exe
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
sqlc generate
go mod tidy && go mod vendor

cat<<EOL > shellEnvSetupCommands.sh
export PATH=\$PATH:\$(go env GOPATH)/bin
export PATH=\$PATH:"/c/PROGRA~1/Red Gate/Flyway Desktop/flyway"
export FLYWAY_USER=<DB_USER>
export FLYWAY_PASSWORD=<DB_PASSWORD>

cat<<EOL >.env
PORT=3000
DATABASE_URL=postgres://<DB_USER>:<DB
REDIS_URL=localhost:6379
REDIS_PASS=
EOL

cat<<EOL > shellEnvSetupCommands.sh
export PATH=\$PATH:\$(go env GOPATH)/bin
export PATH=\$PATH:"/c/PROGRA~1/Red Gate/Flyway Desktop/flyway"
export FLYWAY_USER="$DB_USER"
export FLYWAY_PASSWORD="$DB_PASSWORD"
EOL

echo "Running go mod tidy..."
go mod tidy
go mod vendor


echo "Setup complete! Project ${PROJECT_NAME} has been initialized."
echo "Remember to create the database '${DB_NAME}' in PostgreSQL before running the application."

rm goPostgresFlywaySqlcInit.sh