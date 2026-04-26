package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/temporalio/temporal-worker-controller/internal/demo/release"
	"github.com/temporalio/temporal-worker-controller/internal/demo/util"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	cfg := loadConfig()

	go serveHealthz()

	client, stopClient := util.NewClient("rainbow-release-manager", cfg.ScheduleID, cfg.TemporalNamespace, 9091)
	defer stopClient()

	if err := release.EnsureSchedule(context.Background(), client, cfg); err != nil {
		log.Fatal(err)
	}

	clientset, err := newKubernetesClient()
	if err != nil {
		log.Fatal(err)
	}

	w := worker.New(client, cfg.TaskQueue, worker.Options{})
	w.RegisterWorkflowWithOptions(release.ReleaseWorkflow, workflow.RegisterOptions{Name: release.WorkflowName})
	w.RegisterActivityWithOptions(release.NewActivities(clientset).RunReleaseJob, activity.RegisterOptions{Name: release.ActivityName})

	if err := w.Run(worker.InterruptCh()); err != nil {
		log.Fatal(err)
	}
}

func loadConfig() release.Config {
	return release.Config{
		TemporalNamespace: mustGetEnv("TEMPORAL_NAMESPACE"),
		ScheduleID:        getEnv("RELEASE_SCHEDULE_ID", "rainbow-release-schedule"),
		ScheduleCron:      getEnv("RELEASE_SCHEDULE_CRON", "*/2 * * * *"),
		SchedulePaused:    getEnvBool("RELEASE_SCHEDULE_PAUSED", false),
		TaskQueue:         getEnv("TEMPORAL_TASK_QUEUE", "default/rainbow-release"),
		WorkflowID:        getEnv("RELEASE_WORKFLOW_ID", "rainbow-release-run"),
		CatchupWindow:     getEnvDuration("RELEASE_SCHEDULE_CATCHUP_WINDOW", time.Minute),
		PauseOnFailure:    getEnvBool("RELEASE_SCHEDULE_PAUSE_ON_FAILURE", true),
		WorkflowTimeout:   getEnvDuration("RELEASE_WORKFLOW_TIMEOUT", 45*time.Minute),
		Namespace:         getEnv("RELEASE_NAMESPACE", "default"),
		ReleaseName:       getEnv("RELEASE_NAME", "helloworld"),
		RepoURL:           getEnv("RELEASE_REPO_URL", "https://github.com/temporalio/temporal-worker-controller"),
		RepoRef:           getEnv("RELEASE_REPO_REF", "main"),
		Worker:            getEnv("RELEASE_WORKER", "helloworld"),
		JobImage:          mustGetEnv("RELEASE_JOB_IMAGE"),
		JobPullPolicy:     parsePullPolicy(getEnv("RELEASE_JOB_PULL_POLICY", string("IfNotPresent"))),
		JobServiceAccount: getEnv("RELEASE_JOB_SERVICE_ACCOUNT", "rainbow-version-generator"),
		StateConfigMap:    getEnv("RELEASE_STATE_CONFIGMAP", "rainbow-version-state"),
		AWSRegion:         getEnv("RELEASE_AWS_REGION", "us-east-2"),
		JobTTLSeconds:     int32(getEnvInt("RELEASE_JOB_TTL_SECONDS", 300)),
		JobTimeout:        getEnvDuration("RELEASE_JOB_TIMEOUT", 40*time.Minute),
	}
}

func newKubernetesClient() (*kubernetes.Clientset, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		kubeconfig := os.Getenv("KUBECONFIG")
		if kubeconfig == "" {
			return nil, err
		}
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, err
		}
	}

	return kubernetes.NewForConfig(config)
}

func serveHealthz() {
	if err := http.ListenAndServe("0.0.0.0:8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})); err != nil {
		log.Fatal(err)
	}
}

func mustGetEnv(key string) string {
	value := os.Getenv(key)
	if value == "" {
		log.Fatal(fmt.Sprintf("environment variable %s must be set", key))
	}
	return value
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func getEnvBool(key string, fallback bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		log.Fatal(err)
	}
	return parsed
}

func getEnvInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		log.Fatal(err)
	}
	return parsed
}

func getEnvDuration(key string, fallback time.Duration) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		log.Fatal(err)
	}
	return parsed
}

func parsePullPolicy(value string) corev1.PullPolicy {
	switch value {
	case string(corev1.PullAlways):
		return corev1.PullAlways
	case string(corev1.PullNever):
		return corev1.PullNever
	default:
		return corev1.PullIfNotPresent
	}
}
