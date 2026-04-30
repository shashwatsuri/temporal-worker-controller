package release

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	WorkflowName = "RainbowReleaseWorkflow"
	ActivityName = "RunRainbowReleaseJob"
)

var invalidNameChars = regexp.MustCompile(`[^a-z0-9-]+`)

type Config struct {
	TemporalNamespace string
	ScheduleID        string
	ScheduleCron      string
	SchedulePaused    bool
	TaskQueue         string
	WorkflowID        string
	CatchupWindow     time.Duration
	PauseOnFailure    bool
	WorkflowTimeout   time.Duration
	Namespace         string
	ReleaseName       string
	RepoURL           string
	RepoRef           string
	Worker            string
	JobImage          string
	JobPullPolicy     corev1.PullPolicy
	JobServiceAccount string
	StateConfigMap    string
	AWSRegion         string
	WaitForTWDRollout bool
	JobTTLSeconds     int32
	JobTimeout        time.Duration
}

type Request struct {
	Namespace         string
	ReleaseName       string
	RepoURL           string
	RepoRef           string
	Worker            string
	JobImage          string
	JobPullPolicy     corev1.PullPolicy
	JobServiceAccount string
	StateConfigMap    string
	AWSRegion         string
	WaitForTWDRollout bool
	JobTTLSeconds     int32
	JobTimeout        time.Duration
}

type Activities struct {
	clientset kubernetes.Interface
}

func NewRequest(cfg Config) Request {
	return Request{
		Namespace:         cfg.Namespace,
		ReleaseName:       cfg.ReleaseName,
		RepoURL:           cfg.RepoURL,
		RepoRef:           cfg.RepoRef,
		Worker:            cfg.Worker,
		JobImage:          cfg.JobImage,
		JobPullPolicy:     cfg.JobPullPolicy,
		JobServiceAccount: cfg.JobServiceAccount,
		StateConfigMap:    cfg.StateConfigMap,
		AWSRegion:         cfg.AWSRegion,
		WaitForTWDRollout: cfg.WaitForTWDRollout,
		JobTTLSeconds:     cfg.JobTTLSeconds,
		JobTimeout:        cfg.JobTimeout,
	}
}

func NewActivities(clientset kubernetes.Interface) *Activities {
	return &Activities{clientset: clientset}
}

func EnsureSchedule(ctx context.Context, c client.Client, cfg Config) error {
	scheduleClient := c.ScheduleClient()
	handle := scheduleClient.GetHandle(ctx, cfg.ScheduleID)
	schedule := buildSchedule(cfg)

	_, err := handle.Describe(ctx)
	if err != nil {
		var notFound *serviceerror.NotFound
		if errors.As(err, &notFound) {
			_, createErr := scheduleClient.Create(ctx, client.ScheduleOptions{
				ID:                 cfg.ScheduleID,
				Spec:               *schedule.Spec,
				Action:             schedule.Action,
				Overlap:            schedule.Policy.Overlap,
				CatchupWindow:      schedule.Policy.CatchupWindow,
				PauseOnFailure:     schedule.Policy.PauseOnFailure,
				Note:               schedule.State.Note,
				Paused:             schedule.State.Paused,
				TriggerImmediately: false,
			})
			return createErr
		}
		return err
	}

	return handle.Update(ctx, client.ScheduleUpdateOptions{
		DoUpdate: func(client.ScheduleUpdateInput) (*client.ScheduleUpdate, error) {
			return &client.ScheduleUpdate{Schedule: schedule}, nil
		},
	})
}

func ReleaseWorkflow(ctx workflow.Context, req Request) (string, error) {
	ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: req.JobTimeout + 5*time.Minute,
		HeartbeatTimeout:    30 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			MaximumAttempts: 1,
		},
	})

	var jobName string
	if err := workflow.ExecuteActivity(ctx, ActivityName, req).Get(ctx, &jobName); err != nil {
		return "", err
	}

	return jobName, nil
}

func (a *Activities) RunReleaseJob(ctx context.Context, req Request) (string, error) {
	jobName := jobNameForWorkflow(activity.GetInfo(ctx).WorkflowExecution.ID)
	jobs := a.clientset.BatchV1().Jobs(req.Namespace)

	job, err := jobs.Get(ctx, jobName, metav1.GetOptions{})
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return "", err
		}

		job, err = jobs.Create(ctx, buildJob(jobName, req), metav1.CreateOptions{})
		if err != nil {
			return "", err
		}
	}

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		job, err = jobs.Get(ctx, job.Name, metav1.GetOptions{})
		if err != nil {
			return "", err
		}

		activity.RecordHeartbeat(ctx, summarizeJob(job))

		if isJobComplete(job) {
			return job.Name, nil
		}

		if isJobFailed(job) {
			return "", fmt.Errorf("release job %s failed", job.Name)
		}

		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-ticker.C:
		}
	}
}

func buildSchedule(cfg Config) *client.Schedule {
	return &client.Schedule{
		Action: &client.ScheduleWorkflowAction{
			ID:                       cfg.WorkflowID,
			Workflow:                 WorkflowName,
			Args:                     []interface{}{NewRequest(cfg)},
			TaskQueue:                cfg.TaskQueue,
			WorkflowExecutionTimeout: cfg.WorkflowTimeout,
		},
		Spec: &client.ScheduleSpec{
			CronExpressions: []string{cfg.ScheduleCron},
		},
		Policy: &client.SchedulePolicies{
			Overlap:        enumspb.SCHEDULE_OVERLAP_POLICY_SKIP,
			CatchupWindow:  cfg.CatchupWindow,
			PauseOnFailure: cfg.PauseOnFailure,
		},
		State: &client.ScheduleState{
			Paused: cfg.SchedulePaused,
			Note:   "Managed by rainbow-release-manager",
		},
	}
}

func buildJob(jobName string, req Request) *batchv1.Job {
	backoffLimit := int32(1)
	activeDeadlineSeconds := int64(req.JobTimeout.Seconds())

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      jobName,
			Namespace: req.Namespace,
			Labels: map[string]string{
				"app":                     "rainbow-release-job",
				"temporal-release":        "true",
				"temporal-release-target": req.ReleaseName,
			},
		},
		Spec: batchv1.JobSpec{
			TTLSecondsAfterFinished: &req.JobTTLSeconds,
			BackoffLimit:            &backoffLimit,
			ActiveDeadlineSeconds:   &activeDeadlineSeconds,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"app":              "rainbow-release-job",
						"temporal-release": "true",
					},
				},
				Spec: corev1.PodSpec{
					ServiceAccountName: req.JobServiceAccount,
					RestartPolicy:      corev1.RestartPolicyNever,
					Containers: []corev1.Container{{
						Name:            "orchestrator",
						Image:           req.JobImage,
						ImagePullPolicy: req.JobPullPolicy,
						Command:         []string{"/bin/sh", "-c"},
						Args:            []string{jobCommand()},
						Env: []corev1.EnvVar{
							{Name: "NAMESPACE", Value: req.Namespace},
							{Name: "RELEASE_NAME", Value: req.ReleaseName},
							{Name: "REPO_URL", Value: req.RepoURL},
							{Name: "REPO_REF", Value: req.RepoRef},
							{Name: "WORKER", Value: req.Worker},
							{Name: "CONFIG_MAP_NAME", Value: req.StateConfigMap},
							{Name: "AWS_REGION", Value: req.AWSRegion},
							{Name: "WAIT_FOR_TWD_ROLLOUT", Value: fmt.Sprintf("%t", req.WaitForTWDRollout)},
						},
						Resources: corev1.ResourceRequirements{},
					}},
				},
			},
		},
	}
}

func jobCommand() string {
	return strings.TrimSpace(`/opt/release-scripts/run_release_once.sh`)
}

func jobNameForWorkflow(workflowID string) string {
	name := strings.ToLower(workflowID)
	name = invalidNameChars.ReplaceAllString(name, "-")
	name = strings.Trim(name, "-")
	if name == "" {
		name = "rainbow-release"
	}
	if !strings.HasPrefix(name, "rainbow-release-") {
		name = "rainbow-release-" + name
	}
	if len(name) > 63 {
		name = name[:63]
	}
	return strings.TrimRight(name, "-")
}

func summarizeJob(job *batchv1.Job) string {
	if isJobComplete(job) {
		return "complete"
	}
	if isJobFailed(job) {
		return "failed"
	}
	return fmt.Sprintf("active=%d succeeded=%d failed=%d", job.Status.Active, job.Status.Succeeded, job.Status.Failed)
}

func isJobComplete(job *batchv1.Job) bool {
	for _, condition := range job.Status.Conditions {
		if condition.Type == batchv1.JobComplete && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func isJobFailed(job *batchv1.Job) bool {
	for _, condition := range job.Status.Conditions {
		if condition.Type == batchv1.JobFailed && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}
