package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/temporalio/temporal-worker-controller/internal/demo/util"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/workflow"
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
	namespace := os.Getenv("TEMPORAL_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}

	taskQueue := os.Getenv("TEMPORAL_TASK_QUEUE")
	if taskQueue == "" {
		taskQueue = os.Getenv("TASK_QUEUE")
	}
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

	// Use the shared demo client bootstrap. It supports Temporal Cloud auth via env
	// (API key / mTLS) and keeps connection behavior consistent with other demo workers.
	c, stopFunc := util.NewClient("traffic-generator", taskQueue, namespace, 9091)
	defer stopFunc()

	// Create client for starting workflows
	log.Printf("Connected to Temporal namespace %s, starting %d workflows to %s", namespace, workflowsPerRun, taskQueue)

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
