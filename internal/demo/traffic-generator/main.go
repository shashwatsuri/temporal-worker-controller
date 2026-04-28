package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/workflow"
	"go.temporal.io/sdk/activity"
)

// Workflow function (stub for traffic generation)
func GeneratedWorkflow(ctx workflow.Context) error {
	ao := workflow.ActivityOptions{
		StartToCloseTimeout: time.Minute,
	}
	ctx = workflow.WithActivityOptions(ctx, ao)

	var result string
	err := workflow.ExecuteActivity(ctx, GeneratedActivity, "traffic-generated").Get(ctx, &result)
	if err != nil {
		return err
	}
	return nil
}

// Activity function (stub)
func GeneratedActivity(ctx context.Context, name string) (string, error) {
	return fmt.Sprintf("Generated workflow executed for %s at %s", name, time.Now().Format(time.RFC3339)), nil
}

func main() {
	// Configuration from environment
	temporalAddress := os.Getenv("TEMPORAL_ADDRESS")
	if temporalAddress == "" {
		temporalAddress = "temporal:7233"
	}

	namespace := os.Getenv("TEMPORAL_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}

	taskQueue := os.Getenv("TASK_QUEUE")
	if taskQueue == "" {
		taskQueue = "default/helloworld"
	}

	workflowsPerRun := 3
	if v := os.Getenv("WORKFLOWS_PER_RUN"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			workflowsPerRun = parsed
		}
	}

	ctx := context.Background()

	// Connect to Temporal server
	c, err := client.Dial(client.Options{
		HostPort: temporalAddress,
	})
	if err != nil {
		log.Fatalf("Failed to connect to Temporal server at %s: %v", temporalAddress, err)
	}
	defer c.Close()

	// Create client for starting workflows
	log.Printf("Connected to Temporal at %s, starting %d workflows to %s", temporalAddress, workflowsPerRun, taskQueue)

	timestamp := time.Now().Unix()
	hostname, _ := os.Hostname()

	for i := 1; i <= workflowsPerRun; i++ {
		workflowID := fmt.Sprintf("traffic-%d-%s-%d", timestamp, hostname, i)

		workflowOptions := client.StartWorkflowOptions{
			ID:        workflowID,
			TaskQueue: taskQueue,
		}

		execution, err := c.ExecuteWorkflow(ctx, workflowOptions, "Helloworld", map[string]interface{}{"name": "traffic-generated"})
		if err != nil {
			log.Printf("Failed to start workflow %s: %v (may retry on next run)", workflowID, err)
			continue
		}

		log.Printf("Started workflow %d/%d: %s (RunID: %s)", i, workflowsPerRun, execution.GetID(), execution.GetRunID())
	}

	log.Printf("Traffic generation complete: queued %d workflows", workflowsPerRun)
}
