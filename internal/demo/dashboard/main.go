package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed static/*
var staticFiles embed.FS

type twdResource struct {
	Metadata struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"metadata"`
	Status struct {
		TargetVersion     versionRef      `json:"targetVersion"`
		CurrentVersion    *versionRef     `json:"currentVersion,omitempty"`
		DeprecatedVersion []versionRef    `json:"deprecatedVersions,omitempty"`
		Conditions        []condition     `json:"conditions,omitempty"`
		VersionCount      int             `json:"versionCount,omitempty"`
	} `json:"status"`
}

type versionRef struct {
	BuildID        string         `json:"buildID"`
	Status         string         `json:"status"`
	RampPercentage *float64       `json:"rampPercentage,omitempty"`
	Deployment     *objectRef     `json:"deployment,omitempty"`
	RampingSince   *time.Time     `json:"rampingSince,omitempty"`
	DrainedSince   *time.Time     `json:"drainedSince,omitempty"`
}

type objectRef struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
}

type condition struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	Reason             string `json:"reason"`
	Message            string `json:"message"`
	LastTransitionTime string `json:"lastTransitionTime"`
}

type deploymentResource struct {
	Metadata struct {
		Name      string            `json:"name"`
		Namespace string            `json:"namespace"`
		Labels    map[string]string `json:"labels,omitempty"`
	} `json:"metadata"`
	Status struct {
		Replicas          int `json:"replicas"`
		ReadyReplicas     int `json:"readyReplicas"`
		AvailableReplicas int `json:"availableReplicas"`
	} `json:"status"`
}

type deploymentListResource struct {
	Items []deploymentResource `json:"items"`
}

type versionCard struct {
	BuildID         string   `json:"buildId"`
	Role            string   `json:"role"`
	Status          string   `json:"status"`
	RampPct         *float64 `json:"-"`
	// TrafficPct is the share of *new* workflow starts routed here (0-100).
	// nil means "not applicable" (draining versions don't receive new starts).
	TrafficPct      *float64 `json:"trafficPct,omitempty"`
	// Draining is true for deprecated versions that are still serving pinned workflows.
	Draining        bool     `json:"draining"`
	Deployment      string   `json:"deployment,omitempty"`
	Replicas        int      `json:"replicas"`
	ReadyReplicas   int      `json:"readyReplicas"`
}

type apiState struct {
	Name                 string        `json:"name"`
	Namespace            string        `json:"namespace"`
	FetchedAt            time.Time     `json:"fetchedAt"`
	VersionCount         int           `json:"versionCount"`
	ActiveVersions       int           `json:"activeVersions"`
	PinnedLikely         bool          `json:"pinnedLikely"`
	SlotsUsed            *float64      `json:"slotsUsed,omitempty"`
	SlotsCapacity        *float64      `json:"slotsCapacity,omitempty"`
	SlotUtilizationPct   *float64      `json:"slotUtilizationPct,omitempty"`
	MetricsNote          string        `json:"metricsNote,omitempty"`
	Progressing          *condition    `json:"progressing,omitempty"`
	Ready                *condition    `json:"ready,omitempty"`
	TemporalConnection   *condition    `json:"temporalConnection,omitempty"`
	Versions             []versionCard `json:"versions"`
	Error                string        `json:"error,omitempty"`
}

type promQueryResponse struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Value []any `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

func main() {
	var (
		namespace = flag.String("namespace", "default", "Kubernetes namespace for the TemporalWorkerDeployment")
		name      = flag.String("name", "helloworld", "TemporalWorkerDeployment name")
		port      = flag.Int("port", 8787, "Port for the local dashboard")
	)
	flag.Parse()

	mux := http.NewServeMux()
	staticSub, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatalf("failed to mount embedded static files: %v", err)
	}
	mux.Handle("/", http.FileServer(http.FS(staticSub)))
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		state, err := collectState(ctx, *namespace, *name)
		if err != nil {
			state = apiState{
				Name:      *name,
				Namespace: *namespace,
				FetchedAt: time.Now().UTC(),
				Error:     err.Error(),
			}
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(state)
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("Rainbow dashboard available at http://localhost%s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func collectState(ctx context.Context, namespace, name string) (apiState, error) {
	var twd twdResource
	if err := kubectlJSON(ctx, &twd, "-n", namespace, "get", "temporalworkerdeployment", name, "-o", "json"); err != nil {
		return apiState{}, err
	}

	cards := make([]versionCard, 0, 4)
	cardByBuildID := make(map[string]int)
	addOrMergeCard := func(next versionCard) {
		if next.BuildID == "" {
			cards = append(cards, next)
			return
		}
		if i, ok := cardByBuildID[next.BuildID]; ok {
			if cards[i].Role != next.Role {
				cards[i].Role = cards[i].Role + "+" + next.Role
			}
			if strings.EqualFold(next.Status, "Ramping") {
				cards[i].Status = next.Status
			}
			if next.RampPct != nil {
				cards[i].RampPct = next.RampPct
			}
			if next.Deployment != "" {
				cards[i].Deployment = next.Deployment
				cards[i].Replicas = next.Replicas
				cards[i].ReadyReplicas = next.ReadyReplicas
			}
			return
		}
		cardByBuildID[next.BuildID] = len(cards)
		cards = append(cards, next)
	}
	if twd.Status.CurrentVersion != nil && twd.Status.CurrentVersion.BuildID != "" {
		addOrMergeCard(buildCard(ctx, "current", *twd.Status.CurrentVersion))
	}
	if twd.Status.TargetVersion.BuildID != "" {
		addOrMergeCard(buildCard(ctx, "target", twd.Status.TargetVersion))
	}
	for _, v := range twd.Status.DeprecatedVersion {
		addOrMergeCard(buildCard(ctx, "deprecated", v))
	}

	cards = mergeLiveDeploymentData(ctx, namespace, name, cards, cardByBuildID)

	newWorkflowPcts, drainingIDs := computeTraffic(cards)
	for i := range cards {
		if pct, ok := newWorkflowPcts[cards[i].BuildID]; ok {
			v := pct
			cards[i].TrafficPct = &v
		}
		if drainingIDs[cards[i].BuildID] {
			cards[i].Draining = true
		}
	}

	sort.Slice(cards, func(i, j int) bool {
		// Order: current first, then ramping target, then draining (by replicas desc), then inactive
		order := func(c versionCard) int {
			switch strings.ToLower(c.Status) {
			case "current":
				return 0
			case "ramping":
				return 1
			case "draining":
				return 2
			default:
				return 3
			}
		}
		oi, oj := order(cards[i]), order(cards[j])
		if oi != oj {
			return oi < oj
		}
		// Within draining, sort by replicas descending (most alive first)
		if strings.ToLower(cards[i].Status) == "draining" {
			return cards[i].ReadyReplicas > cards[j].ReadyReplicas
		}
		return cards[i].Role < cards[j].Role
	})

	activeByBuildID := make(map[string]struct{})
	pinnedLikely := false
	for _, c := range cards {
		s := strings.ToLower(c.Status)
		if s == "current" || s == "ramping" || s == "draining" || s == "inactive" {
			activeByBuildID[c.BuildID] = struct{}{}
		}
		if s == "draining" {
			pinnedLikely = true
		}
	}
	state := apiState{
		Name:           twd.Metadata.Name,
		Namespace:      twd.Metadata.Namespace,
		FetchedAt:      time.Now().UTC(),
		VersionCount:   twd.Status.VersionCount,
		ActiveVersions: len(activeByBuildID),
		PinnedLikely:   pinnedLikely,
		Versions:       cards,
	}

	taskQueue := fmt.Sprintf("%s/%s", namespace, name)
	usedExpr := fmt.Sprintf(`sum(temporal_worker_task_slots_used{task_queue=%q})`, taskQueue)
	capExpr := fmt.Sprintf(`sum(temporal_worker_task_slots_used{task_queue=%q} + temporal_worker_task_slots_available{task_queue=%q})`, taskQueue, taskQueue)

	used, usedErr := queryPrometheusScalar(ctx, usedExpr)
	cap, capErr := queryPrometheusScalar(ctx, capExpr)
	if used != nil {
		state.SlotsUsed = used
	}
	if cap != nil {
		state.SlotsCapacity = cap
	}
	if used != nil && cap != nil && *cap > 0 {
		utilPct := (*used / *cap) * 100
		state.SlotUtilizationPct = &utilPct
	}
	if usedErr != nil || capErr != nil {
		state.MetricsNote = "Prometheus metrics unavailable yet (verify monitoring stack and scrape targets)."
	}

	for _, c := range twd.Status.Conditions {
		switch c.Type {
		case "Progressing":
			cc := c
			state.Progressing = &cc
		case "Ready":
			cc := c
			state.Ready = &cc
		case "TemporalConnectionHealthy":
			cc := c
			state.TemporalConnection = &cc
		}
	}

	return state, nil
}

func mergeLiveDeploymentData(ctx context.Context, namespace, twdName string, cards []versionCard, cardByBuildID map[string]int) []versionCard {
	var list deploymentListResource
	err := kubectlJSON(
		ctx,
		&list,
		"-n", namespace,
		"get", "deployments",
		"-l", fmt.Sprintf("temporal.io/deployment-name=%s", twdName),
		"-o", "json",
	)
	if err != nil {
		return cards
	}

	for _, dep := range list.Items {
		buildID := dep.Metadata.Labels["temporal.io/build-id"]
		if buildID == "" {
			continue
		}

		depNS := dep.Metadata.Namespace
		if depNS == "" {
			depNS = namespace
		}
		depRef := fmt.Sprintf("%s/%s", depNS, dep.Metadata.Name)

		if idx, ok := cardByBuildID[buildID]; ok {
			cards[idx].Deployment = depRef
			cards[idx].Replicas = dep.Status.Replicas
			cards[idx].ReadyReplicas = dep.Status.ReadyReplicas
			continue
		}

		cardByBuildID[buildID] = len(cards)
		cards = append(cards, versionCard{
			BuildID:       buildID,
			Role:          "discovered",
			Status:        "Starting",
			Deployment:    depRef,
			Replicas:      dep.Status.Replicas,
			ReadyReplicas: dep.Status.ReadyReplicas,
		})
	}

	return cards
}

func buildCard(ctx context.Context, role string, v versionRef) versionCard {
	card := versionCard{
		BuildID: v.BuildID,
		Role:    role,
		Status:  v.Status,
		RampPct: v.RampPercentage,
	}
	if v.Deployment != nil {
		ns := v.Deployment.Namespace
		if ns == "" {
			ns = "default"
		}
		card.Deployment = fmt.Sprintf("%s/%s", ns, v.Deployment.Name)
		var dep deploymentResource
		err := kubectlJSON(ctx, &dep, "-n", ns, "get", "deployment", v.Deployment.Name, "-o", "json")
		if err == nil {
			card.Replicas = dep.Status.Replicas
			card.ReadyReplicas = dep.Status.ReadyReplicas
		}
	}
	return card
}

// computeTraffic assigns a new-workflow routing percentage to each version.
//
// Temporal's rainbow deployment model:
//  - One "target" version receives rampPercentage% of new workflow starts.
//  - One "current" version receives (100 - rampPercentage)% of new starts.
//  - "deprecated" versions receive 0% of new starts but are still alive serving
//    their pinned, in-flight workflows (Draining state).
//
// TrafficPct is set only for current/target (new-workflow routing).
// Deprecated/draining versions get Draining=true so the UI shows them correctly.
func computeTraffic(cards []versionCard) (newWorkflowPcts map[string]float64, drainingIDs map[string]bool) {
	newWorkflowPcts = map[string]float64{}
	drainingIDs = map[string]bool{}

	var (
		currentID  string
		targetID   string
		targetRamp *float64
		isRamping  bool
	)

	for _, c := range cards {
		switch strings.ToLower(c.Status) {
		case "current":
			currentID = c.BuildID
		case "ramping":
			if strings.Contains(c.Role, "target") || c.Role == "target" {
				targetID = c.BuildID
				targetRamp = c.RampPct
				isRamping = true
			}
		case "inactive":
			// Target registered but not yet ramping
			if strings.Contains(c.Role, "target") || c.Role == "target" {
				targetID = c.BuildID
				targetRamp = c.RampPct
			}
		case "draining":
			drainingIDs[c.BuildID] = true
		}
	}

	if isRamping && targetID != "" {
		ramp := 0.0
		if targetRamp != nil {
			ramp = clampPct(*targetRamp)
		}
		newWorkflowPcts[targetID] = ramp
		if currentID != "" {
			newWorkflowPcts[currentID] = clampPct(100 - ramp)
		}
		return
	}

	// Rollout complete or not yet started — current gets 100% of new starts.
	if currentID != "" {
		newWorkflowPcts[currentID] = 100
		return
	}
	// Only a target exists (e.g. initial deploy).
	if targetID != "" {
		v := 100.0
		if targetRamp != nil {
			v = clampPct(*targetRamp)
		}
		newWorkflowPcts[targetID] = v
	}
	return
}

func clampPct(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

func kubectlJSON(ctx context.Context, out any, args ...string) error {
	cmd := exec.CommandContext(ctx, "kubectl", args...)
	b, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			stderr := strings.TrimSpace(string(ee.Stderr))
			if stderr != "" {
				return fmt.Errorf("kubectl %s: %s", strings.Join(args, " "), stderr)
			}
		}
		return fmt.Errorf("kubectl %s: %w", strings.Join(args, " "), err)
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("failed to decode kubectl output: %w", err)
	}
	return nil
}

func queryPrometheusScalar(ctx context.Context, query string) (*float64, error) {
	path := "/api/v1/namespaces/monitoring/services/http:prometheus-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=" + url.QueryEscape(query)
	cmd := exec.CommandContext(ctx, "kubectl", "get", "--raw", path)
	b, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var resp promQueryResponse
	if err := json.Unmarshal(b, &resp); err != nil {
		return nil, err
	}
	if resp.Status != "success" || len(resp.Data.Result) == 0 || len(resp.Data.Result[0].Value) < 2 {
		return nil, nil
	}

	raw, ok := resp.Data.Result[0].Value[1].(string)
	if !ok {
		return nil, nil
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return nil, err
	}
	return &v, nil
}
