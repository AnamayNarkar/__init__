#!/bin/bash

# Jbang installation
curl -Ls https://sh.jbang.dev | bash -s - app setup

# Neo4j migration tool installation
jbang neo4j-migrations@neo4j

validate_project_name() {
    if [[ "$1" =~ ^[a-zA-Z0-9-]+$ ]]; then
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

read -p "Enter database username: " DB_USER

read -p "Enter database password: " DB_PASS

# Initialize Go module
echo "Initializing Go module..."
go mod init "$INPUT_PROJECT_NAME"

# Create directory structure
echo "Creating necessary directories..."
mkdir -p src/{routes,controllers,service,utils,security,dto,dao}

touch frequentlyUsedCommands.txt
cat<<EOL > frequentlyUsedCommands.txt
export PATH=\$PATH:$(go env GOPATH)/bin
jbang neo4j-migrations@neo4j migrate
jbang neo4j-migrations@neo4j rollback
jbang neo4j-migrations@neo4j validate
go build && ./${INPUT_PROJECT_NAME}
EOL

# Create initial files
echo "Creating Go files..."
touch main.go .env .gitignore go.mod go.sum migrations.properties

cat<<EOL >.env
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=$DB_USER
NEO4J_PASSWORD=$DB_PASS
PORT=3000
EOL

cat<<EOL >migrations.properties
# Migration properties
autocrlf=false
transaction-mode=PER_MIGRATION
password=$DB_PASS
address=bolt://localhost:7687
validate-on-migrate=true
username=$DB_USER
EOL

cat<<EOL >.gitignore
.env
.idea
.DS_Store   
.vscode
.migrations.properties
EOL

mkdir -p neo4j/migrations

cd neo4j/migrations

touch V001__creating_movie_node.cypher

cat<<EOL >V001__creating_movie_node.cypher
CREATE CONSTRAINT unique_movie_id IF NOT EXISTS
FOR (m:Movie) REQUIRE m.movie_id IS UNIQUE;

CREATE CONSTRAINT unique_movie_title IF NOT EXISTS
FOR (m:Movie) REQUIRE m.title IS UNIQUE;
EOL

cd -

cd src/utils

touch getPort.go loadEnv.go setupCors.go setupDatabase.go

cat<<EOL >getPort.go
package utils

import (
    "os"
)

func GetPort() string {
    port := os.Getenv("PORT")
    if port == "" {
        port = "3000"
    }
    return port
}
EOL

cat<<EOL >loadEnv.go
package utils

import (
    "github.com/joho/godotenv"
)

func LoadEnv() error {
    return godotenv.Load()
}
EOL

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

cat<<EOL >setupDatabase.go
package utils

import (
	"context"

	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

func SetupDatabase(ctx context.Context, uri, user, password string) (neo4j.DriverWithContext, error) {
    driver,err:= neo4j.NewDriverWithContext(uri, neo4j.BasicAuth(user, password, ""))
    if err != nil {
        return nil, err
    }

    err = driver.VerifyConnectivity(ctx)

    if err != nil {
        return nil, err
    }

    return driver, nil
}
EOL

cd -

cd src/routes

touch allRoutes.go userRoutes.go

cat<<EOL >allRoutes.go
package routes

import (
	"github.com/gin-gonic/gin"
	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

func SetUpAllRoutes(r *gin.Engine, db* neo4j.DriverWithContext){
	SetupUserRoutes(r, db)
}
EOL

cat<<EOL >userRoutes.go
package routes

import (
	"$INPUT_PROJECT_NAME/src/controllers"

	"github.com/gin-gonic/gin"
	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

func SetupUserRoutes(r *gin.Engine, db* neo4j.DriverWithContext) {
	
	UserController := controllers.UserController{Driver: db}

	userGroup := r.Group("/api/user")

	userGroup.POST("/create", UserController.CreateUser)

}
EOL

cd -

cd src/controllers

touch userController.go

cat<<EOL >userController.go
package controllers

import (
	"github.com/gin-gonic/gin"
	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

type UserController struct {
	Driver* neo4j.DriverWithContext
}


func (uc *UserController) CreateUser(c *gin.Context) {

	people := []map[string]any{
		{"name": "Alice", "age": 33},
		{"name": "Bob", "age": 44},
		{"name": "Eve", "age": 55},
	}

	ctx := c.Request.Context()

	for _, person := range people {
        _, err := neo4j.ExecuteQuery(ctx, *uc.Driver,
            "MERGE (p:Person {name: $person.name, age: $person.age})",
            map[string]any{
                "person": person,
            }, neo4j.EagerResultTransformer,
            neo4j.ExecuteQueryWithDatabase("neo4j"))
        if err != nil {
            c.JSON(500, gin.H{
                "error": err.Error(),
            })
        }
    }	

    c.JSON(200, gin.H{
        "message": "Success",
    })

}
EOL

cd -

cat<<EOL >main.go
package main

import (
	"context"
	"$INPUT_PROJECT_NAME/src/utils"
	"log"
	"os"

	"$INPUT_PROJECT_NAME/src/routes"

	"github.com/gin-gonic/gin"
)

func main() {
    r := gin.Default()
    r.Use(utils.SetupCORS())

    log.SetOutput(gin.DefaultWriter)

    if err := utils.LoadEnv(); err != nil {
        log.Fatalf("Error loading .env file: %v", err)
    }
    
	dbUri := os.Getenv("NEO4J_URI")
    dbUser := os.Getenv("NEO4J_USER")
    dbPassword := os.Getenv("NEO4J_PASSWORD")

	ctx := context.Background()

    driver, err := utils.SetupDatabase(ctx, dbUri, dbUser, dbPassword)
    if err != nil {
        log.Fatalf("Error setting up database: %v", err)
    }

    defer driver.Close(ctx)
    
    routes.SetUpAllRoutes(r, &driver)
    
    port := utils.GetPort()
    r.Run(port)
}
EOL

echo "Running go mod tidy..."
go mod tidy
go mod vendor

rm goNeo4jAndMigrations.sh

go build && ./$INPUT_PROJECT_NAME