package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type twdResource struct {
	Metadata struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"metadata"`
	Spec struct {
		WorkerOptions struct {
			ConnectionRef struct {
				Name string `json:"name"`
			} `json:"connectionRef"`
			TemporalNamespace string `json:"temporalNamespace"`
		} `json:"workerOptions"`
	} `json:"spec"`
	Status struct {
		TargetVersion     versionRef   `json:"targetVersion"`
		CurrentVersion    *versionRef  `json:"currentVersion,omitempty"`
		DeprecatedVersion []versionRef `json:"deprecatedVersions,omitempty"`
		Conditions        []condition  `json:"conditions,omitempty"`
		VersionCount      int          `json:"versionCount,omitempty"`
	} `json:"status"`
}

type versionRef struct {
	BuildID        string     `json:"buildID"`
	Status         string     `json:"status"`
	RampPercentage *float64   `json:"rampPercentage,omitempty"`
	Deployment     *objectRef `json:"deployment,omitempty"`
	RampingSince   *time.Time `json:"rampingSince,omitempty"`
	DrainedSince   *time.Time `json:"drainedSince,omitempty"`
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

type temporalConnectionResource struct {
	Spec struct {
		HostPort        string `json:"hostPort"`
		APIKeySecretRef *struct {
			Name string `json:"name"`
			Key  string `json:"key"`
		} `json:"apiKeySecretRef,omitempty"`
		MutualTLSSecretRef *struct {
			Name string `json:"name"`
		} `json:"mutualTLSSecretRef,omitempty"`
	} `json:"spec"`
}

type secretResource struct {
	Data map[string]string `json:"data"`
}

type temporalAccessConfig struct {
	Address        string
	Namespace      string
	APIKey         string
	UseTLS         bool
	TLSCertPath    string
	TLSKeyPath     string
	TempFiles      []string
	SupportsCounts bool
}

type versionCard struct {
	BuildID string   `json:"buildId"`
	Role    string   `json:"role"`
	Status  string   `json:"status"`
	RampPct *float64 `json:"-"`
	// TrafficPct is the share of *new* workflow starts routed here (0-100).
	// nil means "not applicable" (draining versions don't receive new starts).
	TrafficPct *float64 `json:"trafficPct,omitempty"`
	// Draining is true for deprecated versions that are still serving pinned workflows.
	Draining            bool     `json:"draining"`
	ActiveWorkflowCount int      `json:"activeWorkflowCount,omitempty"`
	ActiveWorkflowPct   *float64 `json:"activeWorkflowPct,omitempty"`
	Deployment          string   `json:"deployment,omitempty"`
	Replicas            int      `json:"replicas"`
	ReadyReplicas       int      `json:"readyReplicas"`
}

type apiState struct {
	Name                string        `json:"name"`
	Namespace           string        `json:"namespace"`
	FetchedAt           time.Time     `json:"fetchedAt"`
	VersionCount        int           `json:"versionCount"`
	ActiveVersions      int           `json:"activeVersions"`
	ActiveWorkflowTotal int           `json:"activeWorkflowTotal,omitempty"`
	PinnedLikely        bool          `json:"pinnedLikely"`
	SlotsUsed           *float64      `json:"slotsUsed,omitempty"`
	SlotsCapacity       *float64      `json:"slotsCapacity,omitempty"`
	SlotUtilizationPct  *float64      `json:"slotUtilizationPct,omitempty"`
	MetricsNote         string        `json:"metricsNote,omitempty"`
	ActiveWorkflowNote  string        `json:"activeWorkflowNote,omitempty"`
	Progressing         *condition    `json:"progressing,omitempty"`
	Ready               *condition    `json:"ready,omitempty"`
	TemporalConnection  *condition    `json:"temporalConnection,omitempty"`
	Versions            []versionCard `json:"versions"`
	Error               string        `json:"error,omitempty"`
}

type executionEntry struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

type versionStatus string

const (
	versionStatusActive   versionStatus = "active"
	versionStatusRamping  versionStatus = "ramping"
	versionStatusDraining versionStatus = "draining"
	versionStatusInactive versionStatus = "inactive"
)

type versionInfo struct {
	Status  versionStatus `json:"status"`
	Running int           `json:"running"`
	Ramping int           `json:"ramping"`
}

type executionsAPIResponse struct {
	Executions []executionEntry       `json:"executions"`
	Versions   map[string]versionInfo `json:"versions"`
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

type activeWorkflowCache struct {
	mu      sync.RWMutex
	total   int
	counts  map[string]int
	updated time.Time
}

var workflowCache activeWorkflowCache

type slotMetricsCache struct {
	mu      sync.RWMutex
	used    float64
	cap     float64
	updated time.Time
	hasData bool
}

var slotsCache slotMetricsCache

type temporalAccessConfigCache struct {
	mu      sync.RWMutex
	cfg     temporalAccessConfig
	updated time.Time
}

var configCache temporalAccessConfigCache

// stateCache caches the full /api/state response so that rapid browser polls
// (every 3s) don't each spawn a new batch of kubectl+temporal subprocesses.
type stateCacheEntry struct {
	mu       sync.Mutex
	state    *apiState
	updated  time.Time
	inflight bool
}

var stateCache stateCacheEntry

const stateCacheTTL = 5 * time.Second

func main() {
	var (
		namespace = flag.String("namespace", "default", "Kubernetes namespace for the TemporalWorkerDeployment")
		name      = flag.String("name", "helloworld", "TemporalWorkerDeployment name")
		port      = flag.Int("port", 8787, "Port for the local dashboard")
	)
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		// Serve from cache if fresh — prevents concurrent 3s browser polls from
		// each spawning kubectl+temporal subprocesses.
		stateCache.mu.Lock()
		if stateCache.state != nil && time.Since(stateCache.updated) < stateCacheTTL {
			cached := *stateCache.state
			stateCache.mu.Unlock()
			_ = json.NewEncoder(w).Encode(cached)
			return
		}
		// Only one goroutine refreshes at a time; others wait and share the result.
		if stateCache.inflight {
			var cached *apiState
			for {
				stateCache.mu.Unlock()
				time.Sleep(200 * time.Millisecond)
				stateCache.mu.Lock()
				if !stateCache.inflight {
					cached = stateCache.state
					break
				}
			}
			stateCache.mu.Unlock()
			if cached != nil {
				_ = json.NewEncoder(w).Encode(*cached)
			}
			return
		}
		stateCache.inflight = true
		stateCache.mu.Unlock()

		ctx, cancel := context.WithTimeout(r.Context(), 75*time.Second)
		defer cancel()

		var state apiState
		s, err := collectState(ctx, *namespace, *name)
		if err != nil {
			state = apiState{
				Name:      *name,
				Namespace: *namespace,
				FetchedAt: time.Now().UTC(),
				Error:     err.Error(),
			}
		} else {
			state = s
		}

		stateCache.mu.Lock()
		stateCache.state = &state
		stateCache.updated = time.Now()
		stateCache.inflight = false
		stateCache.mu.Unlock()

		_ = json.NewEncoder(w).Encode(state)
	})

	mux.HandleFunc("/api/executions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		var since time.Time
		if s := r.URL.Query().Get("since"); s != "" {
			parsed, err := time.Parse(time.RFC3339, s)
			if err != nil {
				// Try parsing as Unix milliseconds (e.g. Date.now() in JS)
				ms, msErr := strconv.ParseInt(s, 10, 64)
				if msErr != nil {
					w.WriteHeader(http.StatusBadRequest)
					_ = json.NewEncoder(w).Encode(map[string]string{"error": "invalid 'since' parameter: expected RFC3339 timestamp or Unix milliseconds"})
					return
				}
				parsed = time.UnixMilli(ms)
			}
			since = parsed
		}

		ctx, cancel := context.WithTimeout(r.Context(), 75*time.Second)
		defer cancel()

		resp, err := collectExecutions(ctx, *namespace, *name, since)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(resp)
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("Rainbow dashboard available at http://localhost%s", addr)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		mux.ServeHTTP(w, r)
	})

	if err := http.ListenAndServe(addr, handler); err != nil {
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

	newWorkflowPcts, drainingIDs, rampingTargetID := computeTraffic(cards)
	for i := range cards {
		if pct, ok := newWorkflowPcts[cards[i].BuildID]; ok {
			v := pct
			cards[i].TrafficPct = &v
		}
		if drainingIDs[cards[i].BuildID] {
			cards[i].Draining = true
		}
		// Normalize status to "Ramping" for the target during an active ramp,
		// regardless of what the controller reports (some emit "Draining" mid-ramp).
		if rampingTargetID != "" && cards[i].BuildID == rampingTargetID {
			cards[i].Status = "Ramping"
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
		if c.BuildID != "" && (s == "current" || s == "ramping" || s == "draining") {
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

	workflowTotal, perVersionCounts, workflowNote := enrichActiveWorkflowData(ctx, twd, cards)
	if workflowTotal > 0 || workflowNote != "" {
		state.ActiveWorkflowTotal = workflowTotal
		if workflowNote != "" {
			state.ActiveWorkflowNote = workflowNote
		}
	}

	// Apply per-version counts to cards.
	for i := range cards {
		if n, ok := perVersionCounts[cards[i].BuildID]; ok {
			cards[i].ActiveWorkflowCount = n
			if workflowTotal > 0 {
				pct := float64(n) / float64(workflowTotal) * 100
				cards[i].ActiveWorkflowPct = &pct
			}
		}
	}
	state.Versions = cards

	// Filter versions:
	// - Always hide deprecated versions the controller has fully drained.
	// - Hide target-only versions that aren't actively ramping and have no workflows
	//   (e.g. new deployments briefly showing as "Draining" before they register).
	// - When we have reliable workflow data, hide anything with 0 active workflows.
	{
		filtered := make([]versionCard, 0, len(cards))
		for _, c := range cards {
			if strings.EqualFold(c.Status, "Drained") {
				continue
			}
			isCurrentRole := strings.Contains(c.Role, "current")
			isTargetOnly := strings.Contains(c.Role, "target") && !isCurrentRole
			if isTargetOnly && c.BuildID != rampingTargetID && c.ActiveWorkflowCount <= 0 {
				continue
			}
			if workflowTotal > 0 && c.ActiveWorkflowCount <= 0 {
				continue
			}
			filtered = append(filtered, c)
		}
		cards = filtered
		state.Versions = cards
	}

	taskQueue := fmt.Sprintf("%s/%s", namespace, name)
	usedExpr := fmt.Sprintf(`sum(temporal_worker_task_slots_used{task_queue=%q})`, taskQueue)
	capExpr := fmt.Sprintf(`sum(temporal_worker_task_slots_used{task_queue=%q} + temporal_worker_task_slots_available{task_queue=%q})`, taskQueue, taskQueue)

	usedCtx, cancelUsed := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	used, usedErr := queryPrometheusScalar(usedCtx, usedExpr)
	cancelUsed()

	capCtx, cancelCap := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	cap, capErr := queryPrometheusScalar(capCtx, capExpr)
	cancelCap()
	if usedErr == nil && capErr == nil && used != nil && cap != nil {
		writeCachedSlotMetrics(*used, *cap)
	}
	if used != nil {
		state.SlotsUsed = used
	}
	if cap != nil {
		state.SlotsCapacity = cap
	}
	if usedErr != nil || capErr != nil {
		if cachedUsed, cachedCap, ok := readCachedSlotMetrics(); ok {
			if state.SlotsUsed == nil {
				state.SlotsUsed = cachedUsed
			}
			if state.SlotsCapacity == nil {
				state.SlotsCapacity = cachedCap
			}
			state.MetricsNote = "Using recent cached Prometheus metrics while live query retries."
		} else {
			state.MetricsNote = "Prometheus metrics temporarily unavailable."
		}
	}
	if state.SlotsUsed != nil && state.SlotsCapacity != nil {
		utilPct := 0.0
		if *state.SlotsCapacity > 0 {
			utilPct = (*state.SlotsUsed / *state.SlotsCapacity) * 100
		}
		state.SlotUtilizationPct = &utilPct
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

func collectExecutions(ctx context.Context, namespace, name string, since time.Time) (executionsAPIResponse, error) {
	var twd twdResource
	if err := kubectlJSON(ctx, &twd, "-n", namespace, "get", "temporalworkerdeployment", name, "-o", "json"); err != nil {
		return executionsAPIResponse{}, err
	}

	cfg, err := loadTemporalAccessConfig(ctx, twd)
	if err != nil {
		return executionsAPIResponse{}, fmt.Errorf("failed to load temporal access config: %w", err)
	}
	defer cleanupTempFiles(cfg.TempFiles)

	deploymentKey := fmt.Sprintf("%s/%s", namespace, name)
	query := fmt.Sprintf(`ExecutionStatus="Running" AND TemporalWorkerDeployment=%q`, deploymentKey)
	if !since.IsZero() {
		query += fmt.Sprintf(` AND StartTime > '%s'`, since.UTC().Format(time.RFC3339))
	}

	executions, err := temporalWorkflowList(ctx, cfg, query, deploymentKey)
	if err != nil {
		return executionsAPIResponse{}, fmt.Errorf("failed to list workflows: %w", err)
	}

	// Build version info from TWD status
	versions := make(map[string]versionInfo)

	// Count running workflows per version
	runningByVersion := make(map[string]int)
	for _, e := range executions {
		if e.Version != "" {
			runningByVersion[e.Version]++
		}
	}

	if twd.Status.CurrentVersion != nil && twd.Status.CurrentVersion.BuildID != "" {
		bid := twd.Status.CurrentVersion.BuildID
		ramp := 100
		if twd.Status.TargetVersion.BuildID != "" && twd.Status.TargetVersion.RampPercentage != nil {
			ramp = 100 - int(*twd.Status.TargetVersion.RampPercentage)
		}
		versions[bid] = versionInfo{
			Status:  versionStatusActive,
			Running: runningByVersion[bid],
			Ramping: ramp,
		}
	}

	if twd.Status.TargetVersion.BuildID != "" {
		bid := twd.Status.TargetVersion.BuildID
		ramp := 0
		status := versionStatusInactive
		switch strings.ToLower(twd.Status.TargetVersion.Status) {
		case "ramping":
			status = versionStatusRamping
			if twd.Status.TargetVersion.RampPercentage != nil {
				ramp = int(*twd.Status.TargetVersion.RampPercentage)
			}
		case "current":
			status = versionStatusActive
			ramp = 100
		}
		// Don't overwrite if already added as current
		if _, exists := versions[bid]; !exists {
			versions[bid] = versionInfo{
				Status:  status,
				Running: runningByVersion[bid],
				Ramping: ramp,
			}
		}
	}

	for _, v := range twd.Status.DeprecatedVersion {
		if v.BuildID == "" {
			continue
		}
		// Only include deprecated versions that have active workflows.
		if runningByVersion[v.BuildID] <= 0 {
			continue
		}
		versions[v.BuildID] = versionInfo{
			Status:  versionStatusDraining,
			Running: runningByVersion[v.BuildID],
			Ramping: 0,
		}
	}

	return executionsAPIResponse{
		Executions: executions,
		Versions:   versions,
	}, nil
}

type workflowListEntry struct {
	Execution struct {
		WorkflowID string `json:"workflowId"`
	} `json:"execution"`
	SearchAttributes struct {
		IndexedFields map[string]struct {
			Data string `json:"data"` // base64-encoded JSON value
		} `json:"indexedFields"`
	} `json:"searchAttributes"`
}

func temporalWorkflowList(ctx context.Context, cfg temporalAccessConfig, query, deploymentKey string) ([]executionEntry, error) {
	tempCtx, tempCancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer tempCancel()

	args := []string{
		"workflow", "list",
		"--query", query,
		"--address", cfg.Address,
		"--namespace", cfg.Namespace,
		"--output", "json",
		"--limit", "1000",
	}
	if cfg.UseTLS {
		args = append(args, "--tls")
	}
	if cfg.APIKey != "" {
		args = append(args, "--api-key", cfg.APIKey)
	}
	if cfg.TLSCertPath != "" {
		args = append(args, "--tls-cert-path", cfg.TLSCertPath)
	}
	if cfg.TLSKeyPath != "" {
		args = append(args, "--tls-key-path", cfg.TLSKeyPath)
	}

	cmd := exec.CommandContext(tempCtx, "temporal", args...)
	b, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			stderr := strings.TrimSpace(string(ee.Stderr))
			if stderr != "" {
				return nil, fmt.Errorf("temporal workflow list: %s", stderr)
			}
		}
		return nil, fmt.Errorf("temporal workflow list: %w", err)
	}

	var entries []workflowListEntry
	if err := json.Unmarshal(b, &entries); err != nil {
		return nil, fmt.Errorf("failed to parse workflow list output: %w", err)
	}

	executions := make([]executionEntry, 0, len(entries))
	for _, e := range entries {
		version := ""
		if field, ok := e.SearchAttributes.IndexedFields["TemporalWorkerDeploymentVersion"]; ok && field.Data != "" {
			decoded, err := base64.StdEncoding.DecodeString(field.Data)
			if err == nil {
				// Value is a JSON string like "default/helloworld:buildID"
				var strVal string
				if json.Unmarshal(decoded, &strVal) == nil && strVal != "" {
					if strings.HasPrefix(strVal, deploymentKey+":") {
						version = strings.TrimPrefix(strVal, deploymentKey+":")
					} else {
						version = strVal
					}
				} else {
					// Or a JSON array like ["default/helloworld:buildID"]
					var arrVal []string
					if json.Unmarshal(decoded, &arrVal) == nil && len(arrVal) > 0 {
						raw := arrVal[0]
						if strings.HasPrefix(raw, deploymentKey+":") {
							version = strings.TrimPrefix(raw, deploymentKey+":")
						} else {
							version = raw
						}
					}
				}
			}
		}
		executions = append(executions, executionEntry{
			ID:      e.Execution.WorkflowID,
			Version: version,
		})
	}

	return executions, nil
}

func enrichActiveWorkflowData(ctx context.Context, twd twdResource, cards []versionCard) (int, map[string]int, string) {
	cfg, err := loadTemporalAccessConfig(ctx, twd)
	if err != nil {
		log.Printf("dashboard: failed to load temporal access config: %v", err)
		if total, counts, ok := applyCachedWorkflowData(); ok {
			return total, counts, "Using recent cached active workflow percentages while live query retries."
		}
		return 0, nil, ""
	}
	defer cleanupTempFiles(cfg.TempFiles)

	deploymentKey := fmt.Sprintf("%s/%s", twd.Metadata.Namespace, twd.Metadata.Name)
	totalQuery := fmt.Sprintf(`ExecutionStatus="Running" AND TemporalWorkerDeployment=%q`, deploymentKey)
	total, err := temporalWorkflowCount(ctx, cfg, totalQuery)
	if err != nil {
		log.Printf("dashboard: failed to query total active workflows for %s: %v", deploymentKey, err)
		if cachedTotal, counts, ok := applyCachedWorkflowData(); ok {
			return cachedTotal, counts, "Using recent cached active workflow percentages while live query retries."
		}
		return 0, nil, ""
	}
	if total == 0 {
		// Avoid immediately dropping cache on transient zero-count reads.
		if cachedTotal, counts, ok := applyCachedWorkflowData(); ok {
			return cachedTotal, counts, "Using recent cached active workflow percentages while live query retries."
		}
		return 0, nil, ""
	}

	// Per-version counts: workflows are now pinned to a specific version via
	// --versioning-override, so each workflow only accumulates one entry in
	// TemporalWorkerDeploymentVersion. The KeywordList "=" contains-check is
	// therefore accurate for pinned workflows.
	perVersion := make(map[string]int)
	for _, c := range cards {
		if c.BuildID == "" {
			continue
		}
		s := strings.ToLower(c.Status)
		// Only query versions that could have active workflows.
		if s == "drained" || s == "notregistered" {
			continue
		}
		versionKey := fmt.Sprintf("%s:%s", deploymentKey, c.BuildID)
		vQuery := fmt.Sprintf(`ExecutionStatus="Running" AND TemporalWorkerDeploymentVersion=%q`, versionKey)
		count, qErr := temporalWorkflowCount(ctx, cfg, vQuery)
		if qErr != nil {
			log.Printf("dashboard: per-version count failed for %s: %v", c.BuildID, qErr)
			continue
		}
		if count > 0 {
			perVersion[c.BuildID] = count
		}
	}

	writeCachedWorkflowData(total, perVersion)
	return total, perVersion, ""
}

func applyCachedWorkflowData() (int, map[string]int, bool) {
	workflowCache.mu.RLock()
	defer workflowCache.mu.RUnlock()
	if workflowCache.total <= 0 {
		return 0, nil, false
	}
	if time.Since(workflowCache.updated) > 2*time.Minute {
		return 0, nil, false
	}
	return workflowCache.total, workflowCache.counts, true
}

func writeCachedWorkflowData(total int, counts map[string]int) {
	workflowCache.mu.Lock()
	workflowCache.total = total
	workflowCache.counts = counts
	workflowCache.updated = time.Now()
	workflowCache.mu.Unlock()
}

func clearCachedWorkflowData() {
	workflowCache.mu.Lock()
	workflowCache.total = 0
	workflowCache.counts = nil
	workflowCache.updated = time.Time{}
	workflowCache.mu.Unlock()
}

func writeCachedSlotMetrics(used, cap float64) {
	slotsCache.mu.Lock()
	slotsCache.used = used
	slotsCache.cap = cap
	slotsCache.updated = time.Now()
	slotsCache.hasData = true
	slotsCache.mu.Unlock()
}

func readCachedSlotMetrics() (*float64, *float64, bool) {
	slotsCache.mu.RLock()
	defer slotsCache.mu.RUnlock()
	if !slotsCache.hasData {
		return nil, nil, false
	}
	if time.Since(slotsCache.updated) > 60*time.Second {
		return nil, nil, false
	}
	used := slotsCache.used
	cap := slotsCache.cap
	return &used, &cap, true
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

		// The deployment label may have a suffix appended to the SHA (e.g. "<sha>-<hex>").
		// Try matching with the full label first, then fall back to the bare SHA prefix
		// so we can merge with TWD status cards which use only the SHA.
		lookupID := buildID
		if idx, ok := cardByBuildID[lookupID]; ok {
			cards[idx].Deployment = depRef
			cards[idx].Replicas = dep.Status.Replicas
			cards[idx].ReadyReplicas = dep.Status.ReadyReplicas
			continue
		}
		// Strip trailing "-<hex>" suffix if present.
		if dashIdx := strings.LastIndex(buildID, "-"); dashIdx > 0 {
			lookupID = buildID[:dashIdx]
			if idx, ok := cardByBuildID[lookupID]; ok {
				cards[idx].Deployment = depRef
				cards[idx].Replicas = dep.Status.Replicas
				cards[idx].ReadyReplicas = dep.Status.ReadyReplicas
				cardByBuildID[buildID] = idx // also index the full label
				continue
			}
		}

		cardByBuildID[buildID] = len(cards)
		cards = append(cards, versionCard{
			BuildID:       lookupID, // use bare SHA, not the suffixed label
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
		// Only fetch individual deployment status for current/target (not deprecated).
		// Deprecated versions get their replica data from mergeLiveDeploymentData's
		// batch query, avoiding 9+ sequential kubectl calls that eat into the context deadline.
		if role != "deprecated" {
			var dep deploymentResource
			err := kubectlJSON(ctx, &dep, "-n", ns, "get", "deployment", v.Deployment.Name, "-o", "json")
			if err == nil {
				card.Replicas = dep.Status.Replicas
				card.ReadyReplicas = dep.Status.ReadyReplicas
			}
		}
	}
	return card
}

// computeTraffic assigns a new-workflow routing percentage to each version.
//
// Temporal's rainbow deployment model:
//   - One "target" version receives rampPercentage% of new workflow starts.
//   - One "current" version receives (100 - rampPercentage)% of new starts.
//   - "deprecated" versions receive 0% of new starts but are still alive serving
//     their pinned, in-flight workflows (Draining state).
//
// TrafficPct is set only for current/target (new-workflow routing).
// Deprecated/draining versions get Draining=true so the UI shows them correctly.
func computeTraffic(cards []versionCard) (newWorkflowPcts map[string]float64, drainingIDs map[string]bool, rampingTargetID string) {
	newWorkflowPcts = map[string]float64{}
	drainingIDs = map[string]bool{}

	var currentID, targetID string
	var targetRamp *float64

	for _, c := range cards {
		isCurrent := strings.Contains(c.Role, "current")
		isTarget := strings.Contains(c.Role, "target")

		if isCurrent {
			currentID = c.BuildID
		}
		// A target with a rampPercentage is actively ramping.
		if isTarget && c.RampPct != nil {
			targetID = c.BuildID
			targetRamp = c.RampPct
		}
		// Only purely deprecated cards (not also current or target) are draining.
		if !isCurrent && !isTarget {
			drainingIDs[c.BuildID] = true
		}
	}

	// Active ramp: target exists, has a ramp percentage, and is a different version from current.
	// When current == target (same buildID), the ramp just completed — don't treat as ramping.
	if targetID != "" && targetID != currentID {
		rampingTargetID = targetID
		ramp := 0.0
		if targetRamp != nil {
			ramp = clampPct(*targetRamp)
		}
		newWorkflowPcts[targetID] = ramp
		if currentID != "" {
			newWorkflowPcts[currentID] = clampPct(100 - ramp)
		}
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

func loadTemporalAccessConfig(ctx context.Context, twd twdResource) (temporalAccessConfig, error) {
	connectionName := twd.Spec.WorkerOptions.ConnectionRef.Name
	if connectionName == "" {
		connectionName = twd.Metadata.Name
	}
	if twd.Spec.WorkerOptions.TemporalNamespace == "" {
		return temporalAccessConfig{}, fmt.Errorf("Temporal namespace not configured on worker deployment")
	}

	// Check cache first (5-minute TTL)
	configCache.mu.RLock()
	if time.Since(configCache.updated) < 5*time.Minute && configCache.updated.After(time.Time{}) {
		defer configCache.mu.RUnlock()
		return configCache.cfg, nil
	}
	configCache.mu.RUnlock()

	// Create a shorter timeout for individual kubectl calls (20 sec each)
	kctx, kcancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
	defer kcancel()

	var conn temporalConnectionResource
	if err := kubectlJSON(kctx, &conn, "-n", twd.Metadata.Namespace, "get", "temporalconnection", connectionName, "-o", "json"); err != nil {
		return temporalAccessConfig{}, err
	}

	cfg := temporalAccessConfig{
		Address:        conn.Spec.HostPort,
		Namespace:      twd.Spec.WorkerOptions.TemporalNamespace,
		SupportsCounts: true,
	}

	if conn.Spec.APIKeySecretRef != nil && strings.TrimSpace(conn.Spec.APIKeySecretRef.Name) != "" && strings.TrimSpace(conn.Spec.APIKeySecretRef.Key) != "" {
		secretData, err := loadSecretData(kctx, twd.Metadata.Namespace, conn.Spec.APIKeySecretRef.Name)
		if err != nil {
			return temporalAccessConfig{}, err
		}
		cfg.APIKey = secretData[conn.Spec.APIKeySecretRef.Key]
		if cfg.APIKey == "" {
			return temporalAccessConfig{}, fmt.Errorf("Temporal API key secret %s/%s missing key %q", twd.Metadata.Namespace, conn.Spec.APIKeySecretRef.Name, conn.Spec.APIKeySecretRef.Key)
		}
		// Temporal Cloud endpoints require TLS with API-key auth.
		cfg.UseTLS = true
		// Cache the config before returning
		configCache.mu.Lock()
		configCache.cfg = cfg
		configCache.updated = time.Now()
		configCache.mu.Unlock()
		return cfg, nil
	}

	if conn.Spec.MutualTLSSecretRef != nil && strings.TrimSpace(conn.Spec.MutualTLSSecretRef.Name) != "" {
		secretData, err := loadSecretData(kctx, twd.Metadata.Namespace, conn.Spec.MutualTLSSecretRef.Name)
		if err != nil {
			return temporalAccessConfig{}, err
		}
		certPath, err := writeTempSecretFile("temporal-client-cert-*.pem", secretData["tls.crt"])
		if err != nil {
			return temporalAccessConfig{}, err
		}
		keyPath, err := writeTempSecretFile("temporal-client-key-*.pem", secretData["tls.key"])
		if err != nil {
			cleanupTempFiles([]string{certPath})
			return temporalAccessConfig{}, err
		}
		cfg.TLSCertPath = certPath
		cfg.TLSKeyPath = keyPath
		cfg.UseTLS = true
		cfg.TempFiles = []string{certPath, keyPath}
		// Cache the config before returning (note: with temp files, cache only the non-temp parts)
		cfgCopy := cfg
		cfgCopy.TempFiles = nil
		configCache.mu.Lock()
		configCache.cfg = cfgCopy
		configCache.updated = time.Now()
		configCache.mu.Unlock()
		return cfg, nil
	}

	return temporalAccessConfig{}, fmt.Errorf("TemporalConnection %s/%s has no valid API key or mTLS secret configured", twd.Metadata.Namespace, connectionName)
}

func loadSecretData(ctx context.Context, namespace, name string) (map[string]string, error) {
	var secret secretResource
	if err := kubectlJSON(ctx, &secret, "-n", namespace, "get", "secret", name, "-o", "json"); err != nil {
		return nil, err
	}
	decoded := make(map[string]string, len(secret.Data))
	for key, value := range secret.Data {
		raw, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			return nil, fmt.Errorf("decode secret %s/%s key %s: %w", namespace, name, key, err)
		}
		decoded[key] = string(raw)
	}
	return decoded, nil
}

func writeTempSecretFile(pattern, contents string) (string, error) {
	file, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", err
	}
	path := file.Name()
	if _, err := file.WriteString(contents); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return "", err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return "", err
	}
	return path, nil
}

func cleanupTempFiles(paths []string) {
	for _, path := range paths {
		if path != "" {
			_ = os.Remove(path)
		}
	}
}

// parseTemporalWorkflowCount handles multiple output formats from temporal CLI across versions.
// Supports:
// - "Total: N" format (standard)
// - Plain numeric "N" format (fallback)
// - JSON format {"count": N} or {"total": N} (future-proofing)
func parseTemporalWorkflowCount(output string) (int, error) {
	text := strings.TrimSpace(output)
	if text == "" {
		return 0, nil
	}

	// Try: "Total: N" format (current standard)
	if strings.HasPrefix(text, "Total:") {
		text = strings.TrimPrefix(text, "Total:")
		text = strings.TrimSpace(text)
		if n, err := strconv.Atoi(text); err == nil {
			return n, nil
		}
		// If parse fails after trimming, fall through to other formats
	}

	// Try: plain numeric format "N"
	if n, err := strconv.Atoi(text); err == nil {
		return n, nil
	}

	// Try: JSON format {"count": N} or {"total": N}
	var jsonResp struct {
		Count int `json:"count"`
		Total int `json:"total"`
	}
	if err := json.Unmarshal([]byte(text), &jsonResp); err == nil {
		if jsonResp.Count > 0 {
			return jsonResp.Count, nil
		}
		if jsonResp.Total > 0 {
			return jsonResp.Total, nil
		}
	}

	// Unable to parse in any known format
	return 0, fmt.Errorf("unexpected workflow count format: %q", output)
}

func temporalWorkflowCount(ctx context.Context, cfg temporalAccessConfig, query string) (int, error) {
	// Use a shorter timeout for individual temporal CLI calls (15 seconds)
	tempCtx, tempCancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer tempCancel()

	args := []string{
		"workflow", "count",
		"--query", query,
		"--address", cfg.Address,
		"--namespace", cfg.Namespace,
	}
	if cfg.UseTLS {
		args = append(args, "--tls")
	}
	if cfg.APIKey != "" {
		args = append(args, "--api-key", cfg.APIKey)
	}
	if cfg.TLSCertPath != "" {
		args = append(args, "--tls-cert-path", cfg.TLSCertPath)
	}
	if cfg.TLSKeyPath != "" {
		args = append(args, "--tls-key-path", cfg.TLSKeyPath)
	}

	safeArgs := make([]string, 0, len(args))
	skipNext := false
	for _, a := range args {
		if skipNext {
			skipNext = false
			safeArgs = append(safeArgs, "***")
			continue
		}
		safeArgs = append(safeArgs, a)
		if a == "--api-key" {
			skipNext = true
		}
	}

	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		cmd := exec.CommandContext(tempCtx, "temporal", args...)
		b, err := cmd.Output()
		if err == nil {
			// Use robust parser that handles multiple output formats
			n, parseErr := parseTemporalWorkflowCount(string(b))
			if parseErr != nil {
				log.Printf("dashboard: temporal workflow count parse error (attempt %d/%d): %v; output was: %q", attempt, 3, parseErr, string(b))
				lastErr = parseErr
				// Continue to next retry attempt for parse errors
				if attempt < 3 {
					select {
					case <-ctx.Done():
						break
					case <-time.After(time.Duration(attempt) * 300 * time.Millisecond):
					}
				}
				continue
			}
			return n, nil
		}

		var ee *exec.ExitError
		if errors.As(err, &ee) {
			stderr := strings.TrimSpace(string(ee.Stderr))
			if stderr != "" {
				lastErr = fmt.Errorf("temporal %s: %s", strings.Join(safeArgs, " "), stderr)
			} else {
				lastErr = fmt.Errorf("temporal %s: %w", strings.Join(safeArgs, " "), err)
			}
		} else {
			lastErr = fmt.Errorf("temporal %s: %w", strings.Join(safeArgs, " "), err)
		}

		log.Printf("dashboard: temporal workflow count failed (attempt %d/%d): %v", attempt, 3, lastErr)

		if ctx.Err() != nil {
			break
		}
		if attempt < 3 {
			select {
			case <-ctx.Done():
				break
			case <-time.After(time.Duration(attempt) * 300 * time.Millisecond):
			}
		}
	}

	if lastErr != nil {
		return 0, lastErr
	}
	return 0, fmt.Errorf("temporal %s: workflow count failed", strings.Join(safeArgs, " "))
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
	if resp.Status != "success" {
		return nil, fmt.Errorf("prometheus query returned status %q", resp.Status)
	}
	if len(resp.Data.Result) == 0 || len(resp.Data.Result[0].Value) < 2 {
		zero := 0.0
		return &zero, nil
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
